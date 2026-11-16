use std::collections::{HashMap, HashSet};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::agent_session::{AgentSession, State};
use crate::core_protocol::{self, CoreEvent, CoreRequest, Data, FrameKind, SessionStatus, Versions};
use crate::core_socket::{self, CoreSocket};
use crate::host_stats::HostSampler;
use crate::pseudo_terminal::{pipe, FORK_LOCK};
use crate::{data_folder, AgentCatalog, Uuid};

/// What the core does beyond running sessions: the board's cards, the lines between them and
/// the agents' tools (the orchestration crate). Every method is called on the main loop, with
/// the server to act on.
pub trait CoreService: Sized + 'static {
    /// A board said hello; the answer is the state it gets with its welcome.
    fn board_connected(&mut self, _server: &mut CoreServer<Self>, _board: &CoreBoard) -> Option<Vec<u8>> {
        None
    }
    /// A `service` frame from `board`.
    fn received(&mut self, _server: &mut CoreServer<Self>, _payload: &[u8], _board: &CoreBoard) {}
    fn board_disconnected(&mut self, _server: &mut CoreServer<Self>, _board: &CoreBoard) {}
    /// Session `id`'s program sent desktop notifications (OSC 9 or 777).
    fn session_notified(&mut self, _server: &mut CoreServer<Self>, _id: Uuid, _notifications: Vec<String>) {}
    /// What a board typed into session `id`: returns what to pass to it now (all of it by default).
    fn input(&mut self, _server: &mut CoreServer<Self>, bytes: Vec<u8>, _id: Uuid) -> Vec<u8> {
        bytes
    }
    /// Every session's status change (`onSessionStatus` in Swift).
    fn session_status(&mut self, _server: &mut CoreServer<Self>, _id: Uuid, _status: &SessionStatus) {}
}

/// A core that only runs sessions.
impl CoreService for () {}

type Body<S> = Box<dyn FnOnce(&mut S, &mut CoreServer<S>) + Send>;

enum Event<S: CoreService> {
    Accepted(UnixStream),
    Frame(u64, FrameKind, Vec<u8>),
    Disconnected(u64),
    SessionStatus(Uuid, SessionStatus),
    Notified(Uuid, Vec<String>),
    Post(Body<S>),
    After(Instant, Body<S>),
    Stop,
}

/// Reaches the main loop from any thread.
pub struct CoreHandle<S: CoreService> {
    events: Sender<Event<S>>,
}

impl<S: CoreService> Clone for CoreHandle<S> {
    fn clone(&self) -> Self {
        Self { events: self.events.clone() }
    }
}

impl<S: CoreService> CoreHandle<S> {
    /// Runs `body` on the main loop, after what was posted before it.
    pub fn post(&self, body: impl FnOnce(&mut S, &mut CoreServer<S>) + Send + 'static) {
        let _ = self.events.send(Event::Post(Box::new(body)));
    }

    /// Runs `body` on the main loop once `delay` has passed: the service's timers.
    pub fn post_after(&self, delay: Duration, body: impl FnOnce(&mut S, &mut CoreServer<S>) + Send + 'static) {
        let _ = self.events.send(Event::After(Instant::now() + delay, Box::new(body)));
    }

    /// Makes `run` return, leaving the programs to end with the process.
    pub fn stop(&self) {
        let _ = self.events.send(Event::Stop);
    }
}

/// The core: owns the agents' sessions and serves them to boards over a Unix socket. Programs
/// keep running while no board is connected; a board that connects later attaches to them.
pub struct CoreServer<S: CoreService = ()> {
    path: String,
    events: Receiver<Event<S>>,
    handle: CoreHandle<S>,
    timers: Vec<(Instant, Body<S>)>,
    /// Out of here only while one of its methods runs.
    service: Option<S>,
    /// Closing it ends the thread that accepts boards, and with it the listening socket.
    listener: Option<OwnedFd>,
    sessions: HashMap<Uuid, Arc<Hosted>>,
    /// Sessions being closed, kept until their program has exited.
    closing: HashMap<Uuid, Arc<Hosted>>,
    clients: HashMap<u64, CoreBoard>,
    boards_accepted: u64,
    /// Logs each session a board attaches to as well (`AGENTBOARD_CORE_VERBOSE=1`).
    verbose: bool,
    idle_checks: u32,
    /// How long the core lingers with no board connected and no program running.
    idle_timeout: f64,
    exiting: bool,
    /// Programs still to end before a shutdown exits.
    ending: usize,
    host: HostSampler,
    host_timer: bool,
    /// Called with what's worth a line in the core's log.
    pub on_log: Box<dyn Fn(&str)>,
    /// The protocol versions this core speaks (another build's, in tests).
    pub versions: Versions,
    /// Where `run` looks a bare program name up: the system's folders and the host's private
    /// toolchain, never a folder the programs of a worktree can write (`~/.local/bin`), or
    /// they would choose what a board runs.
    pub run_path: String,
    /// Puts a program a board runs about a folder (the folder, the program, its arguments, where
    /// it runs) in that folder's sandbox, when the service has one for it.
    pub run_sandbox: Option<RunSandbox>,
}

pub type RunSandbox = std::sync::Arc<dyn Fn(&str, String, Vec<String>, Option<&str>) -> (String, Vec<String>) + Send + Sync>;

impl<S: CoreService> CoreServer<S> {
    pub fn new(socket_path: impl Into<String>, idle_timeout: f64) -> Self {
        let (events, receiver) = channel();
        Self {
            path: socket_path.into(),
            events: receiver,
            handle: CoreHandle { events },
            timers: Vec::new(),
            service: None,
            listener: None,
            sessions: HashMap::new(),
            closing: HashMap::new(),
            clients: HashMap::new(),
            boards_accepted: 0,
            verbose: std::env::var("AGENTBOARD_CORE_VERBOSE").as_deref() == Ok("1"),
            idle_checks: 0,
            idle_timeout,
            exiting: false,
            ending: 0,
            host: HostSampler::default(),
            host_timer: false,
            on_log: Box::new(|_| {}),
            versions: core_protocol::VERSIONS,
            run_path: format!("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:{}", data_folder::url().join("tools/env/bin").display()),
            run_sandbox: None,
        }
    }

    pub fn handle(&self) -> CoreHandle<S> {
        self.handle.clone()
    }

    pub fn socket_path(&self) -> &str {
        &self.path
    }

    /// Listens on the socket; boards are served once `run` is called.
    pub fn start(&mut self) -> io::Result<()> {
        core_socket::ignore_sigpipe();
        raise_descriptor_limit();
        let listener = core_socket::listen(&self.path)?;
        listener.set_nonblocking(true)?;
        let (stopped, stop) = pipe()?;
        let events = self.handle.events.clone();
        std::thread::Builder::new().name("agentboard.accept".into()).spawn(move || loop {
            let mut fds = [libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 }, libc::pollfd { fd: stopped.as_raw_fd(), events: libc::POLLIN, revents: 0 }];
            // SAFETY: `fds` is a live array of two pollfds.
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
            // The server let go of its end: stop listening.
            if fds[1].revents != 0 {
                return;
            }
            if ready <= 0 {
                continue;
            }
            while let Ok((stream, _)) = listener.accept() {
                // On BSDs a connection inherits the listener's non-blocking mode.
                if stream.set_nonblocking(false).is_err() || events.send(Event::Accepted(stream)).is_err() {
                    return;
                }
            }
        })?;
        self.listener = Some(stop);
        self.schedule_idle_check();
        Ok(())
    }

    /// The main loop: serves boards and runs what `CoreHandle` posts, with `service` taking the
    /// boards' frames. Returns when the core should exit: asked to (`shutdown`), idle for too
    /// long, or stopped through its handle. The socket file is the caller's to remove.
    pub fn run(mut self, service: S) {
        self.service = Some(service);
        while !self.exiting {
            let now = Instant::now();
            let next = self.timers.iter().enumerate().min_by_key(|(_, timer)| timer.0).map(|(index, timer)| (index, timer.0));
            let event = match next {
                Some((index, deadline)) if deadline <= now => Event::Post(self.timers.swap_remove(index).1),
                Some((_, deadline)) => match self.events.recv_timeout(deadline - now) {
                    Ok(event) => event,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break,
                },
                None => match self.events.recv() {
                    Ok(event) => event,
                    Err(_) => break,
                },
            };
            self.handle_event(event);
        }
        self.listener = None;
        self.clients.values().for_each(|client| client.inner.socket.close());
    }

    fn with_service<T>(&mut self, body: impl FnOnce(&mut S, &mut Self) -> T) -> T {
        let mut service = self.service.take().expect("the service called back into itself");
        let result = body(&mut service, self);
        self.service = Some(service);
        result
    }

    fn handle_event(&mut self, event: Event<S>) {
        match event {
            Event::Accepted(stream) => self.accepted(stream),
            Event::Frame(key, kind, payload) => {
                if let Some(client) = self.clients.get(&key).cloned() {
                    self.received(kind, payload, &client);
                }
            }
            Event::Disconnected(key) => self.disconnected(key),
            Event::SessionStatus(id, status) => {
                // Subscribed boards hear every status, not only those mirroring the session: a
                // board lists the states of cards it hasn't opened (its sidebar).
                let Some(hosted) = self.sessions.get(&id).or_else(|| self.closing.get(&id)).cloned() else { return };
                self.with_service(|service, server| service.session_status(server, id, &status));
                let event = CoreEvent::Status { id, status };
                for client in self.clients.values().filter(|client| client.inner.hears_all_statuses.load(Ordering::Relaxed) && !hosted.has(client)) {
                    client.inner.socket.send_message(&event);
                }
            }
            Event::Notified(id, notifications) => self.with_service(|service, server| service.session_notified(server, id, notifications)),
            Event::Post(body) => self.with_service(body),
            Event::After(deadline, body) => self.timers.push((deadline, body)),
            Event::Stop => self.exiting = true,
        }
    }

    /// Wraps a session for serving; its statuses and notifications come to the main loop.
    fn hosted(&self, id: Uuid, session: AgentSession) -> Arc<Hosted> {
        let events = self.handle.events.clone();
        session.set_on_notify(move |notifications| {
            let _ = events.send(Event::Notified(id, notifications));
        });
        let events = self.handle.events.clone();
        Hosted::new(id, session, move |status| {
            let _ = events.send(Event::SessionStatus(id, status));
        })
    }

    // MARK: For the service (on the main loop)

    pub fn boards(&self) -> Vec<CoreBoard> {
        self.clients.values().cloned().collect()
    }

    pub fn session(&self, id: Uuid) -> Option<AgentSession> {
        self.sessions.get(&id).map(|hosted| hosted.session.clone())
    }

    /// Session `id`, created at `cols`×`rows` when the core doesn't have it. `board`, when
    /// given, is attached to it (status, then snapshot, then output) unless it already is.
    pub fn open_session(&mut self, id: Uuid, cols: usize, rows: usize, board: Option<&CoreBoard>) -> AgentSession {
        let hosted = match self.sessions.get(&id) {
            Some(hosted) => hosted.clone(),
            None => {
                let hosted = self.hosted(id, AgentSession::new(cols, rows));
                self.sessions.insert(id, hosted.clone());
                hosted
            }
        };
        if let Some(board) = board.filter(|board| !hosted.has(board)) {
            self.attach(board, &hosted);
        }
        hosted.session.clone()
    }

    /// Ends the program of session `id` (`grace` as in `AgentSession::terminate`, or SIGHUP
    /// when none) and forgets the session.
    pub fn close_session(&mut self, id: Uuid, grace: Option<f64>) {
        let Some(hosted) = self.sessions.remove(&id) else { return };
        hosted.remove_all();
        if hosted.session.process_id().is_none() {
            return;
        }
        self.closing.insert(id, hosted.clone());
        let handle = self.handle();
        let forget = Box::new(move || {
            handle.post(move |_, server| {
                server.closing.remove(&id);
            })
        });
        match grace {
            Some(grace) => hosted.session.terminate(grace, Some(forget)),
            None => {
                hosted.lock.lock().unwrap().on_ended = Some(forget);
                hosted.session.stop();
            }
        }
    }

    // MARK: On the main loop

    fn accepted(&mut self, stream: UnixStream) {
        core_socket::no_sigpipe(&stream);
        self.boards_accepted += 1;
        let key = self.boards_accepted;
        let client = CoreBoard {
            inner: Arc::new(BoardInner { socket: CoreSocket::new(stream), number: key, version: AtomicI64::new(0), hears_all_statuses: AtomicBool::new(false), hears_host: AtomicBool::new(false) }),
        };
        let (frames, closed) = (self.handle.events.clone(), self.handle.events.clone());
        client.inner.socket.start(
            move |kind, payload| {
                let _ = frames.send(Event::Frame(key, kind, payload.to_vec()));
            },
            move || {
                let _ = closed.send(Event::Disconnected(key));
            },
        );
        self.clients.insert(key, client);
    }

    fn disconnected(&mut self, key: u64) {
        let Some(client) = self.clients.remove(&key) else { return };
        if client.version().is_some() {
            (self.on_log)(&format!("board {} went away", client.number()));
        }
        self.sessions.values().for_each(|hosted| hosted.remove(&client));
        self.with_service(|service, server| service.board_disconnected(server, &client));
    }

    fn received(&mut self, kind: FrameKind, payload: Vec<u8>, client: &CoreBoard) {
        match kind {
            FrameKind::Control => {
                // An unknown request (a newer board's) is dropped.
                if let Ok(request) = serde_json::from_slice(&payload) {
                    self.handle_request(request, client);
                }
            }
            FrameKind::Data => {
                let Some(id) = Uuid::from_prefix(&payload) else { return };
                let passed = self.with_service(|service, server| service.input(server, payload[16..].to_vec(), id));
                if let Some(hosted) = self.sessions.get(&id) {
                    hosted.session.send(passed);
                }
            }
            FrameKind::Service => self.with_service(|service, server| service.received(server, &payload, client)),
            FrameKind::Snapshot => {}
        }
    }

    fn handle_request(&mut self, request: CoreRequest, client: &CoreBoard) {
        let socket = &client.inner.socket;
        match request {
            CoreRequest::Hello { version, oldest } => {
                let Some(agreed) = self.versions.agreed(Versions { version, oldest: oldest.unwrap_or(version) }) else {
                    // It hangs up on seeing the version; closing here could drop the welcome unsent.
                    return socket.send_message(&CoreEvent::Welcome { version: self.versions.version, oldest: Some(self.versions.oldest), sessions: Vec::new(), service: None });
                };
                client.inner.version.store(agreed, Ordering::Relaxed);
                (self.on_log)(&format!("board {} connected, protocol {agreed}", client.number()));
                let state = self.with_service(|service, server| service.board_connected(server, client));
                let sessions = self.sessions.iter().map(|(id, hosted)| (*id, hosted.session.status())).collect();
                socket.send_message(&CoreEvent::Welcome { version: agreed, oldest: Some(self.versions.oldest), sessions, service: state.map(Data) });
            }
            CoreRequest::Start { id, spec, cols, rows } => {
                let (cols, rows) = (size(cols), size(rows));
                let hosted = match self.sessions.get(&id).cloned() {
                    Some(hosted) => {
                        if !hosted.has(client) {
                            self.attach(client, &hosted);
                        }
                        hosted
                    }
                    None => {
                        let hosted = self.hosted(id, AgentSession::new(cols, rows));
                        self.sessions.insert(id, hosted.clone());
                        hosted.add(client);
                        hosted
                    }
                };
                hosted.session.resize(cols, rows);
                hosted.session.start(spec);
            }
            CoreRequest::SubscribeStatuses {} => client.inner.hears_all_statuses.store(true, Ordering::Relaxed),
            CoreRequest::Attach { id } => match self.sessions.get(&id).cloned() {
                Some(hosted) => self.attach(client, &hosted),
                None => socket.send_message(&CoreEvent::Status { id, status: SessionStatus { state: State::Stopped, process_id: None, exit_code: None } }),
            },
            CoreRequest::Resize { id, cols, rows } => {
                if let Some(hosted) = self.sessions.get(&id) {
                    hosted.session.resize(size(cols), size(rows));
                }
            }
            CoreRequest::Observe { id, observed } => {
                if let Some(hosted) = self.sessions.get(&id) {
                    hosted.observe(observed, client);
                }
            }
            CoreRequest::Terminate { id, grace } => {
                let Some(hosted) = self.sessions.get(&id) else { return };
                let ended = Arc::downgrade(hosted);
                // An exit already reported changes no status; send one anyway so the board's wait ends.
                hosted.session.terminate(
                    grace,
                    Some(Box::new(move || {
                        if let Some(hosted) = ended.upgrade() {
                            hosted.broadcast_status();
                        }
                    })),
                );
            }
            CoreRequest::Stop { id } => {
                if let Some(hosted) = self.sessions.get(&id) {
                    hosted.session.stop();
                }
            }
            CoreRequest::Annotate { id, text, fresh_line } => {
                if let Some(hosted) = self.sessions.get(&id) {
                    hosted.session.annotate(&text, fresh_line);
                }
            }
            CoreRequest::Close { id, grace } => self.close_session(id, grace),
            CoreRequest::Shutdown {} => self.shut_down(),
            // shortcut: no handoff to a newer core (CoreHandoff, `adopt`): one asking is turned
            // away. Port it when a running Rust core must be replaced without ending its programs.
            CoreRequest::TakeOver {} => socket.close(),
            CoreRequest::Run { call, executable, arguments, directory, input } => {
                let socket = socket.clone();
                let (run_path, sandbox) = (self.run_path.clone(), self.run_sandbox.clone());
                // Off the main loop: the program may take as long as it likes.
                let spawned = std::thread::Builder::new().name("agentboard.run".into()).spawn(move || {
                    let (status, output, error) = run(&executable, arguments, directory.as_deref(), input.map(|input| input.0), &run_path, sandbox);
                    socket.send_message(&CoreEvent::Ran { call, status, output: Data(output), error: Data(error) });
                });
                if let Err(error) = spawned {
                    client.inner.socket.send_message(&CoreEvent::Ran { call, status: -1, output: Data::default(), error: Data(crate::error_text(&error).into_bytes()) });
                }
            }
            CoreRequest::SubscribeHost {} => {
                client.inner.hears_host.store(true, Ordering::Relaxed);
                socket.send_message(&CoreEvent::Host { stats: self.host.sample() });
                self.schedule_host_stats();
            }
        }
    }

    /// Sends `client` the session's status and then its screen, and from then on its output.
    /// The snapshot is taken with the terminal locked and the client subscribed in the same
    /// step, so no output falls between them or arrives twice.
    fn attach(&self, client: &CoreBoard, hosted: &Arc<Hosted>) {
        if self.verbose {
            (self.on_log)(&format!("board {} attached to {}", client.number(), hosted.id));
        }
        client.inner.socket.send_message(&CoreEvent::Status { id: hosted.id, status: hosted.session.status() });
        hosted.session.with_terminal(|terminal| {
            client.inner.socket.send_to(FrameKind::Snapshot, hosted.id, &terminal.snapshot());
            hosted.add(client);
        });
    }

    fn shut_down(&mut self) {
        // Held until they exit: a session let go earlier would never report its program's end.
        let sessions: Vec<_> = self.sessions.drain().collect();
        self.closing.extend(sessions);
        let running: Vec<_> = self.closing.values().filter(|hosted| hosted.session.process_id().is_some()).cloned().collect();
        if running.is_empty() {
            return self.exit();
        }
        self.ending = running.len();
        for hosted in running {
            hosted.remove_all();
            let handle = self.handle();
            hosted.session.terminate(
                2.0,
                Some(Box::new(move || {
                    handle.post(|_, server| {
                        server.ending -= 1;
                        if server.ending == 0 {
                            server.exit();
                        }
                    })
                })),
            );
        }
        // Whatever ignores even SIGKILL's aftermath must not keep the core alive.
        self.handle.post_after(Duration::from_secs(4), |_, server| server.exit());
    }

    fn exit(&mut self) {
        self.exiting = true;
    }

    /// Exits after `idle_timeout` with no board connected and nothing running. Programs that
    /// ended are then lost, which is what a relaunch without a core would do anyway.
    fn schedule_idle_check(&mut self) {
        let interval = Duration::from_secs_f64((self.idle_timeout / 4.0).max(0.05));
        self.handle.post_after(interval, |_, server| {
            let idle = server.clients.is_empty() && server.closing.is_empty() && server.sessions.values().all(|hosted| hosted.session.process_id().is_none());
            server.idle_checks = if idle { server.idle_checks + 1 } else { 0 };
            if server.idle_checks >= 4 {
                return server.exit();
            }
            server.schedule_idle_check();
        });
    }

    /// Sends the machine's stats to the boards that asked, every 2 seconds while any does.
    fn schedule_host_stats(&mut self) {
        if std::mem::replace(&mut self.host_timer, true) {
            return;
        }
        self.handle.post_after(Duration::from_secs(2), |_, server| {
            server.host_timer = false;
            let listeners: Vec<_> = server.clients.values().filter(|client| client.inner.hears_host.load(Ordering::Relaxed)).cloned().collect();
            if listeners.is_empty() {
                return;
            }
            let event = CoreEvent::Host { stats: server.host.sample() };
            listeners.iter().for_each(|client| client.inner.socket.send_message(&event));
            server.schedule_host_stats();
        });
    }
}

/// A terminal dimension a board asked for, kept within what a PTY and memory can take.
fn size(asked: i64) -> usize {
    asked.clamp(1, 4096) as usize
}

/// Sessions cost three descriptors each (the PTY and a wake-up pipe) and boards one; the
/// default soft limit (256 for a macOS service) would cap a busy core.
fn raise_descriptor_limit() {
    // SAFETY: both calls read or write an rlimit that outlives them.
    unsafe {
        let mut limit: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 && limit.rlim_cur < 8192 {
            limit.rlim_cur = limit.rlim_max.min(8192);
            libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
        }
    }
}

/// The most of a program's output (and of its errors) a `ran` carries; the rest is dropped.
const RUN_OUTPUT_LIMIT: usize = 64 * 1024 * 1024;

/// Runs `executable` with exactly `arguments` (no shell), `input` to read (nothing when none),
/// and returns its exit code (or the signal that ended it) and what it printed; -1 and why when
/// it couldn't start. A name without a slash is looked up in `search_path`.
/// How long a program `run` started may take (a large clone, a slow fetch).
const RUN_LIMIT: Duration = Duration::from_secs(15 * 60);

fn run(executable: &str, arguments: Vec<String>, directory: Option<&str>, input: Option<Vec<u8>>, run_path: &str, sandbox: Option<RunSandbox>) -> (i32, Vec<u8>, Vec<u8>) {
    let located = if executable.contains('/') {
        Some(executable.to_string())
    } else if executable == "agentboard" {
        std::env::current_exe().ok().map(|path| path.to_string_lossy().into_owned())
    } else {
        AgentCatalog::locate(executable, run_path, &[])
    };
    let Some(located) = located else { return (-1, Vec::new(), format!("{executable}: command not found").into_bytes()) };
    // What the program is about: where it runs, or the folder git is pointed at.
    let about = directory.map(String::from).or_else(|| match &arguments[..] {
        [flag, folder, ..] if flag == "-C" && executable == "git" => Some(folder.clone()),
        _ => None,
    });
    let (located, arguments) = match (sandbox, about) {
        (Some(sandbox), Some(about)) => sandbox(&about, located, arguments, directory),
        _ => (located, arguments),
    };
    let mut command = Command::new(located);
    command.args(&arguments).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    // Nobody is there to answer a question: git says what it lacks instead of waiting for it.
    command.env("GIT_TERMINAL_PROMPT", "0");
    if std::env::var_os("GIT_SSH_COMMAND").is_none() {
        command.env("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new");
    }
    let spawned = {
        let _forking = FORK_LOCK.lock().unwrap();
        command.spawn()
    };
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return (-1, Vec::new(), crate::error_text(&error).into_bytes()),
    };
    // Written on a thread of its own: a program that doesn't read must not hold the readers up.
    // Dropping the pipe when done is the program's end-of-file.
    if let (Some(mut pipe), Some(input)) = (child.stdin.take(), input) {
        std::thread::spawn(move || {
            let _ = io::Write::write_all(&mut pipe, &input);
        });
    }
    // A program that never ends must not hold its board's request forever.
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    std::thread::spawn({
        let (done, pid) = (done.clone(), child.id() as libc::pid_t);
        move || {
            let deadline = std::time::Instant::now() + RUN_LIMIT;
            while std::time::Instant::now() < deadline && !done.load(std::sync::atomic::Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(200));
            }
            if !done.load(std::sync::atomic::Ordering::SeqCst) {
                // SAFETY: a signal to the child this function still waits for (not reaped yet).
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
    });
    // Read on a thread of its own, so a program filling one pipe can't block on the other.
    let output = child.stdout.take().map(|pipe| std::thread::spawn(move || read_to_limit(pipe)));
    let error = child.stderr.take().map(read_to_limit).unwrap_or_default();
    let output = output.and_then(|reading| reading.join().ok()).unwrap_or_default();
    let ended = child.wait();
    done.store(true, std::sync::atomic::Ordering::SeqCst);
    match ended {
        Ok(status) => (status.code().or(status.signal()).unwrap_or(-1), output, error),
        Err(failure) => (-1, output, crate::error_text(&failure).into_bytes()),
    }
}

/// Everything `pipe` gives up to the limit; what comes after is read and dropped, so the
/// program never blocks on a full pipe.
fn read_to_limit(mut pipe: impl Read) -> Vec<u8> {
    let mut read = Vec::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => return read,
            Ok(count) => read.extend_from_slice(&buffer[..count.min(RUN_OUTPUT_LIMIT - read.len())]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return read,
        }
    }
}

/// A board connected to the core.
#[derive(Clone)]
pub struct CoreBoard {
    inner: Arc<BoardInner>,
}

struct BoardInner {
    socket: CoreSocket,
    /// In the order the core accepted boards, for its log.
    number: u64,
    /// The protocol version agreed on with it, once it said hello; 0 before.
    version: AtomicI64,
    /// Set by `subscribeStatuses`: it then hears every session's status. Other clients (an
    /// agent's own connection) never get events they didn't ask for.
    hears_all_statuses: AtomicBool,
    /// Set by `subscribeHost`.
    hears_host: AtomicBool,
}

impl CoreBoard {
    /// Sends the board a frame for its side of the service.
    pub fn send(&self, payload: &[u8]) {
        self.inner.socket.send(FrameKind::Service, payload);
    }

    /// The protocol version agreed on with it, once it said hello.
    pub fn version(&self) -> Option<i64> {
        Some(self.inner.version.load(Ordering::Relaxed)).filter(|version| *version != 0)
    }

    pub fn number(&self) -> u64 {
        self.inner.number
    }
}

impl PartialEq for CoreBoard {
    fn eq(&self, other: &Self) -> bool {
        self.inner.number == other.inner.number
    }
}

impl Eq for CoreBoard {}

impl std::hash::Hash for CoreBoard {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.inner.number.hash(state);
    }
}

/// A session on the core and the boards mirroring it. Output is fanned out from the session's
/// thread, so the subscriber list has its own lock (taken inside the terminal's, never around it).
struct Hosted {
    id: Uuid,
    session: AgentSession,
    lock: Mutex<Subscribers>,
}

#[derive(Default)]
struct Subscribers {
    subscribers: HashMap<u64, CoreBoard>,
    observers: HashSet<u64>,
    /// Called once the program has ended (set by `close_session`).
    on_ended: Option<Box<dyn FnOnce() + Send>>,
}

impl Hosted {
    /// `on_status_for_others` hears every status too, for the boards that don't mirror the session.
    fn new(id: Uuid, session: AgentSession, on_status_for_others: impl Fn(SessionStatus) + Send + Sync + 'static) -> Arc<Self> {
        let hosted = Arc::new(Self { id, session, lock: Mutex::default() });
        let output = Arc::downgrade(&hosted);
        hosted.session.set_on_output(move |bytes| {
            if let Some(hosted) = output.upgrade() {
                hosted.broadcast(bytes);
            }
        });
        let weak = Arc::downgrade(&hosted);
        hosted.session.set_on_status(move |status| {
            let Some(hosted) = weak.upgrade() else { return };
            let ended = status.process_id.is_none() && status.state != State::Starting;
            hosted.send(&CoreEvent::Status { id, status: status.clone() });
            on_status_for_others(status);
            let on_ended = if ended { hosted.lock.lock().unwrap().on_ended.take() } else { None };
            if let Some(on_ended) = on_ended {
                on_ended();
            }
        });
        hosted
    }

    fn has(&self, client: &CoreBoard) -> bool {
        self.lock.lock().unwrap().subscribers.contains_key(&client.number())
    }

    fn add(&self, client: &CoreBoard) {
        self.lock.lock().unwrap().subscribers.insert(client.number(), client.clone());
    }

    fn remove(&self, client: &CoreBoard) {
        let observed = {
            let mut locked = self.lock.lock().unwrap();
            locked.subscribers.remove(&client.number());
            locked.observers.remove(&client.number());
            !locked.observers.is_empty()
        };
        self.session.set_observed(observed);
    }

    fn remove_all(&self) {
        {
            let mut locked = self.lock.lock().unwrap();
            locked.subscribers.clear();
            locked.observers.clear();
        }
        self.session.set_observed(false);
    }

    /// Output is read sooner while any board shows the session.
    fn observe(&self, observed: bool, client: &CoreBoard) {
        let any = {
            let mut locked = self.lock.lock().unwrap();
            if observed {
                locked.observers.insert(client.number());
            } else {
                locked.observers.remove(&client.number());
            }
            !locked.observers.is_empty()
        };
        self.session.set_observed(any);
    }

    fn broadcast_status(&self) {
        self.send(&CoreEvent::Status { id: self.id, status: self.session.status() });
    }

    /// Called with the terminal locked: each board's socket takes the bytes or queues them,
    /// without waiting.
    fn broadcast(&self, bytes: &[u8]) {
        for client in self.lock.lock().unwrap().subscribers.values() {
            client.inner.socket.send_to(FrameKind::Data, self.id, bytes);
        }
    }

    fn send(&self, event: &CoreEvent) {
        let Ok(json) = serde_json::to_vec(event) else { return };
        for client in self.lock.lock().unwrap().subscribers.values() {
            client.inner.socket.send(FrameKind::Control, &json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_program_printing_without_end_is_cut_at_the_limit() {
        let endless = io::repeat(7).take(RUN_OUTPUT_LIMIT as u64 + 100_000);
        assert_eq!(read_to_limit(endless).len(), RUN_OUTPUT_LIMIT);
        assert_eq!(read_to_limit(&b"short"[..]), b"short");
    }
}
