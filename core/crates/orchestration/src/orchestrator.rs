use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{Read, Write};
use std::ops::{Deref, DerefMut};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Map, Value};

use connections::{
    Board as BusBoard, BoardName, Connection, ConnectionGraph, Element, ElementKind, Elements, Endpoint, Message, MessageBus, MessageError, MessagingTools, Reply, Request, RequestKind, ToolCatalog,
    ToolResult, ToolServer, Uuid,
};
use runtime::{AgentCatalog, AgentHook, AgentProvider, AgentSession, CoreBoard, CoreHandle, CoreServer, CoreService, Data, LaunchSpec, SessionStatus, State, ToolServerLink};
use terminal::TerminalModes;

use crate::attention::{AttentionRequest, PendingQuestions};
use crate::board_protocol::{from_runtime, only, to_runtime, BoardEvent, BoardRequest, BoardState, RunnerReport, Unlabelled};
use crate::card_database::CardDatabase;
use crate::cards::{prepare_organization, AgentRecord, ElementInfo};
use crate::image_card::{ImageFiles, ImageRecord};
use crate::l10n::l;
use crate::file_tree::FileTreeRecord;
use crate::post_it::PostItRecord;
use crate::process_inspector::{RunnerStats, Sample};
use crate::video_files::VideoTools;
use crate::{browser_relay::BrowserRelay, simulator_relay::SimulatorRelay, card_tools::CardTools, image_tools::ImageTools, post_it_tools::PostItTools, project_relay::ProjectRelay, runner_tools::RunnerTools, worktree_tools::WorktreeTools};

/// The board's cards, the lines between elements and the agents' tools, kept by the core so
/// they work while no board runs: agents message each other, start runners and read their logs
/// with the board closed, rebuilt or crashed. Boards mirror the cards and lines and send the
/// user's changes (see `BoardRequest`); the tools only a board can run (browsers) are relayed to
/// one.
///
/// Lives on the main loop, as the `CoreServer`'s service: nothing here is locked. Tool calls
/// arrive from the tool server's threads as closures posted to the loop (`CoreHandle`), and so
/// do timers and what worker threads found.
// shortcut: no handoff to a newer core (`prepareHandOff`, `handOffState`, `Inherited`), port it with the runtime's when a Rust core must be replaced without ending its programs.
pub struct Orchestrator {
    bus: MessageBus,
    store: Store,
}

/// Everything the orchestrator keeps but the lines, which the bus has: the two are borrowed
/// apart when the bus asks who is on the board (`Elements`).
pub struct Store {
    pub(crate) handle: CoreHandle<Orchestrator>,
    database: Option<CardDatabase>,
    pub(crate) providers: Vec<&'static dyn AgentProvider>,
    pub(crate) data_folder: PathBuf,
    pub(crate) cards: Vec<AgentRecord>,
    /// The post-its (see PostItTools).
    pub(crate) post_its: Vec<PostItRecord>,
    /// The images (see ImageTools).
    pub(crate) images: Vec<ImageRecord>,
    /// The file tree cards; the board lists their files on the host.
    pub(crate) file_trees: Vec<FileTreeRecord>,
    /// The agents waiting on the developer, oldest first (see attention.rs).
    pub(crate) attention: Vec<AttentionRequest>,
    /// Agents whose questions hook waits on the developer's answers (see attention.rs).
    pub(crate) pending_questions: HashMap<Uuid, PendingQuestions>,
    /// Agent endpoints, so messages held while an agent waits on the developer go out once it's answered.
    agent_endpoints: HashMap<Uuid, AgentEndpoint>,
    tool_server: ToolServer,
    /// The user's real PATH, resolved off the main loop at launch (the login shell can be slow).
    search_path: Option<String>,
    /// Where agents reach the tool server; none if it couldn't start (agents then launch without it).
    tools_url: Option<String>,
    /// Cards whose program waits for the PATH.
    pub(crate) pending_launches: Vec<Uuid>,
    /// Set when the saved board couldn't be read at launch: the stored lines are then never replaced.
    connections_read_only: bool,
    /// The boards' other elements (browsers).
    elements: HashMap<Uuid, ElementInfo>,
    /// Boards that got their welcome, which then get every change.
    boards: Vec<CoreBoard>,
    tool_calls: HashMap<Uuid, (CoreBoard, Reply)>,
    /// What the bus did since it was last asked (see `Turn::flush_bus`).
    bus_events: Arc<Mutex<Vec<BusEvent>>>,

    // Runners (see orchestrator_runners.rs).
    pub(crate) runner_stats: HashMap<Uuid, RunnerStats>,
    pub(crate) runner_samples: HashMap<Uuid, Sample>,
    /// Seconds since 2001.
    pub(crate) runner_starts: HashMap<Uuid, f64>,
    /// The monitor's timer, by the number it was started with; none while no runner runs.
    pub(crate) runner_monitor: Option<u64>,
    pub(crate) monitors_started: u64,
    /// A measurement is on its way from its thread.
    pub(crate) sampling: bool,
    pub(crate) network_address: Option<String>,
    pub(crate) reported_runners: RunnerReport,

    /// Per agent, each connected post-it as it last reached its context: name and text.
    pub(crate) delivered_post_its: HashMap<Uuid, HashMap<Uuid, (String, String)>>,
    /// Per medium (video or not) and agent, each connected image as it last reached its
    /// context: name and file.
    pub(crate) delivered_images: HashMap<(bool, Uuid), HashMap<Uuid, (String, String)>>,
}

enum BusEvent {
    Graph(Vec<Connection>),
    Message(Message),
}

/// What an `Orchestrator` is made with.
pub struct Options {
    /// The cards' database; `agentboard.sqlite` in the data folder when none.
    pub database: Option<PathBuf>,
    pub data_folder: PathBuf,
    /// The agents cards can run.
    pub providers: Vec<&'static dyn AgentProvider>,
    /// Skips asking the login shell for the PATH (tests).
    pub search_path: Option<String>,
}

impl Options {
    pub fn new(data_folder: impl Into<PathBuf>) -> Self {
        Self { database: None, data_folder: data_folder.into(), providers: AgentCatalog::all().to_vec(), search_path: None }
    }
}

/// The orchestrator for the length of one call on the main loop, with the server to act on.
pub struct Turn<'a> {
    pub(crate) bus: &'a mut MessageBus,
    pub(crate) board: BoardView<'a>,
}

/// The board without its lines: what the bus is given as the elements.
pub struct BoardView<'a> {
    pub(crate) store: &'a mut Store,
    pub(crate) server: &'a mut CoreServer<Orchestrator>,
}

impl<'a> Deref for Turn<'a> {
    type Target = BoardView<'a>;
    fn deref(&self) -> &Self::Target {
        &self.board
    }
}

impl DerefMut for Turn<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.board
    }
}

impl Deref for BoardView<'_> {
    type Target = Store;
    fn deref(&self) -> &Store {
        self.store
    }
}

impl DerefMut for BoardView<'_> {
    fn deref_mut(&mut self) -> &mut Store {
        self.store
    }
}

impl BusBoard for Turn<'_> {
    fn board(&mut self) -> (&mut MessageBus, &mut dyn Elements) {
        (self.bus, &mut self.board)
    }
}

impl Orchestrator {
    pub fn new(handle: CoreHandle<Self>, options: Options) -> Self {
        let Options { database, data_folder, providers, search_path } = options;
        let database = match CardDatabase::open(&database.unwrap_or_else(|| data_folder.join("agentboard.sqlite"))) {
            Ok(database) => Some(database),
            Err(error) => {
                // Running on without saving is better than not running, but never silently.
                eprintln!("agentboard core: the cards database didn't open, nothing will be saved: {error}");
                None
            }
        };
        let mut read_failed = false;
        let stored = database.as_ref();
        let mut saved = read(stored.map(CardDatabase::agents), &mut read_failed).unwrap_or_default();
        // Cards saved before agents had names get one now.
        for index in 0..saved.len() {
            if saved[index].name.is_empty() {
                let card = &saved[index];
                let base = providers.iter().find(|provider| provider.id() == card.provider_id).map_or(card.provider_id.clone(), |provider| provider.title().to_string());
                let name = AgentRecord::unique_name(&base, saved.iter().filter(|other| other.worktree == card.worktree));
                saved[index].name = name;
                if let Some(stored) = stored {
                    let _ = stored.save_agent(&saved[index]);
                }
            }
        }
        let saved_post_its = read(stored.map(CardDatabase::post_its), &mut read_failed).unwrap_or_default();
        let saved_images = read(stored.map(CardDatabase::images), &mut read_failed).unwrap_or_default();
        let saved_file_trees = read(stored.map(CardDatabase::file_trees), &mut read_failed).unwrap_or_default();
        let mut ids: HashSet<Uuid> = saved.iter().map(|card| card.id).chain(saved_post_its.iter().map(|note| note.id)).chain(saved_images.iter().map(|image| image.id)).chain(saved_file_trees.iter().map(|tree| tree.id)).collect();
        ids.extend(read(stored.map(CardDatabase::browser_ids), &mut read_failed).unwrap_or_default());
        let mut lines = read(stored.map(CardDatabase::connections), &mut read_failed).unwrap_or_default();
        lines.retain(|line| ids.contains(&line.a) && ids.contains(&line.b));

        let bus_events: Arc<Mutex<Vec<BusEvent>>> = Arc::default();
        let mut bus = MessageBus::new(ConnectionGraph::new(lines));
        // Kept as the Swift core writes it: a flat list, element then maker.
        let makers: Vec<Uuid> = std::fs::read(data_folder.join("makers.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        bus.makers = makers.chunks_exact(2).map(|pair| (pair[0], pair[1])).collect();
        bus.makers.extend(saved.iter().filter_map(|card| Some((card.id, card.runner.as_ref()?.owner?))));
        let events = bus_events.clone();
        bus.on_graph_change = Some(Box::new(move |graph| events.lock().unwrap().push(BusEvent::Graph(graph.connections().to_vec()))));
        let events = bus_events.clone();
        bus.on_message = Some(Box::new(move |message| events.lock().unwrap().push(BusEvent::Message(message.clone()))));

        let calls = handle.clone();
        let handler: connections::Handler = Arc::new(move |request| calls.post(move |orchestrator: &mut Orchestrator, server| orchestrator.turn(server).serve(request)));
        let secret = tool_secret(&data_folder);
        let tool_server = if std::env::var("AGENTBOARD_CORE_VERBOSE").as_deref() == Ok("1") {
            let log = handle.clone();
            ToolServer::logging(handler, secret, Arc::new(move |line| log.post(move |_, server| (server.on_log)(&format!("tools: {line}")))))
        } else {
            ToolServer::new(handler, secret)
        };
        // Agents launched earlier reach the server where it was.
        let port_file = data_folder.join("tools.port");
        let port = std::fs::read_to_string(&port_file).ok().and_then(|port| port.trim().parse::<u16>().ok());
        let tools_url = tool_server.start(port);
        if let Some(port) = tools_url.as_deref().and_then(|url| url.trim_end_matches(ToolServer::PATH).rsplit(':').next()) {
            let _ = std::fs::write(&port_file, port);
        }

        // Names reach agents' prompts and listings: cards saved by older builds are cleaned too.
        let clean = |name: &mut String, fallback: &str| *name = BoardName::named(name, fallback);
        let mut store = Store {
            handle,
            database,
            providers,
            data_folder,
            cards: saved,
            post_its: saved_post_its,
            images: saved_images,
            file_trees: saved_file_trees,
            attention: Vec::new(),
            pending_questions: HashMap::new(),
            agent_endpoints: HashMap::new(),
            tool_server,
            search_path: None,
            tools_url,
            pending_launches: Vec::new(),
            connections_read_only: read_failed,
            elements: HashMap::new(),
            boards: Vec::new(),
            tool_calls: HashMap::new(),
            bus_events,
            runner_stats: HashMap::new(),
            runner_samples: HashMap::new(),
            runner_starts: HashMap::new(),
            runner_monitor: None,
            monitors_started: 0,
            sampling: false,
            network_address: None,
            reported_runners: RunnerReport::default(),
            delivered_post_its: HashMap::new(),
            delivered_images: HashMap::new(),
        };
        store.cards.iter_mut().for_each(|card| clean(&mut card.name, if card.runner.is_none() { "Agent" } else { "Runner" }));
        store.post_its.iter_mut().for_each(|note| clean(&mut note.name, "Post-it"));
        store.images.iter_mut().for_each(|image| clean(&mut image.name, "Image"));
        store.file_trees.iter_mut().for_each(|tree| clean(&mut tree.name, "Files"));
        for index in 0..store.cards.len() {
            let (id, is_agent) = (store.cards[index].id, store.cards[index].runner.is_none());
            store.register(id, is_agent);
        }
        match search_path {
            Some(path) => store.path_resolved(path),
            None => {
                let handle = store.handle.clone();
                std::thread::spawn(move || {
                    let path = login_shell_path();
                    handle.post(move |orchestrator: &mut Orchestrator, server| {
                        orchestrator.store.path_resolved(path);
                        orchestrator.turn(server).launch_pending();
                    });
                });
            }
        }
        Self { bus, store }
    }

    /// The orchestrator and the server together, for one call on the main loop.
    pub fn turn<'a>(&'a mut self, server: &'a mut CoreServer<Self>) -> Turn<'a> {
        Turn { bus: &mut self.bus, board: BoardView { store: &mut self.store, server } }
    }

    /// Where agents reach the tools; tests call it as an agent would.
    pub fn tools_endpoint(&self) -> Option<&str> {
        self.store.tools_url.as_deref()
    }

    /// The token `card` calls the tools with.
    pub fn tool_token(&self, card: Uuid) -> String {
        self.store.tool_server.token(card)
    }

    pub fn cards(&self) -> &[AgentRecord] {
        &self.store.cards
    }

    pub fn post_its(&self) -> &[PostItRecord] {
        &self.store.post_its
    }

    pub fn images(&self) -> &[ImageRecord] {
        &self.store.images
    }

    pub fn file_trees(&self) -> &[FileTreeRecord] {
        &self.store.file_trees
    }

    pub fn attention(&self) -> &[AttentionRequest] {
        &self.store.attention
    }

    pub fn connections(&self) -> &[Connection] {
        self.bus.graph().connections()
    }
}

/// What a read of the database gave. One that fails must not look like an empty board: the
/// lines are saved by replacing them all, so they stay unwritten until the next launch reads
/// everything.
fn read<T>(result: Option<crate::card_database::Result<T>>, failed: &mut bool) -> Option<T> {
    match result? {
        Ok(read) => Some(read),
        Err(error) => {
            *failed = true;
            eprintln!("agentboard core: couldn't read the cards database, lines won't be saved: {error}");
            None
        }
    }
}

/// The key the tool server derives agents' tokens from, created on first use. Kept on disk,
/// readable by this user only, so tokens stay valid across launches.
fn tool_secret(folder: &Path) -> Option<Vec<u8>> {
    let path = folder.join("tools.key");
    if let Some(key) = std::fs::read(&path).ok().filter(|key| key.len() == 32) {
        return Some(key);
    }
    let mut bytes = [0u8; 32];
    // The kernel's generator.
    std::fs::File::open("/dev/urandom").and_then(|mut random| random.read_exact(&mut bytes)).ok()?;
    let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder);
    let _ = std::fs::remove_file(&path);
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).ok()?;
    file.write_all(&bytes).ok()?;
    Some(bytes.to_vec())
}

/// This process's environment; a variable that isn't text is left out.
pub(crate) fn environment() -> HashMap<String, String> {
    std::env::vars_os().filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?))).collect()
}

/// The user's shell: `SHELL`, else the one their account names (a service has no `SHELL`).
pub(crate) fn login_shell(environment: &HashMap<String, String>) -> String {
    if let Some(shell) = environment.get("SHELL").filter(|shell| !shell.is_empty()) {
        return shell.clone();
    }
    // SAFETY: getpwuid returns null or a record valid until the next call; its shell is copied out at once.
    let account = unsafe {
        let record = libc::getpwuid(libc::getuid());
        (!record.is_null() && !(*record).pw_shell.is_null()).then(|| std::ffi::CStr::from_ptr((*record).pw_shell).to_string_lossy().into_owned())
    };
    account.filter(|shell| !shell.is_empty()).unwrap_or_else(|| if cfg!(target_os = "macos") { "/bin/zsh" } else { "/bin/sh" }.to_string())
}

/// A service gets a minimal PATH; ask the user's interactive login shell for the real one
/// so tools installed through shell config (like ~/.local/bin) are found.
pub fn login_shell_path() -> String {
    let environment = environment();
    let fallback = environment.get("PATH").cloned().unwrap_or_else(|| "/usr/bin:/bin".to_string());
    let spawned = Command::new(login_shell(&environment)).args(["-l", "-i", "-c", "printf '\\n%s' \"$PATH\""]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn();
    let Ok(mut child) = spawned else { return fallback };
    let Some(mut pipe) = child.stdout.take() else { return fallback };
    let (sender, printed) = mpsc::channel();
    std::thread::spawn(move || {
        let mut read = Vec::new();
        let _ = pipe.read_to_end(&mut read);
        let _ = sender.send(read);
    });
    // Shell config can block (prompts, tmux auto-attach); never wait more than a few seconds.
    let mut read = printed.recv_timeout(Duration::from_secs(5));
    if read.is_err() {
        // SAFETY: the child hasn't been waited for, so its id is still its own.
        unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
        // Something it started may still hold the pipe open: its end is not waited for.
        read = printed.recv_timeout(Duration::from_secs(1));
        if read.is_err() {
            let _ = child.kill();
        }
    }
    let _ = child.wait();
    let text = String::from_utf8_lossy(&read.unwrap_or_default()).into_owned();
    text.split('\n').filter(|line| !line.is_empty()).next_back().map_or(fallback, str::to_string)
}

/// The board of an element of one organization's worktree; see `MessageBus::elements_on_board_of`.
pub(crate) fn board_key(worktree: &str, organization: Uuid) -> String {
    format!("{worktree}\0{organization}")
}

impl Store {
    fn register(&mut self, id: Uuid, is_agent: bool) {
        if is_agent {
            self.agent_endpoints.insert(id, AgentEndpoint::default());
        }
        // Agents launched earlier call with the token they got then.
        let _ = self.tool_server.token(id);
    }

    /// The PATH programs launch with is known: videos can be read too.
    fn path_resolved(&mut self, path: String) {
        self.search_path = Some(path);
        self.tidy_media();
    }


    /// ffmpeg and ffprobe, when this host has them.
    pub(crate) fn video_tools(&self) -> Option<VideoTools> {
        VideoTools::locate(self.search_path.as_deref().unwrap_or("/usr/bin:/bin"))
    }

    pub(crate) fn record(&self, id: Uuid) -> Option<&AgentRecord> {
        self.cards.iter().find(|card| card.id == id)
    }

    pub(crate) fn cards_in<'a>(&'a self, worktree: &'a str) -> impl Iterator<Item = &'a AgentRecord> {
        self.cards.iter().filter(move |card| card.worktree == worktree)
    }

    /// The boards' other elements on `worktree` (browsers, file trees).
    pub(crate) fn element_frames<'a>(&'a self, worktree: &'a str) -> impl Iterator<Item = &'a ElementInfo> {
        self.elements.values().filter(move |info| info.worktree == worktree)
    }

    pub(crate) fn post_it(&self, id: Uuid) -> Option<&PostItRecord> {
        self.post_its.iter().find(|note| note.id == id)
    }

    pub(crate) fn image(&self, id: Uuid) -> Option<&ImageRecord> {
        self.images.iter().find(|image| image.id == id)
    }

    pub(crate) fn file_tree(&self, id: Uuid) -> Option<&FileTreeRecord> {
        self.file_trees.iter().find(|tree| tree.id == id)
    }

    /// Whether the agent is answering the developer's questions or a prompt in its terminal:
    /// a message typed in now would land in that answer.
    fn is_awaiting_developer(&self, id: Uuid) -> bool {
        // A permission prompt counts whether or not it said anything: a message typed in now
        // could answer it.
        self.pending_questions.contains_key(&id) || self.attention.iter().any(|request| request.id == id && request.needs_user())
    }

    fn save<T>(&mut self, write: impl FnOnce(&mut CardDatabase) -> crate::card_database::Result<T>) {
        if let Some(database) = &mut self.database {
            let _ = write(database);
        }
    }
}

// MARK: The board as the bus sees it

impl Elements for BoardView<'_> {
    fn elements(&self) -> Vec<Element> {
        let ids = self.cards.iter().map(|card| card.id).chain(self.post_its.iter().map(|note| note.id)).chain(self.images.iter().map(|image| image.id)).chain(self.file_trees.iter().map(|tree| tree.id)).chain(self.elements.keys().copied());
        ids.filter_map(|id| self.element(id)).collect()
    }

    fn element(&self, id: Uuid) -> Option<Element> {
        if let Some(record) = self.record(id) {
            let board = Some(board_key(&record.worktree, record.organization_id()));
            return Some(match &record.runner {
                // An agent: a message is typed into its terminal as a prompt.
                None => Element { board, endpoint: Some(Endpoint { unavailable_reason: self.unavailable_reason(id) }), ..Element::new(id, record.name.clone(), ElementKind::agent()) },
                // A runner: reachable along lines, driven with the runner tools.
                Some(runner) => {
                    let detail = if runner.is_shell() { "a terminal the user types into".to_string() } else { format!("runs `{}`", runner.command) };
                    Element { board, detail: Some(detail), ..Element::new(id, record.name.clone(), ElementKind::runner()) }
                }
            });
        }
        if let Some(record) = self.post_it(id) {
            let lines = record.text.split(is_newline).filter(|line| !line.is_empty()).count();
            let length = match lines {
                0 => "empty".to_string(),
                1 => "1 line".to_string(),
                lines => format!("{lines} lines"),
            };
            let detail = format!("shared markdown note, {length}; read with postit_read");
            return Some(Element { board: Some(board_key(&record.worktree, record.organization_id())), detail: Some(detail), ..Element::new(id, record.name.clone(), ElementKind::post_it()) });
        }
        if let Some(record) = self.image(id) {
            let size = format!("{}×{}", record.pixel_size.width as i64, record.pixel_size.height as i64);
            let detail = record.duration.map_or(size.clone(), |duration| format!("{size}, {} s; read with video_read", duration.round() as i64));
            let kind = if record.is_video() { ElementKind::video() } else { ElementKind::image() };
            return Some(Element { board: Some(board_key(&record.worktree, record.organization_id())), detail: Some(detail), ..Element::new(id, record.name.clone(), kind) });
        }
        if let Some(record) = self.file_tree(id) {
            return Some(Element { board: Some(board_key(&record.worktree, record.organization_id())), ..Element::new(id, record.name.clone(), ElementKind::file_tree()) });
        }
        // An element the board told the core about (a browser).
        let info = self.elements.get(&id)?;
        let board = info.organization.map_or(info.worktree.clone(), |organization| board_key(&info.worktree, organization));
        Some(Element { board: Some(board), detail: info.detail.clone(), ..Element::new(id, info.name.clone(), ElementKind(info.kind.clone())) })
    }

    fn receive(&mut self, message: &Message, sender: &Element) {
        let name = BoardName::quoted(&sender.name);
        let id = message.to;
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id) else { return };
        endpoint.outbox.push_back(Queued { text: message.text.clone(), from_user: false, sender: Some(sender.id), from: Some(name) });
        // Agents answering at once (a broadcast's replies) reach it as one prompt, not a row of them.
        if !std::mem::replace(&mut endpoint.gathering, true) {
            self.store.handle.post_after(AgentEndpoint::GATHER, move |orchestrator: &mut Orchestrator, server| {
                let mut turn = orchestrator.turn(server);
                if let Some(endpoint) = turn.agent_endpoints.get_mut(&id) {
                    endpoint.gathering = false;
                    turn.board.deliver_next(id);
                }
            });
        }
        self.report_held(id);
    }

    /// Why the last message given to it waits instead of going in, or none when nothing waits.
    fn queue_note(&self, id: Uuid) -> Option<String> {
        let endpoint = self.agent_endpoints.get(&id).filter(|endpoint| !endpoint.outbox.is_empty())?;
        if self.is_awaiting_developer(id) {
            return Some("they are waiting on their user".into());
        }
        if endpoint.line.has_draft() && !endpoint.forced {
            return Some(format!("their user is typing in their terminal; it goes in once they submit, or after {} seconds without typing", AgentEndpoint::IDLE_LIMIT.as_secs()));
        }
        // Only the moment messages are gathered for: as good as delivered.
        (endpoint.delivering || !endpoint.gathering || endpoint.outbox.iter().any(|queued| queued.from.is_none())).then(|| "it goes in after the messages before it".into())
    }
}

/// As Swift's `Character.isNewline`, for the scalars a text can hold.
pub(crate) fn is_newline(scalar: char) -> bool {
    matches!(scalar, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `CharacterSet.whitespaces`: spaces and tabs, not line breaks.
pub(crate) fn is_inline_space(scalar: char) -> bool {
    scalar.is_whitespace() && !is_newline(scalar)
}

/// An agent as the message bus sees it: a message is typed into its terminal as a prompt.
#[derive(Default)]
struct AgentEndpoint {
    /// Prompts waiting their turn: each is pasted and submitted before the next, so two
    /// arriving together don't run into one line. Agents' messages waiting in a row go in as
    /// one prompt that names each sender.
    outbox: VecDeque<Queued>,
    delivering: bool,
    /// An agent's message just came: more may follow within `GATHER`, to go in with it.
    gathering: bool,
    /// What the user types in the terminal meanwhile: held between a paste and its Enter, and
    /// whether the line holds their unsent text, which a paste would join.
    line: TerminalLine,
    /// When the user last typed in the terminal.
    last_key: Option<Instant>,
    idle_check_scheduled: bool,
    /// Delivers even over the user's half-typed line, until the outbox empties (Deliver now).
    forced: bool,
    reported_held: usize,
}

struct Queued {
    text: String,
    /// Typed in the card's composer: given back to the board, never dropped silently.
    from_user: bool,
    /// The agent that sent it, told when it can't be delivered.
    sender: Option<Uuid>,
    /// The sending agent's name, quoted; `text` is then what it said, without a header.
    from: Option<String>,
}

impl Queued {
    /// The prompt for agents' messages delivered together, in the order they came.
    fn prompt(messages: &[(String, String)]) -> String {
        if let [(name, text)] = messages {
            return format!("Message from {name} (if it needs an answer, reply with send_message to {name}):\n\n{text}");
        }
        let said: Vec<String> = messages.iter().map(|(name, text)| format!("Message from {name}:\n\n{text}")).collect();
        format!("{} messages arrived together (reply with send_message to each sender that needs an answer).\n\n{}", messages.len(), said.join("\n\n"))
    }
}

impl AgentEndpoint {
    /// How long an agent's message waits for others to go in with it.
    const GATHER: Duration = Duration::from_millis(500);
    /// Between the paste and the Enter that submits it: sent together, the agent may read the
    /// Enter as part of the pasted text.
    const SUBMIT_DELAY: Duration = Duration::from_millis(250);
    /// A line left untouched this long no longer holds messages back: a key the program took
    /// without Enter (a menu) must not keep them forever.
    pub(crate) const IDLE_LIMIT: Duration = Duration::from_secs(30);
    /// Messages one agent can have waiting; past it senders are told it can't take more.
    pub(crate) const MAX_QUEUED: usize = 20;
}

impl BoardView<'_> {
    pub(crate) fn session(&self, id: Uuid) -> Option<AgentSession> {
        self.server.session(to_runtime(id))
    }

    pub(crate) fn broadcast(&self, event: &BoardEvent, except: Option<&CoreBoard>) {
        if self.boards.iter().all(|board| Some(board) == except) {
            return;
        }
        let data = event.encoded();
        self.boards.iter().filter(|board| Some(*board) != except).for_each(|board| board.send(&data));
    }

    /// Why its program can't take a prompt, or none.
    fn program_reason(&self, id: Uuid) -> Option<&'static str> {
        match self.session(id).map(|session| session.state()) {
            Some(State::Running) => None,
            Some(State::Starting) => Some("it is still starting"),
            Some(State::Exited) => Some("it exited"),
            Some(State::Failed(_)) => Some("it failed to start"),
            Some(State::Stopped) => Some("it was stopped"),
            None => Some("it hasn't started yet"),
        }
    }

    fn unavailable_reason(&self, id: Uuid) -> Option<String> {
        let queued = self.agent_endpoints.get(&id).map_or(0, |endpoint| endpoint.outbox.len());
        self.program_reason(id).map(str::to_string).or_else(|| (queued >= AgentEndpoint::MAX_QUEUED).then(|| format!("it already has {} messages waiting", AgentEndpoint::MAX_QUEUED)))
    }

    /// What the user wrote in the card's composer, typed in as their own prompt. One it can't
    /// take goes back to the board, which puts it back in the composer.
    fn prompt(&mut self, id: Uuid, text: &str) {
        let text = text.trim();
        let Some(queued) = self.agent_endpoints.get(&id).map(|endpoint| endpoint.outbox.len()) else { return };
        if text.is_empty() {
            return;
        }
        let reason = self
            .program_reason(id)
            .map(str::to_string)
            .or_else(|| self.is_awaiting_developer(id).then(|| "it is waiting for your answer".to_string()))
            .or_else(|| (queued >= AgentEndpoint::MAX_QUEUED).then(|| format!("it already has {} messages waiting", AgentEndpoint::MAX_QUEUED)));
        if let Some(reason) = reason {
            return self.give_back(id, text, &reason);
        }
        self.enqueue(id, Queued { text: text.to_string(), from_user: true, sender: None, from: None });
    }

    fn enqueue(&mut self, id: Uuid, queued: Queued) {
        if let Some(endpoint) = self.agent_endpoints.get_mut(&id) {
            endpoint.outbox.push_back(queued);
            self.deliver_next(id);
        }
    }

    /// A note from the board itself (a message of theirs that couldn't be delivered).
    fn notice(&mut self, id: Uuid, text: String) {
        if self.program_reason(id).is_none() {
            self.enqueue(id, Queued { text, from_user: false, sender: None, from: None });
        }
    }

    fn give_back(&self, id: Uuid, text: &str, reason: &str) {
        self.broadcast(&BoardEvent::PromptReturned { id, text: text.to_string(), reason: reason.to_string() }, None);
    }

    /// The user's keystrokes on their way to the terminal: what to pass on now. Keys answering
    /// the program's own question (a permission menu) don't write the line.
    // On the keystroke path: nothing here allocates per byte, waits, or reads the database.
    fn user_typed(&mut self, id: Uuid, bytes: Vec<u8>) -> Vec<u8> {
        let answering = self.is_awaiting_developer(id);
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id) else { return bytes };
        let passed = endpoint.line.typed(bytes, endpoint.delivering, !answering);
        endpoint.last_key = Some(Instant::now());
        if endpoint.line.has_draft() {
            self.schedule_idle_check(id);
        } else if endpoint.outbox.is_empty() {
            endpoint.forced = false;
        } else {
            // After the keystroke has gone to the program.
            self.store.handle.post(move |orchestrator: &mut Orchestrator, server| orchestrator.turn(server).board.deliver_next(id));
        }
        self.report_held(id);
        passed
    }

    /// Delivers what waits even though the user has text on the terminal's line; that text is
    /// submitted with the first one.
    fn deliver_held(&mut self, id: Uuid) {
        if let Some(endpoint) = self.agent_endpoints.get_mut(&id) {
            endpoint.forced = true;
            self.deliver_next(id);
        }
    }

    /// The program started, stopped or ended. A new program has a new, empty line; what waited
    /// for one that ended goes back (the composer's) or is reported to its sender, never typed
    /// into the next program out of context.
    fn session_changed(&mut self, id: Uuid, status: &SessionStatus) {
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id) else { return };
        endpoint.line = TerminalLine::default();
        endpoint.forced = false;
        if status.process_id.is_none() && status.state != State::Starting {
            let dropped = std::mem::take(&mut endpoint.outbox);
            let name = self.record(id).map(|record| record.name.clone()).unwrap_or_default();
            for item in dropped {
                if item.from_user {
                    self.give_back(id, &item.text, "it stopped before it could read it");
                } else if let Some(sender) = item.sender {
                    // The sender hears that its message never went in.
                    self.notice(sender, format!("Your message to {} wasn't delivered: it stopped before it could read it.", BoardName::quoted(&name)));
                }
            }
        }
        self.report_held(id);
    }

    fn schedule_idle_check(&mut self, id: Uuid) {
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id).filter(|endpoint| !endpoint.idle_check_scheduled && !endpoint.outbox.is_empty()) else { return };
        endpoint.idle_check_scheduled = true;
        self.store.handle.post_after(AgentEndpoint::IDLE_LIMIT + Duration::from_millis(100), move |orchestrator: &mut Orchestrator, server| {
            let mut turn = orchestrator.turn(server);
            if let Some(endpoint) = turn.agent_endpoints.get_mut(&id) {
                endpoint.idle_check_scheduled = false;
                turn.board.deliver_next(id);
            }
        });
    }

    /// Held while the agent waits on the developer; the store calls again once that changes.
    pub(crate) fn deliver_next(&mut self, id: Uuid) {
        self.deliver(id);
        self.report_held(id);
    }

    fn deliver(&mut self, id: Uuid) {
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id) else { return };
        if endpoint.outbox.is_empty() {
            endpoint.forced = false;
            return;
        }
        if endpoint.delivering || endpoint.gathering && endpoint.outbox.front().is_some_and(|next| next.from.is_some()) || self.is_awaiting_developer(id) || self.program_reason(id).is_some() {
            return;
        }
        let Some(session) = self.session(id) else { return };
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id) else { return };
        let idle = endpoint.last_key.is_none_or(|last| last.elapsed() >= AgentEndpoint::IDLE_LIMIT);
        if !(endpoint.forced || idle || !endpoint.line.has_draft()) {
            return self.schedule_idle_check(id);
        }
        let Some(mut next) = endpoint.outbox.pop_front() else { return };
        if let Some(name) = next.from.take() {
            let mut messages = vec![(name, std::mem::take(&mut next.text))];
            while let Some(more) = endpoint.outbox.pop_front_if(|more| more.from.is_some()) {
                messages.push((more.from.unwrap_or_default(), more.text));
            }
            next.text = Queued::prompt(&messages);
        }
        // Whatever was on the line goes in with this prompt.
        endpoint.line = TerminalLine::default();
        endpoint.delivering = true;
        let paste = session.with_terminal(|terminal| {
            let text = TerminalLine::pasteable(&next.text, terminal.modes().contains(TerminalModes::BRACKETED_PASTE));
            // A slash command is typed, not pasted, so the program runs it as if keyed in.
            if next.from_user && TerminalLine::is_command(&text) { text.into_bytes() } else { terminal.encode_paste(&text) }
        });
        session.send(paste);
        self.store.handle.post_after(AgentEndpoint::SUBMIT_DELAY, move |_: &mut Orchestrator, server| {
            session.send(vec![0x0D]);
            server.handle().post_after(AgentEndpoint::SUBMIT_DELAY, move |orchestrator: &mut Orchestrator, server| {
                let mut turn = orchestrator.turn(server);
                let Some(endpoint) = turn.agent_endpoints.get_mut(&id) else { return };
                endpoint.delivering = false;
                // What the user typed meanwhile goes in now, after the Enter.
                session.send(endpoint.line.release_held());
                turn.board.deliver_next(id);
            });
        });
    }

    /// Tells the boards how many messages wait on the user's terminal line.
    fn report_held(&mut self, id: Uuid) {
        let Some(endpoint) = self.agent_endpoints.get(&id) else { return };
        // The common case, on every keystroke: nothing waits and nothing was reported.
        let waiting = if endpoint.line.has_draft() && !endpoint.forced { endpoint.outbox.len() } else { 0 };
        if waiting == 0 && endpoint.reported_held == 0 {
            return;
        }
        let held = if self.program_reason(id).is_none() { waiting } else { 0 };
        let Some(endpoint) = self.store.agent_endpoints.get_mut(&id).filter(|endpoint| endpoint.reported_held != held) else { return };
        endpoint.reported_held = held;
        self.broadcast(&BoardEvent::Held { id, count: held as i64 }, None);
    }

    /// The attention queue or the pending questions changed: what waited on them may go.
    pub(crate) fn release_held_messages(&mut self) {
        let waiting: Vec<Uuid> = self.agent_endpoints.iter().filter(|(_, endpoint)| !endpoint.outbox.is_empty() || endpoint.forced || endpoint.reported_held != 0).map(|(id, _)| *id).collect();
        waiting.into_iter().for_each(|id| self.deliver_next(id));
    }
}

/// The user's side of an agent's terminal line, as the core sees their keystrokes: what they
/// typed and haven't submitted, edited the way a shell or Claude Code's input would.
#[derive(Default)]
pub struct TerminalLine {
    pending: String,
    /// Lone Escapes in a row; two clear the input.
    escapes: u8,
    held: Vec<u8>,
}

impl TerminalLine {
    const PASTE_START: &'static [u8] = b"\x1b[200~";

    /// Whether unsent text sits on the line: a paste now would join it.
    pub fn has_draft(&self) -> bool {
        self.pending.chars().any(|scalar| !scalar.is_whitespace())
    }

    /// Records `bytes`; returns what passes now. While `delivering`, all of it waits. With
    /// `writes_line` false (the program asked something), keys answer it and leave the line be.
    pub fn typed(&mut self, bytes: Vec<u8>, delivering: bool, writes_line: bool) -> Vec<u8> {
        if writes_line {
            self.record(&bytes);
        }
        if !delivering {
            return bytes;
        }
        self.held.extend_from_slice(&bytes);
        Vec::new()
    }

    fn record(&mut self, bytes: &[u8]) {
        if bytes.starts_with(Self::PASTE_START) {
            // A paste is text on the line, bracketed or not.
            self.escapes = 0;
            self.pending.push('\u{FFFC}');
            return;
        }
        if bytes == [0x1B] {
            self.escapes += 1;
            if self.escapes >= 2 {
                self.pending.clear();
                self.escapes = 0;
            }
            return;
        }
        self.escapes = 0;
        // Other escape sequences (arrows, focus and mouse reports) don't write on the line.
        if bytes.first() == Some(&0x1B) {
            return;
        }
        // Edited by scalar, where Swift edits by character: the same for all but a cluster of
        // several scalars half erased, which is still a draft either way.
        for scalar in String::from_utf8_lossy(bytes).chars() {
            match scalar as u32 {
                0x0D => {
                    // A backslash before Enter continues the input on a new line.
                    if self.pending.ends_with('\\') {
                        self.pending.pop();
                        self.pending.push('\n');
                    } else {
                        self.pending.clear();
                    }
                }
                0x03 | 0x15 => self.pending.clear(),
                0x7F | 0x08 => {
                    self.pending.pop();
                }
                0x17 => {
                    let kept = self.pending.trim_end().trim_end_matches(|scalar: char| !scalar.is_whitespace()).len();
                    self.pending.truncate(kept);
                }
                0..0x20 => {}
                _ => self.pending.push(scalar),
            }
        }
    }

    pub fn release_held(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.held)
    }

    /// `text` safe to paste: no control characters but line breaks and tabs, and on one line
    /// when the program doesn't bracket pastes (each break would be an Enter).
    /// `/effort high`, `/compact`…: one line starting with a slash.
    pub fn is_command(text: &str) -> bool {
        text.starts_with('/') && !text.contains(is_newline)
    }

    pub fn pasteable(text: &str, bracketed: bool) -> String {
        let clean: String = text.chars().filter(|scalar| *scalar == '\n' || *scalar == '\t' || !scalar.is_control()).collect();
        if bracketed {
            return clean;
        }
        clean.split(is_newline).filter(|line| !line.is_empty()).collect::<Vec<_>>().join(" ")
    }
}

// MARK: Boards

impl CoreService for Orchestrator {
    fn board_connected(&mut self, _server: &mut CoreServer<Self>, board: &CoreBoard) -> Option<Vec<u8>> {
        if !self.store.boards.contains(board) {
            self.store.boards.push(board.clone());
        }
        let store = &self.store;
        let state = BoardState {
            cards: store.cards.clone(),
            connections: self.bus.graph().connections().to_vec(),
            runners: store.reported_runners.clone(),
            post_its: Some(store.post_its.clone()),
            attention: Some(store.attention.clone()),
            images: Some(store.images.clone()),
            file_trees: Some(store.file_trees.clone()),
        };
        Some(state.encoded())
    }

    fn input(&mut self, server: &mut CoreServer<Self>, bytes: Vec<u8>, id: runtime::Uuid) -> Vec<u8> {
        self.turn(server).board.user_typed(from_runtime(id), bytes)
    }

    fn board_disconnected(&mut self, _server: &mut CoreServer<Self>, board: &CoreBoard) {
        self.store.boards.retain(|other| other != board);
        let calls: Vec<Uuid> = self.store.tool_calls.iter().filter(|(_, pending)| &pending.0 == board).map(|(call, _)| *call).collect();
        for call in calls {
            if let Some((_, reply)) = self.store.tool_calls.remove(&call) {
                reply.send(ToolResult::error("The board closed before the browser answered. Try again once it is open."));
            }
        }
    }

    fn received(&mut self, server: &mut CoreServer<Self>, payload: &[u8], board: &CoreBoard) {
        self.turn(server).received(payload, board);
    }

    fn session_notified(&mut self, server: &mut CoreServer<Self>, id: runtime::Uuid, notifications: Vec<String>) {
        self.turn(server).session_notified(from_runtime(id), &notifications);
    }

    fn session_status(&mut self, server: &mut CoreServer<Self>, id: runtime::Uuid, status: &SessionStatus) {
        let (id, mut turn) = (from_runtime(id), self.turn(server));
        turn.board.session_changed(id, status);
        // An agent whose program ended can't answer: it leaves Needs you.
        if status.process_id.is_none() && status.state != State::Starting {
            turn.dismiss_attention(id);
        }
    }
}

impl Turn<'_> {
    /// One request from the tool server: a tool call, a hook asking for context, or an agent
    /// saying it waits on the developer.
    fn serve(&mut self, request: Request) {
        let mut catalog = ToolCatalog::new();
        catalog.add(MessagingTools);
        catalog.add(RunnerTools);
        catalog.add(PostItTools);
        catalog.add(ImageTools::IMAGE);
        catalog.add(ImageTools::VIDEO);
        catalog.add(BrowserRelay);
        catalog.add(SimulatorRelay);
        catalog.add(ProjectRelay);
        catalog.add(WorktreeTools);
        catalog.add(CardTools);
        if let Some(request) = catalog.serve(self, request) {
            match request.kind {
                RequestKind::Question => self.ask(request),
                RequestKind::Attention => {
                    if let Ok(hook) = serde_json::from_slice::<AgentHook>(&request.body) {
                        self.hooked(request.caller, hook);
                    }
                }
                RequestKind::Rpc | RequestKind::Context => {}
            }
        }
        self.flush_bus();
    }

    /// Saves and tells the boards what the bus did: lines that changed, messages that travelled.
    pub(crate) fn flush_bus(&mut self) {
        let events = std::mem::take(&mut *self.bus_events.lock().unwrap());
        for event in events {
            match event {
                BusEvent::Graph(lines) => {
                    if !self.connections_read_only {
                        self.save(|database| database.save_connections(&lines));
                    }
                    self.broadcast(&BoardEvent::Connections(only(lines)), None);
                }
                BusEvent::Message(message) => self.broadcast(&BoardEvent::Message(only(message)), None),
            }
        }
    }

    /// Notes that `agent` put `element` on the board.
    pub(crate) fn made(&mut self, element: Uuid, agent: Uuid) {
        self.bus.makers.insert(element, agent);
        let flat: Vec<Uuid> = self.bus.makers.iter().flat_map(|(element, agent)| [*element, *agent]).collect();
        let _ = std::fs::write(self.data_folder.join("makers.json"), serde_json::to_vec(&flat).unwrap_or_default());
    }

    /// Draws a line between two elements.
    pub(crate) fn connect(&mut self, x: Uuid, y: Uuid) {
        self.bus.connect(x, y, (None, None));
        self.flush_bus();
    }

    /// Takes an element's lines off the board.
    fn disconnect_element(&mut self, id: Uuid) {
        self.bus.remove(id);
        self.flush_bus();
    }

    /// Sends `text` from `sender` to the connected element `recipient`.
    pub(crate) fn deliver(&mut self, text: &str, sender: Uuid, recipient: Uuid) -> Result<Message, MessageError> {
        let sent = self.bus.deliver(text, sender, recipient, &mut self.board);
        self.flush_bus();
        sent
    }

    fn received(&mut self, payload: &[u8], board: &CoreBoard) {
        let Some(request) = BoardRequest::decode(payload).map(BoardRequest::with_clean_names) else {
            (self.server.on_log)(&format!("ignored a board request this core doesn't know ({} bytes)", payload.len()));
            return;
        };
        let sender = Some(board);
        match request {
            BoardRequest::AddCard(Unlabelled { value: record }) => {
                if self.record(record.id).is_none() {
                    self.insert(record, sender);
                }
            }
            // Names reach agents' listings and prompts: one line of visible text, or the old one.
            BoardRequest::UpdateCard(Unlabelled { value: record }) => self.update(record.id, sender, |card| {
                let name = BoardName::clean(&record.name).unwrap_or_else(|| card.name.clone());
                *card = AgentRecord { name, ..record };
            }),
            BoardRequest::RemoveCard(Unlabelled { value: id }) => self.remove(id, sender),
            BoardRequest::Prompt { id, text } => self.board.prompt(id, &text),
            BoardRequest::DeliverHeld(Unlabelled { value: id }) => self.board.deliver_held(id),
            BoardRequest::Deliver { from, text, to } => {
                for peer in self.bus.peers(from, &self.board).into_iter().filter(|peer| peer.endpoint.is_some() && to.is_none_or(|to| to == peer.id)) {
                    let _ = self.deliver(&text, from, peer.id);
                }
            }
            BoardRequest::Connect(Unlabelled { value: connection }) => {
                // Only within one board: a line across organizations would let an agent read the
                // other's post-its.
                let board_of = |id| self.board.element(id).and_then(|element| element.board);
                if MessageBus::same_board(board_of(connection.a).as_deref(), board_of(connection.b).as_deref()) {
                    self.bus.add(connection);
                    self.flush_bus();
                }
            }
            BoardRequest::Disconnect(Unlabelled { value: id }) => {
                self.bus.disconnect(id);
                self.flush_bus();
            }
            BoardRequest::Elements(Unlabelled { value: list }) => {
                let listed: HashSet<Uuid> = list.iter().map(|info| info.id).collect();
                let gone: Vec<Uuid> = self.elements.keys().filter(|id| !listed.contains(id)).copied().collect();
                for id in gone {
                    self.elements.remove(&id);
                    self.disconnect_element(id);
                }
                self.elements.extend(list.into_iter().map(|info| (info.id, info)));
            }
            BoardRequest::Open { id, cols, rows, start } => {
                if self.record(id).is_none() {
                    return;
                }
                let fresh = self.session(id).is_none();
                let session = self.server.open_session(to_runtime(id), cols.clamp(1, 4096) as usize, rows.clamp(1, 4096) as usize, sender);
                if !fresh {
                    return;
                }
                if start {
                    self.launch(id);
                } else {
                    session.mark_stopped();
                }
            }
            BoardRequest::Restart { id, command } => {
                let Some(is_runner) = self.record(id).map(|record| record.runner.is_some()) else { return };
                if is_runner {
                    self.restart_runner(id, command);
                } else if self.session(id).is_some_and(|session| session.process_id().is_none()) {
                    self.launch(id);
                }
            }
            BoardRequest::StartRunner(Unlabelled { value: id }) => self.start_runner(id),
            BoardRequest::StopRunner(Unlabelled { value: id }) => self.stop_runner(id, None),
            BoardRequest::ToolResult { call, result } => {
                if let Some((_, reply)) = self.tool_calls.remove(&call) {
                    reply.send(result.result());
                }
            }
            BoardRequest::AddPostIt(Unlabelled { value: record }) => {
                if self.post_it(record.id).is_none() {
                    self.insert_post_it(record, sender);
                }
            }
            BoardRequest::UpdatePostIt(Unlabelled { value: record }) => self.update_post_it(record.id, sender, |note| {
                note.name = BoardName::clean(&record.name).unwrap_or_else(|| note.name.clone());
                note.frame = record.frame;
            }),
            BoardRequest::RemovePostIt(Unlabelled { value: id }) => self.remove_post_it(id, sender),
            BoardRequest::WritePostIt { id, text } => self.update_post_it(id, sender, |note| note.write(text, None, "")),
            BoardRequest::AddImage(Unlabelled { value: mut record }) => {
                // A plain file name inside the images folder, never a path out of it.
                if self.image(record.id).is_some() || !ImageFiles::is_plain_name(&record.file) || !ImageFiles::url(&record.file, &self.data_folder).exists() {
                    return;
                }
                // A dropped file's name reaches agents: no control or bidi characters.
                record.name = BoardName::clean(&record.name).unwrap_or_else(|| if record.is_video() { "Video" } else { "Image" }.to_string());
                self.insert_image(record, sender);
            }
            BoardRequest::UpdateImage(Unlabelled { value: record }) => self.update_image(record.id, sender, |image| {
                image.name = BoardName::clean(&record.name).unwrap_or_else(|| image.name.clone());
                image.frame = record.frame;
            }),
            BoardRequest::RemoveImage(Unlabelled { value: id }) => self.remove_image(id, sender),
            BoardRequest::AddFileTree(Unlabelled { value: record }) => {
                if self.file_tree(record.id).is_none() {
                    self.save(|database| database.save_file_tree(&record));
                    self.broadcast(&BoardEvent::FileTreeAdded(only(record.clone())), sender);
                    self.file_trees.push(record);
                }
            }
            BoardRequest::UpdateFileTree(Unlabelled { value: record }) => {
                let Some(tree) = self.board.store.file_trees.iter_mut().find(|tree| tree.id == record.id) else { return };
                tree.name = BoardName::clean(&record.name).unwrap_or_else(|| tree.name.clone());
                tree.frame = record.frame;
                let tree = tree.clone();
                self.save(|database| database.save_file_tree(&tree));
                self.broadcast(&BoardEvent::FileTreeUpdated(only(tree)), sender);
            }
            BoardRequest::RemoveFileTree(Unlabelled { value: id }) => {
                if self.file_tree(id).is_some() {
                    self.disconnect_element(id);
                    self.file_trees.retain(|tree| tree.id != id);
                    self.save(|database| database.delete_file_tree(id));
                    self.broadcast(&BoardEvent::FileTreeRemoved(only(id)), sender);
                }
            }
            BoardRequest::DismissAttention(Unlabelled { value: id }) => self.dismiss_attention(id),
            BoardRequest::AnswerQuestions { id, answers } => self.answer_questions(id, answers),
        }
    }

    /// Runs a tool only a board can (a browser's) on a connected one.
    pub(crate) fn relay(&mut self, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        let Some(board) = self.boards.first().cloned() else {
            let lives_in_sidebar = ["project_", "worktree_", "host_"].iter().any(|prefix| name.starts_with(prefix));
            let place = if lives_in_sidebar {
                "Projects live"
            } else if name.starts_with("simulator_") {
                "Simulators run"
            } else {
                "Browsers run"
            };
            return reply.send(ToolResult::error(format!("{place} in the board, which isn't open right now. Ask the user to open it, then try again.")));
        };
        let call = Uuid::new();
        let arguments = Data(serde_json::to_vec(arguments).unwrap_or_else(|_| b"{}".to_vec()));
        board.send(&BoardEvent::ToolCall { call, name: name.to_string(), arguments, caller }.encoded());
        self.tool_calls.insert(call, (board, reply));
    }

    // MARK: Cards

    /// Adds a card and saves it; boards other than `sender` hear of it.
    pub(crate) fn insert(&mut self, record: AgentRecord, sender: Option<&CoreBoard>) {
        self.register(record.id, record.runner.is_none());
        self.save(|database| database.save_agent(&record));
        self.broadcast(&BoardEvent::CardAdded(only(record.clone())), sender);
        self.cards.push(record);
    }

    /// Changes a card's record in place and saves it.
    pub(crate) fn update(&mut self, id: Uuid, sender: Option<&CoreBoard>, change: impl FnOnce(&mut AgentRecord)) {
        let Some(card) = self.board.store.cards.iter_mut().find(|card| card.id == id) else { return };
        change(card);
        let card = card.clone();
        self.save(|database| database.save_agent(&card));
        self.broadcast(&BoardEvent::CardUpdated(only(card)), sender);
    }

    pub(crate) fn remove(&mut self, id: Uuid, sender: Option<&CoreBoard>) {
        let Some(is_runner) = self.record(id).map(|record| record.runner.is_some()) else { return };
        self.server.close_session(to_runtime(id), is_runner.then_some(3.0));
        if is_runner {
            self.forget_runner(id);
        }
        self.disconnect_element(id);
        self.agent_endpoints.remove(&id);
        self.tool_server.revoke(id);
        self.cards.retain(|card| card.id != id);
        self.save(|database| database.delete_agent(id));
        self.broadcast(&BoardEvent::CardRemoved(only(id)), sender);
        self.dismiss_attention(id);
    }

    // MARK: Post-its

    /// Adds a post-it and saves it; boards other than `sender` hear of it.
    pub(crate) fn insert_post_it(&mut self, record: PostItRecord, sender: Option<&CoreBoard>) {
        self.save(|database| database.save_post_it(&record));
        self.broadcast(&BoardEvent::PostItAdded(only(record.clone())), sender);
        self.post_its.push(record);
    }

    /// Changes a post-it in place and saves it; boards other than `sender` hear of it (the
    /// sender already shows the change it sent).
    pub(crate) fn update_post_it(&mut self, id: Uuid, sender: Option<&CoreBoard>, change: impl FnOnce(&mut PostItRecord)) {
        let Some(note) = self.board.store.post_its.iter_mut().find(|note| note.id == id) else { return };
        let before = note.clone();
        change(note);
        if *note == before {
            return;
        }
        let note = note.clone();
        self.save(|database| database.save_post_it(&note));
        self.broadcast(&BoardEvent::PostItUpdated(only(note)), sender);
    }

    pub(crate) fn remove_post_it(&mut self, id: Uuid, sender: Option<&CoreBoard>) {
        if self.post_it(id).is_none() {
            return;
        }
        self.disconnect_element(id);
        self.post_its.retain(|note| note.id != id);
        self.save(|database| database.delete_post_it(id));
        self.broadcast(&BoardEvent::PostItRemoved(only(id)), sender);
    }

    // MARK: Images

    /// Adds an image and saves it; boards other than `sender` hear of it.
    pub(crate) fn insert_image(&mut self, record: ImageRecord, sender: Option<&CoreBoard>) {
        self.save(|database| database.save_image(&record));
        self.broadcast(&BoardEvent::ImageAdded(only(record.clone())), sender);
        self.images.push(record);
    }

    /// Changes an image in place and saves it; boards other than `sender` hear of it. A new
    /// `file` deletes the old one.
    pub(crate) fn update_image(&mut self, id: Uuid, sender: Option<&CoreBoard>, change: impl FnOnce(&mut ImageRecord)) {
        let Some(image) = self.board.store.images.iter_mut().find(|image| image.id == id) else { return };
        let before = image.clone();
        change(image);
        if *image == before {
            return;
        }
        let image = image.clone();
        if image.file != before.file {
            ImageFiles::remove(&before.file, &self.data_folder);
        }
        self.save(|database| database.save_image(&image));
        self.broadcast(&BoardEvent::ImageUpdated(only(image)), sender);
    }

    /// Forgets an image, its lines and its file.
    pub(crate) fn remove_image(&mut self, id: Uuid, sender: Option<&CoreBoard>) {
        let Some(file) = self.image(id).map(|image| image.file.clone()) else { return };
        self.disconnect_element(id);
        self.images.retain(|image| image.id != id);
        self.save(|database| database.delete_image(id));
        ImageFiles::remove(&file, &self.data_folder);
        self.broadcast(&BoardEvent::ImageRemoved(only(id)), sender);
    }

    // MARK: Launching

    pub(crate) fn launch_pending(&mut self) {
        if self.search_path.is_none() {
            return;
        }
        let pending = std::mem::take(&mut self.pending_launches);
        pending.into_iter().for_each(|id| self.launch(id));
    }

    /// Starts the card's program in its session.
    pub(crate) fn launch(&mut self, id: Uuid) {
        let (Some(record), Some(session)) = (self.record(id).cloned(), self.session(id)) else { return };
        let Some(search_path) = self.search_path.clone() else {
            if !self.pending_launches.contains(&id) {
                self.pending_launches.push(id);
            }
            return;
        };
        if let Some(runner) = &record.runner {
            return self.launch_runner(&record, runner, &session, &search_path);
        }
        let Some(provider) = self.providers.iter().find(|provider| provider.id() == record.provider_id).copied() else {
            return session.fail(l(&format!("Unknown agent “{}”.", record.provider_id)));
        };
        if !Path::new(&record.worktree).exists() {
            return session.fail(l("This worktree no longer exists on disk."));
        }
        let home = runtime::data_folder::home_directory();
        let Some(executable) = AgentCatalog::locate(provider.executable(), &search_path, &AgentCatalog::fallback_directories(&home.to_string_lossy())) else {
            return session.fail(match provider.install_command() {
                Some(install) => l(&format!("{} is not installed. Install it in a terminal with “{install}”, then click this card.", provider.title())),
                None => l(&format!("Could not find “{}” in your PATH.", provider.executable())),
            });
        };
        let mut environment = provider.environment(environment());
        // Found outside the PATH: its folder joins it, for scripts run through `env node` and the like.
        let folder = executable.rsplit_once('/').map_or("", |(folder, _)| folder);
        environment.insert("PATH".into(), if search_path.split(':').any(|listed| listed == folder) { search_path.clone() } else { format!("{search_path}:{folder}") });
        environment.insert("TERM".into(), "xterm-256color".into());
        environment.insert("COLORTERM".into(), "truecolor".into());
        environment.entry("LANG".into()).or_insert_with(|| "en_US.UTF-8".into());
        // The core's own settings aren't the agent's business: an agent running a build of
        // the board (`./run`) must not reach this core, or its data folder.
        environment.retain(|key, _| !key.starts_with("AGENTBOARD_"));
        // Signed in as the card's organization; `/login` in the terminal signs that one in.
        match prepare_organization(record.organization) {
            Some(folder) => environment.insert("CLAUDE_CONFIG_DIR".into(), folder.to_string_lossy().into_owned()),
            None => environment.remove("CLAUDE_CONFIG_DIR"),
        };
        let tools = self.tools_url.clone().map(|url| ToolServerLink { name: ToolCatalog::<()>::SERVER_NAME.to_string(), url, token: self.tool_server.token(record.id) });
        let arguments = provider.arguments(to_runtime(record.conversation.unwrap_or(record.id)), tools.as_ref());
        session.start(crate::sandbox::wrap(LaunchSpec { executable, arguments, environment, directory: record.worktree.clone() }, &record.worktree, &self.data_folder));
    }
}
