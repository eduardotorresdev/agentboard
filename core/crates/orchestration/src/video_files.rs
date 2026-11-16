use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::Value;

use connections::{Size, Uuid};

use crate::image_card::{extension, Failure, ImageFiles, Inspected, Stored};

/// The programs videos are read with on a host: Swift reads them with AVFoundation.
#[derive(Clone, Debug)]
pub struct VideoTools {
    ffprobe: String,
    ffmpeg: String,
}

impl VideoTools {
    /// `ffprobe` and `ffmpeg` from `search_path`; none when either is missing.
    pub fn locate(search_path: &str) -> Option<Self> {
        let find = |name| runtime::AgentCatalog::locate(name, search_path, &["/opt/homebrew/bin".to_string(), "/usr/local/bin".to_string()]);
        Some(Self { ffprobe: find("ffprobe")?, ffmpeg: find("ffmpeg")? })
    }
}

/// Videos live with the pictures (same folder, same record), so a board that predates them
/// keeps its images as they are. Everything here that reads a video runs ffmpeg and blocks up
/// to `TIMEOUT`: call it off the main loop.
impl ImageFiles {
    /// The largest video taken: a few minutes of 1080p screen recording.
    pub const MAXIMUM_VIDEO_BYTES: u64 = 200 * 1024 * 1024;
    /// The containers the board plays without extra codecs.
    pub const VIDEO_EXTENSIONS: [&'static str; 3] = ["mp4", "mov", "m4v"];
    /// How many frames `reading_video` samples, evenly over the video.
    pub const READ_FRAMES: usize = 4;
    /// The longer side of each sampled frame.
    pub const READ_FRAME_SIDE: u32 = 1024;
    /// The longest any ffmpeg step may take.
    const TIMEOUT: Duration = Duration::from_secs(20);

    /// Any movie file, playable or not: these go through `store_video`, which says why it refuses.
    // shortcut: told by the extension alone (Swift also asks the system for the content type), sniff the header if movies arrive under other names.
    pub fn is_video_file(path: &Path) -> bool {
        const MOVIES: [&str; 14] = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv", "3gp", "ogv", "ts", "mts"];
        extension(path).is_some_and(|extension| MOVIES.contains(&extension.as_str()))
    }

    /// Copies a playable video into the folder under a new name, as it is.
    pub(crate) fn store_video(file: &Inspected, data_folder: &Path, tools: Option<&VideoTools>) -> Result<Stored, Failure> {
        let extension = extension(&file.path).filter(|extension| Self::VIDEO_EXTENSIONS.contains(&extension.as_str())).ok_or(Failure::NotPlayable)?;
        if file.bytes > Self::MAXIMUM_VIDEO_BYTES {
            return Err(Failure::TooLarge);
        }
        let (pixel_size, duration) = Self::video_info(&file.path, tools.ok_or(Failure::NoVideoTools)?).ok_or(Failure::NotPlayable)?;
        let name = format!("{}.{extension}", Uuid::new());
        std::fs::create_dir_all(Self::folder(data_folder)).map_err(|error| Failure::Other(error.to_string()))?;
        Self::copy(&file.path, &Self::url(&name, data_folder), Self::MAXIMUM_VIDEO_BYTES)?;
        Ok(Stored { file: name, pixel_size, duration: Some(duration) })
    }

    /// Copies at most `limit` bytes: a file that grew past it since it was measured is refused
    /// and nothing is left behind.
    pub(crate) fn copy(source: &Path, destination: &Path, limit: u64) -> Result<(), Failure> {
        let mut input = std::fs::File::open(source).map_err(|_| Failure::Missing)?;
        let mut output = std::fs::File::create(destination).map_err(|_| Failure::Missing)?;
        let mut copy = || {
            let mut chunk = vec![0u8; 1 << 20];
            let mut written = 0u64;
            loop {
                let count = input.read(&mut chunk).map_err(|error| Failure::Other(error.to_string()))?;
                if count == 0 {
                    return Ok(());
                }
                written += count as u64;
                if written > limit {
                    return Err(Failure::TooLarge);
                }
                output.write_all(&chunk[..count]).map_err(|error| Failure::Other(error.to_string()))?;
            }
        };
        let copied = copy();
        if copied.is_err() {
            let _ = std::fs::remove_file(destination);
        }
        copied
    }

    /// The upright size and the length of a playable video whose frames decode through to the
    /// last one `reading_video` samples (a truncated file fails here, not when an agent reads
    /// it); none otherwise or after `TIMEOUT`.
    pub fn video_info(path: &Path, tools: &VideoTools) -> Option<(Size, f64)> {
        let deadline = Instant::now() + Self::TIMEOUT;
        let entries = "stream=width,height,duration:stream_tags=rotate:stream_side_data=rotation:format=duration";
        let described = output(Command::new(&tools.ffprobe).args(["-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of", "json"]).arg(path), deadline)?;
        let described: Value = serde_json::from_slice(&described).ok()?;
        let stream = described.get("streams")?.get(0)?;
        let number = |value: &Value| value.as_f64().or_else(|| value.as_str()?.parse().ok());
        let (width, height) = (number(stream.get("width")?)?, number(stream.get("height")?)?);
        let rotation = stream.get("side_data_list").and_then(Value::as_array).and_then(|list| list.iter().find_map(|data| number(data.get("rotation")?)));
        let rotation = rotation.or_else(|| number(stream.get("tags")?.get("rotate")?)).unwrap_or(0.0);
        let turned = (rotation.abs() / 90.0).round() as i64 % 2 == 1;
        let size = if turned { Size::new(height, width) } else { Size::new(width, height) };
        let seconds = described.get("format").and_then(|format| number(format.get("duration")?)).or_else(|| number(stream.get("duration")?))?;
        if !(size.width > 0.0 && size.height > 0.0 && seconds.is_finite() && seconds >= 0.0) {
            return None;
        }
        for second in [0.0, Self::sample_times(seconds).last().copied().unwrap_or(0.0)] {
            frame(path, second, 64, tools, deadline)?;
        }
        Some((size, seconds))
    }

    /// The seconds `reading_video` asks for: the middle of each of `READ_FRAMES` equal slices.
    pub fn sample_times(duration: f64) -> Vec<f64> {
        (0..Self::READ_FRAMES).map(|index| duration * (index as f64 + 0.5) / Self::READ_FRAMES as f64).collect()
    }

    /// What an agent gets for a video: up to `READ_FRAMES` JPEG frames sampled evenly, each with
    /// its second. Times that land on the same frame give it once, so a one-frame video gives
    /// one frame. None when the file is gone, unplayable or too slow.
    // shortcut: each frame carries the second asked for, where AVFoundation reports the one the
    // frame really shows (they differ by under a frame), read ffmpeg's `showinfo` if that matters.
    pub fn reading_video(file: &str, data_folder: &Path, tools: &VideoTools) -> Option<Vec<(f64, Vec<u8>)>> {
        let path = Self::url(file, data_folder);
        let deadline = Instant::now() + Self::TIMEOUT;
        let duration: f64 = String::from_utf8(output(Command::new(&tools.ffprobe).args(["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"]).arg(&path), deadline)?).ok()?.trim().parse().ok()?;
        let mut frames: Vec<(f64, Vec<u8>)> = Vec::new();
        for second in Self::sample_times(duration) {
            if let Some(jpeg) = frame(&path, second, Self::READ_FRAME_SIDE, tools, deadline).filter(|jpeg| !frames.iter().any(|(_, seen)| seen == jpeg)) {
                frames.push((second, jpeg));
            }
        }
        (!frames.is_empty()).then_some(frames)
    }
}

/// The frame at `second` exactly (ffmpeg decodes from the keyframe before it), as a JPEG at most
/// `side` on its longer side; none when there is none there.
fn frame(path: &Path, second: f64, side: u32, tools: &VideoTools, deadline: Instant) -> Option<Vec<u8>> {
    let scale = format!("scale='min({side},iw)':'min({side},ih)':force_original_aspect_ratio=decrease");
    let mut command = Command::new(&tools.ffmpeg);
    command.args(["-v", "error", "-ss", &format!("{second:.3}"), "-i"]).arg(path).args(["-frames:v", "1", "-vf", &scale, "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "4", "-"]);
    output(&mut command, deadline).filter(|jpeg| !jpeg.is_empty())
}

/// What `command` printed when it ended well before `deadline`; it is killed at the deadline.
fn output(command: &mut Command, deadline: Instant) -> Option<Vec<u8>> {
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let mut pipe = child.stdout.take()?;
    let (sender, printed) = mpsc::channel();
    std::thread::spawn(move || {
        let mut read = Vec::new();
        let _ = sender.send(pipe.read_to_end(&mut read).ok().map(|_| read));
    });
    let read = printed.recv_timeout(deadline.saturating_duration_since(Instant::now()));
    if read.is_err() {
        let _ = child.kill();
    }
    let ended = child.wait().ok()?;
    read.ok().flatten().filter(|_| ended.success())
}
