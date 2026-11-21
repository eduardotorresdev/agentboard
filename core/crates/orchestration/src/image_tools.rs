use std::collections::HashMap;
use std::path::Path;

use serde_json::{json, Map, Value};

use connections::{find_element, BoardName, Element, ElementKind, Rect, Reply, ToolContent, ToolDefinition, ToolProvider, ToolResult, Uuid};

use crate::image_card::{Failure, ImageFiles, ImageRecord, Kind, Stored};
use crate::orchestrator::{is_inline_space, Orchestrator, Turn};
use crate::runner_tools::absolute;

/// The image tools: agents put pictures on the board (a screenshot, a chart) and see the
/// pixels of the images connected to them. A second instance, `VIDEO`, gives the same
/// tools for videos (`video_create`…), which share the images' record and files. What each
/// agent last heard of each image is kept by the orchestrator (`delivered_images`).
pub(crate) struct ImageTools {
    video: bool,
}

/// What a tool is given once the file it was pointed at is stored, or why it wasn't.
type Storing = Box<dyn FnOnce(&mut Turn, Result<Stored, String>) + Send>;

const NO_VIDEO_TOOLS: &str = "Videos can't be read on this host: it needs ffmpeg and ffprobe in its PATH.";

impl ImageTools {
    pub(crate) const IMAGE: Self = Self { video: false };
    pub(crate) const VIDEO: Self = Self { video: true };

    fn kind(&self) -> ElementKind {
        if self.video { ElementKind::video() } else { ElementKind::image() }
    }

    /// Tool prefix and argument name.
    fn word(&self) -> &'static str {
        if self.video { "video" } else { "image" }
    }

    fn title(&self) -> &'static str {
        if self.video { "Video" } else { "Image" }
    }

    fn element_argument(&self) -> Value {
        json!({"type": "string", "description": format!("Which connected {}, by name or id (as list_peers shows it). Needed only when several are connected.", self.word())})
    }

    fn path_argument(&self) -> Value {
        let description = if self.video {
            format!("The video file: absolute, with `~`, or relative to your worktree. MP4, MOV or M4V, up to {} MB.", ImageFiles::MAXIMUM_VIDEO_BYTES / 1024 / 1024)
        } else {
            "The picture file: absolute, with `~`, or relative to your worktree. Any image format, up to 20 MB.".to_string()
        };
        json!({"type": "string", "description": description})
    }
}

impl<'a> ToolProvider<Turn<'a>> for ImageTools {
    fn instructions(&self, _turn: &mut Turn<'a>, _caller: Uuid) -> Option<String> {
        if self.video {
            return Some(format!(
                "Videos are clips on the user's board (MP4, MOV or M4V), kept apart from images. You hear in your context \
                 when one is connected to you, replaced or disconnected; video_read gives its size, length and {} \
                 frames sampled evenly through it. video_create puts a video file you made (a screen recording) on the \
                 board next to you, connected to you; video_replace swaps its clip, video_remove takes it off the board. \
                 Give a file path; videos are never passed inline.",
                ImageFiles::READ_FRAMES
            ));
        }
        Some(
            "Images are pictures on the user's board. You hear in your context when one is connected to you, replaced \
             or disconnected; see its pixels with image_read. image_create puts a picture file you made (a screenshot, \
             a chart) on the board next to you, connected to you; image_replace swaps the picture of a connected image, \
             image_remove takes one off the board. Give a file path; images are never passed inline. For videos use the \
             video_ tools."
                .to_string(),
        )
    }

    fn tools(&self, _turn: &mut Turn<'a>, _caller: Uuid) -> Vec<ToolDefinition> {
        let (word, picture) = (self.word(), !self.video);
        let which = || {
            let mut properties = Map::new();
            properties.insert(word.to_string(), self.element_argument());
            properties
        };
        let mut read = which();
        if picture {
            read.insert("marks".into(), json!({"type": "string", "description": "The id of marks the user sent you on this image: the picture comes with those numbered areas drawn on it. Leave out for the picture as it is."}));
        }
        let mut replaced = which();
        replaced.insert("path".into(), self.path_argument());
        vec![
            ToolDefinition::with_schema(
                &format!("{word}_create"),
                if picture { "Puts a picture file on the board next to you, connected to you." } else { "Puts a video file on the board next to you, connected to you. It never plays on its own." },
                json!({"type": "object", "properties": {
                    "path": self.path_argument(),
                    "name": {"type": "string", "description": format!("Its title, e.g. `{}`. “{}” when left out.", if picture { "Login screen" } else { "Signup flow" }, self.title())},
                }, "required": ["path"]}),
            ),
            ToolDefinition::with_schema(
                &format!("{word}_read"),
                &if picture { "Shows you the pixels of a connected image.".to_string() } else { format!("Gives a connected video's size and length and {} frames sampled evenly through it.", ImageFiles::READ_FRAMES) },
                json!({"type": "object", "properties": read, "required": []}),
            ),
            ToolDefinition::with_schema(
                &format!("{word}_replace"),
                if picture { "Replaces the picture of a connected image with a file, keeping its card and name." } else { "Replaces the clip of a connected video with a file, keeping its card and name." },
                json!({"type": "object", "properties": replaced, "required": ["path"]}),
            ),
            ToolDefinition::with_schema(&format!("{word}_remove"), &format!("Takes a connected {word} off the board."), json!({"type": "object", "properties": which(), "required": []})),
        ]
    }

    fn call(&mut self, turn: &mut Turn<'a>, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        let (word, video) = (self.word(), self.video);
        if name == format!("{word}_create") {
            return self.create(turn, arguments, caller, reply);
        }
        let element = match self.resolve(turn, arguments.get(word).and_then(Value::as_str), caller) {
            Ok(found) => found,
            Err(refusal) => return reply.send(ToolResult::error(refusal)),
        };
        let Some(record) = turn.image(element.id).cloned() else { return reply.send(ToolResult::error(format!("That {word} is gone."))) };
        let size = format!("{}×{}", record.pixel_size.width as i64, record.pixel_size.height as i64);
        match name.strip_prefix(word).unwrap_or(name) {
            "_read" if video => {
                let Some(tools) = turn.video_tools() else { return reply.send(ToolResult::error(NO_VIDEO_TOOLS)) };
                let data_folder = turn.data_folder.clone();
                // Off the main loop: ffmpeg takes its time.
                std::thread::spawn(move || {
                    let Some(frames) = ImageFiles::reading_video(&record.file, &data_folder, &tools) else {
                        return reply.send(ToolResult::error(format!("The video {} can't be read.", record.name)));
                    };
                    let (plural, verb) = if frames.len() == 1 { ("", "s") } else { ("s", "") };
                    let mut content = vec![ToolContent::Text(format!("{}, {size} pixels, {:.1} s. {} frame{plural} follow{verb}, each after the second it shows.", record.name, record.duration.unwrap_or(0.0), frames.len()))];
                    for (second, jpeg) in frames {
                        content.push(ToolContent::Text(format!("At {second:.2} s:")));
                        content.push(ToolContent::Image { data: jpeg, mime_type: "image/jpeg".into() });
                    }
                    reply.send(ToolResult::new(content))
                });
            }
            // shortcut: the marks' id is the marked copy's file name in the pictures folder, so any
            // agent that knows one can read it; keep a table of who was sent what if that matters.
            "_read" if arguments.get("marks").and_then(Value::as_str).is_some_and(|marks| !marks.trim().is_empty()) => {
                let marks = arguments.get("marks").and_then(Value::as_str).unwrap_or_default().trim();
                // A plain file name inside the pictures folder, never a path out of it.
                let plain = Path::new(marks).file_name().is_some_and(|name| name == marks) && marks != "..";
                reply.send(match plain.then(|| ImageFiles::reading(marks, &turn.data_folder)).flatten() {
                    Some((data, mime_type)) => ToolResult::new(vec![
                        ToolContent::Text(format!("{} with the user's marks drawn on it. The areas you were given are in the pixels of the picture itself, {size}.", record.name)),
                        ToolContent::Image { data, mime_type },
                    ]),
                    None => ToolResult::error(format!("There are no marks “{marks}”. See the picture without `marks`.")),
                })
            }
            "_read" => reply.send(match ImageFiles::reading(&record.file, &turn.data_folder) {
                Some((data, mime_type)) => ToolResult::new(vec![ToolContent::Text(format!("{}, {size} pixels.", record.name)), ToolContent::Image { data, mime_type }]),
                None => ToolResult::error(format!("The picture of {} can't be read.", record.name)),
            }),
            "_replace" => self.store_file(
                turn,
                arguments,
                caller,
                Box::new(move |turn: &mut Turn, stored: Result<Stored, String>| {
                    let stored = match stored {
                        Ok(stored) => stored,
                        Err(refusal) => return reply.send(ToolResult::error(refusal)),
                    };
                    // Removed while the file was copied: the copy goes too.
                    if turn.image(record.id).is_none() {
                        ImageFiles::remove(&stored.file, &turn.data_folder);
                        return reply.send(ToolResult::error(format!("That {word} is gone.")));
                    }
                    let file = stored.file.clone();
                    turn.update_image(record.id, None, |image| {
                        image.file = stored.file;
                        image.pixel_size = stored.pixel_size;
                        image.duration = stored.duration;
                        image.frame.size = ImageRecord::card_size_wide(image.frame.width(), stored.pixel_size);
                    });
                    if let Some(delivered) = turn.delivered_images.get_mut(&(video, caller)) {
                        delivered.insert(record.id, (record.name.clone(), file));
                    }
                    reply.send(ToolResult::text(format!("Replaced the {} of “{}”.", if video { "clip" } else { "picture" }, record.name)))
                }),
            ),
            "_remove" => {
                if let Some(delivered) = turn.delivered_images.get_mut(&(video, caller)) {
                    delivered.remove(&record.id);
                }
                turn.remove_image(record.id, None);
                reply.send(ToolResult::text(format!("Removed “{}” from the board.", record.name)))
            }
            _ => reply.send(ToolResult::error(format!("Unknown tool “{name}”."))),
        }
    }

    /// One line per connected image the caller hasn't heard of as it is now: all of them when
    /// its session starts, then those connected, replaced or disconnected since. What the
    /// caller did itself isn't sent back.
    fn context(&mut self, turn: &mut Turn<'a>, caller: Uuid, event: &str) -> Option<String> {
        let key = (self.video, caller);
        let before = if event == "SessionStart" { HashMap::new() } else { turn.delivered_images.remove(&key).unwrap_or_default() };
        let mut now: HashMap<Uuid, (String, String)> = HashMap::new();
        let mut parts: Vec<String> = Vec::new();
        let (title, word) = (self.title(), self.word());
        for element in turn.bus.peers_of_kind(caller, &self.kind(), &turn.board) {
            let Some(record) = turn.image(element.id) else { continue };
            let current = (record.name.clone(), record.file.clone());
            now.insert(record.id, current.clone());
            let seen = before.get(&record.id);
            if seen == Some(&current) {
                continue;
            }
            let size = format!("{}×{}{}", record.pixel_size.width as i64, record.pixel_size.height as i64, record.duration.map(|duration| format!(", {duration:.1} s")).unwrap_or_default());
            parts.push(match seen {
                Some(old) if old.1 != current.1 => format!("{title} “{}” has a new {} ({size}); see it with {word}_read.", record.name, if self.video { "clip" } else { "picture" }),
                Some(old) => format!("{title} “{}” is now called “{}”.", old.0, record.name),
                None => format!("{title} “{}” ({size}) is connected to you; see it with {word}_read.", record.name),
            });
        }
        parts.extend(before.iter().filter(|(id, _)| !now.contains_key(id)).map(|(_, gone)| format!("{title} “{}” is no longer connected to you.", gone.0)));
        turn.delivered_images.insert(key, now);
        (!parts.is_empty()).then(|| parts.join("\n"))
    }
}

impl ImageTools {
    fn create(&self, turn: &mut Turn, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        let (word, title, video) = (self.word(), self.title(), self.video);
        let only_agents = move || ToolResult::error(format!("Only agents on the board can add {word}s."));
        if turn.record(caller).is_none() {
            return reply.send(only_agents());
        }
        // The name first: a refused name must not leave a copied file behind.
        let trimmed = match BoardName::argument(arguments.get("name")) {
            Ok(name) => name.unwrap_or_default(),
            Err(error) => return reply.send(ToolResult::error(error.to_string())),
        };
        self.store_file(
            turn,
            arguments,
            caller,
            Box::new(move |turn: &mut Turn, stored: Result<Stored, String>| {
                let stored = match stored {
                    Ok(stored) => stored,
                    Err(refusal) => return reply.send(ToolResult::error(refusal)),
                };
                let Some(agent) = turn.record(caller).cloned() else {
                    ImageFiles::remove(&stored.file, &turn.data_folder);
                    return reply.send(only_agents());
                };
                let siblings = turn.images.iter().filter(|image| image.worktree == agent.worktree && image.organization_id() == agent.organization_id());
                let name = ImageRecord::unique_name(if trimmed.is_empty() { title } else { &trimmed }, siblings);
                let size = ImageRecord::card_size(stored.pixel_size);
                let record = ImageRecord {
                    id: Uuid::new(),
                    worktree: agent.worktree.clone(),
                    name: name.clone(),
                    frame: Rect::at(turn.origin(&agent, size), size),
                    file: stored.file,
                    pixel_size: stored.pixel_size,
                    organization: agent.organization,
                    duration: stored.duration,
                };
                let (id, file) = (record.id, record.file.clone());
                turn.insert_image(record, None);
                turn.made(id, caller);
                turn.connect(caller, id);
                turn.delivered_images.entry((video, caller)).or_default().insert(id, (name.clone(), file));
                reply.send(ToolResult::text(format!("Added {word} “{name}” ({}×{}), connected to you.", stored.pixel_size.width as i64, stored.pixel_size.height as i64)))
            }),
        )
    }

    /// The file at `path`, stored with `ImageFiles`: a picture at once, a video on a thread of
    /// its own, `then` hearing of it back on the main loop.
    fn store_file(&self, turn: &mut Turn, arguments: &Map<String, Value>, caller: Uuid, then: Storing) {
        let path = arguments.get("path").and_then(Value::as_str).map_or("", |path| path.trim_matches(is_inline_space));
        if path.is_empty() {
            return then(turn, Err(format!("Give the {}'s file with `path`.", if self.video { "video" } else { "picture" })));
        }
        let worktree = turn.record(caller).map(|record| record.worktree.clone()).unwrap_or_else(|| std::env::current_dir().unwrap_or_default().to_string_lossy().into_owned());
        let path = absolute(path, &worktree);
        // Each medium takes only its own files, so the agent's choice of tool is the card it
        // gets. The kind comes from the resolved file, decided once.
        let file = match ImageFiles::inspect(&path) {
            Ok(file) => file,
            Err(failure) => return then(turn, Err(refusal(&failure, &path, self.video))),
        };
        let video = file.kind == Kind::Video;
        if video != self.video {
            let shown = path.display();
            return then(turn, Err(if video { format!("{shown} is a video; put it on the board with video_create.") } else { format!("{shown} isn't a video; pictures go on the board with image_create.") }));
        }
        if !video {
            let stored = ImageFiles::store_picture(&file, &turn.data_folder).map_err(|failure| refusal(&failure, &path, false));
            return then(turn, stored);
        }
        let (tools, data_folder, handle) = (turn.video_tools(), turn.data_folder.clone(), turn.handle.clone());
        std::thread::spawn(move || {
            let stored = ImageFiles::store_video(&file, &data_folder, tools.as_ref()).map_err(|failure| refusal(&failure, &path, true));
            handle.post(move |orchestrator: &mut Orchestrator, server| then(&mut orchestrator.turn(server), stored));
        });
    }

    fn resolve(&self, turn: &Turn, name: Option<&str>, caller: Uuid) -> Result<Element, String> {
        let word = self.word();
        let images = turn.bus.peers_of_kind(caller, &self.kind(), &turn.board);
        if images.is_empty() {
            return Err(format!("No {word} is connected to you. Add one with {word}_create, or ask the user to connect one by drawing a line between it and your card."));
        }
        let names = || images.iter().map(|image| image.name.as_str()).collect::<Vec<_>>().join(", ");
        if let Some(name) = name.map(|name| name.trim_matches(is_inline_space)).filter(|name| !name.is_empty()) {
            return find_element(name, &images).cloned().ok_or_else(|| format!("No {word} named “{name}” is connected to you. Connected: {}.", names()));
        }
        match images.as_slice() {
            [only] => Ok(only.clone()),
            _ => Err(format!("Several {word}s are connected; say which with `{word}`: {}.", names())),
        }
    }
}

/// Why the file at `path` wasn't stored, for the agent.
fn refusal(failure: &Failure, path: &Path, video: bool) -> String {
    let path = path.display();
    match failure {
        Failure::NotAFile => format!("{path} isn't a regular file (a folder, a device or a pipe)."),
        Failure::TooLarge => format!("{path} is larger than {} MB.", if video { ImageFiles::MAXIMUM_VIDEO_BYTES / 1024 / 1024 } else { 20 }),
        Failure::NotPlayable => format!("{path} isn't a video the board can play; use MP4, MOV or M4V."),
        Failure::NotAnImage => format!("{path} isn't an image."),
        Failure::Missing => format!("There is no file at {path}."),
        Failure::NoVideoTools => NO_VIDEO_TOOLS.to_string(),
        Failure::Other(error) => format!("{path} couldn't be stored: {error}"),
    }
}
