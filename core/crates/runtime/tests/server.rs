//! The core over its socket, as a board sees it: frames in, frames out.

use std::collections::HashMap;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use runtime::{core_socket, CoreBoard, CoreEvent, CoreHandle, CoreRequest, CoreServer, CoreService, CoreSocket, Data, FrameKind, LaunchSpec, SessionStatus, State, Uuid};
use terminal::Terminal;

const TIMEOUT: Duration = Duration::from_secs(15);

fn script(text: &str) -> LaunchSpec {
    let environment: HashMap<String, String> = [("PATH", "/usr/bin:/bin"), ("TERM", "xterm-256color")].map(|(key, value)| (key.to_string(), value.to_string())).into();
    LaunchSpec { executable: "/bin/sh".into(), arguments: vec!["-c".into(), text.into()], environment, directory: std::env::temp_dir().to_string_lossy().into_owned() }
}

/// A core on a socket of its own, running on a thread until dropped.
struct Fixture<S: CoreService = ()> {
    path: String,
    handle: CoreHandle<S>,
    running: Option<JoinHandle<()>>,
}

impl Fixture {
    fn new() -> Self {
        Self::with(60.0, |_| ())
    }
}

impl<S: CoreService> Fixture<S> {
    fn with(idle_timeout: f64, service: impl FnOnce(CoreHandle<S>) -> S + Send + 'static) -> Self {
        let path = std::env::temp_dir().join(format!("abcore-{}.sock", &Uuid::new().to_string()[..8])).to_string_lossy().into_owned();
        let (ready, started) = channel();
        let socket_path = path.clone();
        // The server is made on the thread that runs it: it never leaves its main loop's thread.
        let running = std::thread::spawn(move || {
            let mut server = CoreServer::new(socket_path, idle_timeout);
            server.start().unwrap();
            let handle = server.handle();
            ready.send(handle.clone()).unwrap();
            server.run(service(handle));
        });
        Self { path, handle: started.recv().unwrap(), running: Some(running) }
    }

    /// The core's own terminal for session `id`, as a snapshot.
    fn snapshot(&self, id: Uuid) -> Vec<u8> {
        let (sender, snapshot) = channel();
        self.handle.post(move |_, server| sender.send(server.session(id).map(|session| session.with_terminal(|terminal| terminal.snapshot()))).unwrap());
        snapshot.recv_timeout(TIMEOUT).unwrap().expect("the core has the session")
    }

    /// Waits for the main loop to return by itself.
    fn exited(&mut self, within: Duration) -> bool {
        let deadline = Instant::now() + within;
        let running = self.running.as_ref().unwrap();
        while !running.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        running.is_finished()
    }
}

impl<S: CoreService> Drop for Fixture<S> {
    fn drop(&mut self) {
        self.handle.stop();
        if let Some(running) = self.running.take() {
            let _ = running.join();
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

/// A board's end of the connection: every frame the core sends, in order.
struct Board {
    socket: CoreSocket,
    frames: Receiver<(FrameKind, Vec<u8>)>,
}

impl Board {
    /// Connected, without having said hello.
    fn connect(path: &str) -> Self {
        let socket = CoreSocket::new(core_socket::connect(path).unwrap());
        let (sender, frames) = channel();
        socket.start(
            move |kind, payload| {
                let _ = sender.send((kind, payload.to_vec()));
            },
            || {},
        );
        Self { socket, frames }
    }

    /// Connected and welcomed, in this build's version.
    fn open(path: &str) -> Self {
        let board = Self::connect(path);
        board.request(&CoreRequest::Hello { version: 8, oldest: Some(2) });
        let CoreEvent::Welcome { version: 8, .. } = board.event() else { panic!("not welcomed") };
        board
    }

    fn request(&self, request: &CoreRequest) {
        self.socket.send_message(request);
    }

    fn start(&self, id: Uuid, text: &str, cols: i64, rows: i64) {
        self.request(&CoreRequest::Start { id, spec: script(text), cols, rows });
    }

    fn input(&self, id: Uuid, bytes: &[u8]) {
        self.socket.send_to(FrameKind::Data, id, bytes);
    }

    /// The next frame; none when the core hung up.
    fn next(&self) -> Option<(FrameKind, Vec<u8>)> {
        match self.frames.recv_timeout(TIMEOUT) {
            Ok(frame) => Some(frame),
            Err(RecvTimeoutError::Disconnected) => None,
            Err(RecvTimeoutError::Timeout) => panic!("the core sent nothing for {TIMEOUT:?}"),
        }
    }

    /// Reads frames until `wanted` picks one.
    fn until<T>(&self, mut wanted: impl FnMut(FrameKind, &[u8]) -> Option<T>) -> T {
        loop {
            let (kind, payload) = self.next().expect("the core hung up");
            if let Some(found) = wanted(kind, &payload) {
                return found;
            }
        }
    }

    /// The next control frame, skipping the others.
    fn event(&self) -> CoreEvent {
        self.until(|kind, payload| (kind == FrameKind::Control).then(|| serde_json::from_slice(payload).unwrap()))
    }

    /// The next status of session `id` that `wanted` accepts.
    fn status(&self, id: Uuid, wanted: impl Fn(&SessionStatus) -> bool) -> SessionStatus {
        self.until(|kind, payload| match (kind == FrameKind::Control).then(|| serde_json::from_slice(payload).unwrap()) {
            Some(CoreEvent::Status { id: of, status }) if of == id && wanted(&status) => Some(status),
            _ => None,
        })
    }

    fn run(&self, executable: &str, arguments: &[&str], directory: Option<&str>) -> (i32, Vec<u8>, Vec<u8>) {
        self.run_with(executable, arguments, directory, None)
    }

    fn run_with(&self, executable: &str, arguments: &[&str], directory: Option<&str>, input: Option<&[u8]>) -> (i32, Vec<u8>, Vec<u8>) {
        let call = Uuid::new();
        let arguments = arguments.iter().map(|argument| argument.to_string()).collect();
        self.request(&CoreRequest::Run { call, executable: executable.into(), arguments, directory: directory.map(Into::into), input: input.map(|input| Data(input.to_vec())) });
        loop {
            if let CoreEvent::Ran { call: answered, status, output, error } = self.event() {
                assert_eq!(answered, call);
                return (status, output.0, error.0);
            }
        }
    }
}

/// A board's copy of one session's terminal, as the Swift mirror keeps it: restored from the
/// snapshot, then fed the output that follows.
struct Mirror {
    id: Uuid,
    terminal: Terminal,
    snapshots: usize,
    statuses: Vec<SessionStatus>,
}

impl Mirror {
    fn new(id: Uuid) -> Self {
        Self { id, terminal: Terminal::with_scrollback(80, 24, 5000), snapshots: 0, statuses: Vec::new() }
    }

    fn take(&mut self, kind: FrameKind, payload: &[u8]) {
        if kind == FrameKind::Control {
            if let Ok(CoreEvent::Status { id, status }) = serde_json::from_slice(payload) {
                self.statuses.extend((id == self.id).then_some(status));
            }
        }
        if !matches!(kind, FrameKind::Data | FrameKind::Snapshot) || Uuid::from_prefix(payload) != Some(self.id) {
            return;
        }
        if kind == FrameKind::Snapshot {
            assert!(self.terminal.restore(&payload[16..]));
            self.snapshots += 1;
        } else {
            self.terminal.feed(&payload[16..]);
        }
    }

    fn screen(&self) -> String {
        self.terminal.screen_text().join("\n")
    }

    /// Reads `board` until this terminal shows `text`.
    fn until_shows(&mut self, board: &Board, text: &str) {
        while !self.screen().contains(text) {
            let (kind, payload) = board.next().unwrap_or_else(|| panic!("hung up before {text:?}:\n{}", self.screen()));
            self.take(kind, &payload);
        }
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only asks whether the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn wait_until(what: &str, condition: impl Fn() -> bool) {
    let deadline = Instant::now() + TIMEOUT;
    while !condition() {
        assert!(Instant::now() < deadline, "never: {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

const ECHO: &str = "printf 'ready\\n'; while read line; do printf 'got %s\\n' \"$line\"; done";

#[test]
fn hello_agrees_on_a_version_or_says_which_the_core_speaks() {
    let core = Fixture::new();
    let welcome = |version, oldest| {
        let board = Board::connect(&core.path);
        board.request(&CoreRequest::Hello { version, oldest });
        let CoreEvent::Welcome { version, oldest, sessions, service } = board.event() else { panic!() };
        assert_eq!((sessions, service), (vec![], None));
        (version, oldest)
    };
    assert_eq!(welcome(8, Some(2)), (8, Some(2)));
    // The build before: it doesn't say which versions it still speaks.
    assert_eq!(welcome(2, None), (2, Some(2)));
    // A newer board that still speaks ours.
    assert_eq!(welcome(11, Some(7)), (9, Some(2)));
    // No version in common, either way: the core's own versions, and nothing else.
    assert_eq!(welcome(11, Some(10)), (9, Some(2)));
    assert_eq!(welcome(1, None), (9, Some(2)));

    // A core of another build answers a board of this one the same way.
    let newer = Fixture::<()>::with(60.0, |handle| handle.post(|_, server| server.versions = runtime::Versions { version: 11, oldest: 10 }));
    let board = Board::connect(&newer.path);
    board.request(&CoreRequest::Hello { version: 8, oldest: Some(2) });
    let CoreEvent::Welcome { version: 11, oldest: Some(10), .. } = board.event() else { panic!() };
}

#[test]
fn the_socket_and_its_folder_are_the_users_only() {
    let folder = std::env::temp_dir().join(format!("abdir-{}", &Uuid::new().to_string()[..8]));
    let path = folder.join("deep/core.sock");
    let mut server = CoreServer::<()>::new(path.to_str().unwrap(), 60.0);
    server.start().unwrap();
    let mode = |path: &std::path::Path| path.metadata().unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&path) & 0o077, 0, "{:o}", mode(&path));
    assert_eq!(mode(path.parent().unwrap()), 0o700);
    assert!(core_socket::connect(path.to_str().unwrap()).is_ok());
    drop(server);
    assert!(CoreServer::<()>::new(path.to_str().unwrap(), 60.0).start().is_ok(), "a socket file left behind is replaced");
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn a_board_mirrors_a_program_and_a_second_one_picks_it_up() {
    let core = Fixture::new();
    let id = Uuid::new();
    let first = Board::open(&core.path);
    first.start(id, ECHO, 40, 6);
    let mut mirror = Mirror::new(id);
    mirror.terminal.resize(40, 6);
    mirror.until_shows(&first, "ready");
    first.input(id, b"before\r");
    mirror.until_shows(&first, "got before");
    // Starting, then with its pid, then running at its first output.
    let pid = mirror.statuses[1].process_id.unwrap();
    let status = |state, process_id| SessionStatus { state, process_id, exit_code: None };
    assert_eq!(mirror.statuses, [status(State::Starting, None), status(State::Starting, Some(pid)), status(State::Running, Some(pid))]);
    // It started the session, so it mirrors from the first byte: no snapshot.
    assert_eq!(mirror.snapshots, 0);
    first.socket.close();

    // The program outlives the board; the next one learns of it in its welcome.
    let second = Board::connect(&core.path);
    second.request(&CoreRequest::Hello { version: 8, oldest: Some(2) });
    let CoreEvent::Welcome { sessions, .. } = second.event() else { panic!() };
    assert_eq!(sessions, [(id, SessionStatus { state: State::Running, process_id: Some(pid), exit_code: None })]);
    second.request(&CoreRequest::Attach { id });
    // The status first, then the screen.
    let (kind, payload) = second.next().unwrap();
    assert_eq!(kind, FrameKind::Control);
    assert_eq!(serde_json::from_slice::<CoreEvent>(&payload).unwrap(), CoreEvent::Status { id, status: sessions[0].1.clone() });
    let mut picked_up = Mirror::new(id);
    let (kind, payload) = second.next().unwrap();
    picked_up.take(kind, &payload);
    assert_eq!((picked_up.snapshots, picked_up.terminal.cols(), picked_up.terminal.rows()), (1, 40, 6));
    assert_eq!(picked_up.screen(), mirror.screen());

    // Text the board writes into the terminal reaches every mirror, as output.
    let third = Board::open(&core.path);
    third.request(&CoreRequest::Attach { id });
    let mut other = Mirror::new(id);
    other.until_shows(&third, "got before");
    second.request(&CoreRequest::Annotate { id, text: "-- restarted --".into(), fresh_line: true });
    second.input(id, b"after\r");
    picked_up.until_shows(&second, "got after");
    other.until_shows(&third, "got after");
    assert!(other.screen().contains("\n-- restarted --"), "{}", other.screen());
    assert_eq!(other.terminal.snapshot(), picked_up.terminal.snapshot());
    assert_eq!(core.snapshot(id), picked_up.terminal.snapshot());

    // A resize reaches the program and the core's terminal.
    second.request(&CoreRequest::Resize { id, cols: 30, rows: 4 });
    second.request(&CoreRequest::Attach { id });
    let resized = second.until(|kind, payload| (kind == FrameKind::Snapshot).then(|| payload[16..].to_vec()));
    let mut terminal = Terminal::new(80, 24);
    assert!(terminal.restore(&resized));
    assert_eq!((terminal.cols(), terminal.rows()), (30, 4));

    // An unknown session is reported stopped; an unknown request is dropped, not fatal.
    let unknown = Uuid::new();
    second.socket.send(FrameKind::Control, br#"{"teleport":{"id":"x"}}"#);
    second.socket.send(FrameKind::Control, b"not json");
    second.request(&CoreRequest::Attach { id: unknown });
    assert_eq!(second.status(unknown, |_| true), SessionStatus { state: State::Stopped, process_id: None, exit_code: None });
}

/// The heart of the design: a board that attaches while the program prints gets a snapshot and
/// then exactly the output that follows it, no byte missing or twice.
#[test]
fn attaching_under_load_never_misses_or_repeats_a_byte() {
    let core = Fixture::new();
    let id = Uuid::new();
    let starter = Board::open(&core.path);
    // Colors, wrapping lines, tabs and more lines than the scrollback keeps.
    starter.start(id, "i=0; while [ $i -lt 12000 ]; do printf '\\033[3%dm line %d\\033[0m\\tthe quick brown fox jumps over the lazy dog\\n' $((i % 8)) $i; i=$((i + 1)); done; printf 'finished\\n'; read line", 60, 20);
    let seed = u64::from_le_bytes(Uuid::new().as_bytes()[..8].try_into().unwrap());
    let attaching: Vec<_> = (0..20u64)
        .map(|client| {
            let path = core.path.clone();
            std::thread::spawn(move || {
                // Spread over the time the program takes to print, some after it is done.
                let wait = seed.wrapping_mul(6364136223846793005).wrapping_add(client.wrapping_mul(1442695040888963407)) >> 33;
                std::thread::sleep(Duration::from_micros(wait % 400_000));
                let board = Board::open(&path);
                board.request(&CoreRequest::Attach { id });
                let mut mirror = Mirror::new(id);
                mirror.until_shows(&board, "finished");
                (board, mirror)
            })
        })
        .collect();
    let mut first = Mirror::new(id);
    first.terminal.resize(60, 20);
    first.until_shows(&starter, "finished");
    let mirrors: Vec<_> = attaching.into_iter().map(|thread| thread.join().unwrap()).collect();
    // Everything the program printed is parsed by now (it waits on `read`), so the core's
    // terminal is final; so is each mirror's, "finished" being the last output.
    let expected = core.snapshot(id);
    assert_eq!(first.terminal.snapshot(), expected, "the board that started it");
    let mut mid_stream = 0;
    for (index, (_board, mirror)) in mirrors.iter().enumerate() {
        assert_eq!(mirror.snapshots, 1);
        assert!(mirror.terminal.snapshot() == expected, "client {index} differs:\n{}", mirror.screen());
        mid_stream += (mirror.terminal.scrollback().count() > 0) as usize;
    }
    assert!(mid_stream > 0);
    starter.request(&CoreRequest::Close { id, grace: Some(1.0) });
}

#[test]
fn statuses_reach_those_who_mirror_and_those_who_subscribed() {
    let core = Fixture::new();
    let opener = Board::open(&core.path);
    let sidebar = Board::open(&core.path);
    sidebar.request(&CoreRequest::SubscribeStatuses {});
    let agent = Board::open(&core.path);
    // Answered in order, so the subscription is in place once this comes back.
    sidebar.request(&CoreRequest::Attach { id: Uuid::new() });
    sidebar.event();
    let id = Uuid::new();
    opener.start(id, "echo up; sleep 0.2; exit 2", 40, 6);
    let exited = SessionStatus { state: State::Exited, process_id: None, exit_code: Some(2) };
    assert_eq!(opener.status(id, |status| status.process_id.is_none() && status.state != State::Starting), exited);
    assert_eq!(sidebar.status(id, |status| status.state == State::Exited), exited);
    // A connection that didn't subscribe (an agent's own) hears nothing it didn't open.
    assert!(agent.frames.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn terminate_stop_and_close_end_the_program() {
    let core = Fixture::new();
    let board = Board::open(&core.path);

    let terminated = Uuid::new();
    board.start(terminated, ECHO, 40, 6);
    let pid = board.status(terminated, |status| status.state == State::Running).process_id.unwrap();
    board.request(&CoreRequest::Terminate { id: terminated, grace: 1.0 });
    let stopped = SessionStatus { state: State::Stopped, process_id: None, exit_code: Some(128 + libc::SIGTERM) };
    assert_eq!(board.status(terminated, |status| status.process_id.is_none()), stopped);
    // Once more when the completion runs, so a board waiting on an exit already reported wakes.
    assert_eq!(board.status(terminated, |_| true), stopped);
    assert!(!alive(pid));
    // The session is kept, with its screen: the same card starts it again.
    board.start(terminated, ECHO, 40, 6);
    assert!(board.status(terminated, |status| status.state == State::Running).process_id.is_some_and(|again| again != pid));
    // Terminating a program that already ended still answers.
    board.request(&CoreRequest::Terminate { id: terminated, grace: 0.1 });
    board.status(terminated, |status| status.state == State::Stopped);
    board.request(&CoreRequest::Terminate { id: terminated, grace: 0.1 });
    board.status(terminated, |status| status.state == State::Stopped);

    let hung_up = Uuid::new();
    board.start(hung_up, ECHO, 40, 6);
    board.status(hung_up, |status| status.state == State::Running);
    board.request(&CoreRequest::Stop { id: hung_up });
    assert_eq!(board.status(hung_up, |status| status.process_id.is_none()), SessionStatus { state: State::Exited, process_id: None, exit_code: Some(128 + libc::SIGHUP) });

    // Close ends the program and forgets the session: nothing more is heard of it.
    for grace in [Some(1.0), None] {
        let closed = Uuid::new();
        board.start(closed, ECHO, 40, 6);
        let pid = board.status(closed, |status| status.state == State::Running).process_id.unwrap();
        board.request(&CoreRequest::Close { id: closed, grace });
        wait_until("the closed program to end", || !alive(pid));
        board.request(&CoreRequest::Attach { id: closed });
        assert_eq!(board.status(closed, |_| true), SessionStatus { state: State::Stopped, process_id: None, exit_code: None });
    }
    let fresh = Board::connect(&core.path);
    fresh.request(&CoreRequest::Hello { version: 8, oldest: Some(2) });
    let CoreEvent::Welcome { sessions, .. } = fresh.event() else { panic!() };
    let mut known: Vec<Uuid> = sessions.into_iter().map(|(id, _)| id).collect();
    known.sort();
    let mut kept = [terminated, hung_up];
    kept.sort();
    assert_eq!(known, kept);

    // A core asking to take over is turned away: this one doesn't hand over.
    fresh.request(&CoreRequest::TakeOver {});
    assert!(fresh.next().is_none());
}

#[test]
fn shutdown_ends_every_program_and_the_core() {
    let mut core = Fixture::new();
    let board = Board::open(&core.path);
    let (polite, stubborn) = (Uuid::new(), Uuid::new());
    board.start(polite, ECHO, 40, 6);
    board.start(stubborn, "trap '' TERM HUP; echo armed; while :; do sleep 1; done", 40, 6);
    // Both running, in whichever order they report it.
    let mut pids = HashMap::new();
    while pids.len() < 2 {
        if let CoreEvent::Status { id, status: SessionStatus { state: State::Running, process_id: Some(pid), .. } } = board.event() {
            pids.insert(id, pid);
        }
    }
    board.request(&CoreRequest::Shutdown {});
    // SIGTERM, then SIGKILL after 2 seconds for the one that ignores it.
    assert!(core.exited(Duration::from_secs(8)), "the core didn't exit");
    assert!(pids.values().all(|pid| !alive(*pid)));
    wait_until("the board to be hung up on", || loop {
        match board.frames.try_recv() {
            Ok(_) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => break true,
            Err(std::sync::mpsc::TryRecvError::Empty) => break false,
        }
    });
}

#[test]
fn an_idle_core_exits_and_a_busy_one_stays() {
    let started = Instant::now();
    let mut idle = Fixture::<()>::with(0.3, |_| ());
    assert!(idle.exited(Duration::from_secs(5)), "an idle core exits");
    assert!(started.elapsed() >= Duration::from_millis(300), "{:?}", started.elapsed());

    // A connected board keeps it; so does a running program after the board left.
    let mut busy = Fixture::<()>::with(0.3, |_| ());
    let board = Board::open(&busy.path);
    assert!(!busy.exited(Duration::from_millis(700)));
    let id = Uuid::new();
    board.start(id, "echo up; sleep 1.2", 40, 6);
    board.status(id, |status| status.state == State::Running);
    board.socket.close();
    assert!(!busy.exited(Duration::from_millis(700)), "a program still runs");
    assert!(busy.exited(Duration::from_secs(5)), "the program ended and no board is connected");
}

#[test]
fn run_executes_a_program_on_the_cores_machine() {
    let core = Fixture::new();
    let board = Board::open(&core.path);
    assert_eq!(board.run("/bin/sh", &["-c", "printf out; printf err >&2"], None), (0, b"out".to_vec(), b"err".to_vec()));
    assert_eq!(board.run("/bin/sh", &["-c", "echo no >&2; exit 3"], None), (3, vec![], b"no\n".to_vec()));
    // Exactly the given arguments: nothing is a shell's to expand, and there is nothing to read.
    assert_eq!(board.run("/bin/echo", &["$HOME; *", "a  b"], None), (0, b"$HOME; * a  b\n".to_vec(), vec![]));
    assert_eq!(board.run("/bin/cat", &[], None), (0, vec![], vec![]));
    let folder = std::env::temp_dir().canonicalize().unwrap();
    assert_eq!(board.run("/bin/pwd", &["-P"], folder.to_str()), (0, format!("{}\n", folder.display()).into_bytes(), vec![]));
    // Ended by a signal: the signal's number, as Foundation reports it.
    assert_eq!(board.run("/bin/sh", &["-c", "kill -9 $$"], None).0, libc::SIGKILL);

    let (status, output, error) = board.run("/nonexistent/program", &[], None);
    assert_eq!((status, output), (-1, vec![]));
    assert_eq!(String::from_utf8(error).unwrap(), "No such file or directory");
    assert_eq!(board.run("/bin/pwd", &[], Some("/nonexistent/folder")).0, -1);

    // What the program reads, then end-of-file; more than a pipe holds, to one that never reads.
    assert_eq!(board.run_with("/bin/cat", &[], None, Some(b"typed\n")), (0, b"typed\n".to_vec(), vec![]));
    assert_eq!(board.run_with("/bin/cat", &[], None, Some(b"")), (0, vec![], vec![]));
    let long = vec![b'x'; 2_000_000];
    assert_eq!(board.run_with("/bin/cat", &[], None, Some(&long)).1.len(), long.len());
    assert_eq!(board.run_with("/bin/echo", &["deaf"], None, Some(&long)), (0, b"deaf\n".to_vec(), vec![]));

    // A bare name is looked up in the PATH; one that isn't there says so.
    assert_eq!(board.run("sh", &["-c", "printf found"], None), (0, b"found".to_vec(), vec![]));
    let (status, output, error) = board.run("no-such-program-anywhere", &[], None);
    assert_eq!((status, output, String::from_utf8(error).unwrap().as_str()), (-1, vec![], "no-such-program-anywhere: command not found"));
    // The service's PATH, once it set one, is the only place looked in.
    let (sender, set) = channel();
    core.handle.post(move |_, server| {
        server.run_path = "/nonexistent".into();
        sender.send(()).unwrap();
    });
    set.recv_timeout(TIMEOUT).unwrap();
    assert_eq!(board.run("sh", &[], None).0, -1);
    assert_eq!(board.run("/bin/echo", &["absolute"], None).1, b"absolute\n");

    // More than a pipe holds on both, the errors first: neither blocks the other.
    let (status, output, error) = board.run("/bin/sh", &["-c", "head -c 3000000 /dev/zero >&2; head -c 2000000 /dev/zero; head -c 100 /dev/zero >&2"], None);
    assert_eq!((status, output.len(), error.len()), (0, 2_000_000, 3_000_100));

    // A slow program doesn't hold the core up: the quick one answers first.
    let slow = Uuid::new();
    board.request(&CoreRequest::Run { call: slow, executable: "/bin/sleep".into(), arguments: vec!["0.6".into()], directory: None, input: None });
    assert_eq!(board.run("/bin/echo", &["quick"], None).1, b"quick\n");
    let CoreEvent::Ran { call, status: 0, .. } = board.event() else { panic!() };
    assert_eq!(call, slow);
}

#[test]
fn a_subscribed_board_hears_the_machines_stats() {
    let core = Fixture::new();
    let board = Board::open(&core.path);
    let other = Board::open(&core.path);
    let started = Instant::now();
    board.request(&CoreRequest::SubscribeHost {});
    for sample in 0..2 {
        let CoreEvent::Host { stats } = board.event() else { panic!() };
        println!("host stats: {stats:?}");
        assert!((0.0..=1.0).contains(&stats.cpu), "{stats:?}");
        assert!(stats.cores >= 1 && stats.load >= 0.0, "{stats:?}");
        assert!(stats.memory_total >= 256 << 20 && stats.memory_used > 0 && stats.memory_used <= stats.memory_total, "{stats:?}");
        assert!(stats.disk_total >= 1 << 30 && stats.disk_used > 0 && stats.disk_used <= stats.disk_total, "{stats:?}");
        // The first at once, the next 2 seconds later.
        assert_eq!(started.elapsed() >= Duration::from_millis(1900), sample == 1, "{:?}", started.elapsed());
    }
    assert!(other.frames.try_recv().is_err(), "only the board that asked");
}

/// A board that stops reading is dropped once too much waits for it; the program and the other
/// boards never wait for it.
#[test]
fn a_board_that_stops_reading_is_dropped_without_stalling_the_others() {
    let core = Fixture::new();
    let id = Uuid::new();
    let reader = Board::open(&core.path);
    reader.start(id, "read go; head -c 70000000 /dev/zero; printf 'finished\\n'; read line", 40, 6);
    reader.status(id, |status| status.process_id.is_some());

    // Says hello and attaches, then never reads again.
    let mut stuck = core_socket::connect(&core.path).unwrap();
    stuck.set_read_timeout(Some(TIMEOUT)).unwrap();
    let frame = |kind: u8, payload: &[u8]| [&((payload.len() + 1) as u32).to_be_bytes()[..], &[kind], payload].concat();
    use std::io::Write;
    stuck.write_all(&frame(1, br#"{"hello":{"version":8,"oldest":2}}"#)).unwrap();
    stuck.write_all(&frame(1, &serde_json::to_vec(&CoreRequest::Attach { id }).unwrap())).unwrap();
    // Its attach is answered before the program is told to go.
    let probe = Board::open(&core.path);
    probe.request(&CoreRequest::Attach { id: Uuid::new() });
    probe.event();

    reader.input(id, b"\r");
    let mut received = 0usize;
    let mut mirror = Mirror::new(id);
    mirror.terminal.resize(40, 6);
    let started = Instant::now();
    while !mirror.screen().contains("finished") {
        let (kind, payload) = reader.next().expect("the reading board is still served");
        received += if kind == FrameKind::Data { payload.len() - 16 } else { 0 };
        mirror.take(kind, &payload);
    }
    println!("70 MB through the core with a stuck board attached: {:?}", started.elapsed());
    // Every byte once: the zeros, "finished" and the echo of the line that set it off.
    assert_eq!(received, 70_000_000 + "\r\nfinished\r\n".len());

    // The stuck one was hung up on: what the socket still held, then the end, well short of
    // everything.
    let mut left = Vec::new();
    match stuck.read_to_end(&mut left) {
        // Hung up on with frames unread: the end comes as a reset on some systems.
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => {}
        Err(error) => panic!("the core kept the stuck board: {error}"),
    }
    assert!(left.len() < 60_000_000, "{}", left.len());
}

/// What the orchestration crate plugs in: a service with state of its own, called on the main
/// loop, with the server to act on.
struct Recorder {
    handle: CoreHandle<Recorder>,
    log: Arc<Mutex<Vec<String>>>,
    connected: Vec<CoreBoard>,
}

impl Recorder {
    fn note(&self, line: String) {
        self.log.lock().unwrap().push(line);
    }
}

impl CoreService for Recorder {
    fn board_connected(&mut self, server: &mut CoreServer<Self>, board: &CoreBoard) -> Option<Vec<u8>> {
        self.connected.push(board.clone());
        self.note(format!("connected {} v{:?} of {}", board.number(), board.version(), server.boards().len()));
        Some(b"state".to_vec())
    }

    fn received(&mut self, server: &mut CoreServer<Self>, payload: &[u8], board: &CoreBoard) {
        match payload.split_first() {
            // Opens a session for the board that asked, as the orchestrator does for a card.
            Some((b'o', id)) => {
                let id = Uuid::from_prefix(id).unwrap();
                let session = server.open_session(id, 50, 5, Some(board));
                session.mark_stopped();
                assert!(server.session(id).is_some());
            }
            Some((b'c', id)) => server.close_session(Uuid::from_prefix(id).unwrap(), Some(0.5)),
            // A timer of its own, on the main loop, with its state at hand.
            Some((b't', _)) => {
                let board = board.clone();
                self.handle.post_after(Duration::from_millis(50), move |service, _| {
                    service.note("timer".into());
                    board.send(b"rang");
                });
            }
            _ => self.connected.iter().for_each(|other| other.send(&[b"echo ", payload].concat())),
        }
    }

    fn board_disconnected(&mut self, _server: &mut CoreServer<Self>, board: &CoreBoard) {
        self.connected.retain(|other| other != board);
        self.note(format!("disconnected {}", board.number()));
    }

    fn session_notified(&mut self, _server: &mut CoreServer<Self>, id: Uuid, notifications: Vec<String>) {
        self.note(format!("notified {id} {notifications:?}"));
    }

    fn input(&mut self, _server: &mut CoreServer<Self>, bytes: Vec<u8>, _id: Uuid) -> Vec<u8> {
        bytes.to_ascii_uppercase()
    }

    fn session_status(&mut self, _server: &mut CoreServer<Self>, _id: Uuid, status: &SessionStatus) {
        self.note(format!("status {:?} {:?}", status.state, status.exit_code));
    }
}

#[test]
fn the_service_gets_boards_frames_input_and_notifications() {
    let log = Arc::new(Mutex::new(Vec::new()));
    let service_log = log.clone();
    let core = Fixture::with(60.0, move |handle| Recorder { handle, log: service_log, connected: Vec::new() });
    let logged = |line: &str| log.lock().unwrap().iter().any(|logged| logged == line);

    let board = Board::connect(&core.path);
    board.request(&CoreRequest::Hello { version: 8, oldest: Some(2) });
    let CoreEvent::Welcome { service, .. } = board.event() else { panic!() };
    assert_eq!(service, Some(Data(b"state".to_vec())));
    assert!(logged("connected 1 vSome(8) of 1"));

    // Service frames both ways, in order with the requests.
    let service_frame = |board: &Board| board.until(|kind, payload| (kind == FrameKind::Service).then(|| payload.to_vec()));
    board.socket.send(FrameKind::Service, b"hi");
    assert_eq!(service_frame(&board), b"echo hi");
    board.socket.send(FrameKind::Service, b"t");
    assert_eq!(service_frame(&board), b"rang");
    assert!(logged("timer"));

    // The service opens a session for the board: status, then snapshot.
    let id = Uuid::new();
    board.socket.send(FrameKind::Service, &[b"o", &id.as_bytes()[..]].concat());
    assert_eq!(board.status(id, |_| true).state, State::Starting);
    let mut mirror = Mirror::new(id);
    let (kind, payload) = board.next().unwrap();
    mirror.take(kind, &payload);
    assert_eq!((mirror.snapshots, mirror.terminal.cols(), mirror.terminal.rows()), (1, 50, 5));
    assert_eq!(board.status(id, |_| true).state, State::Stopped);

    // What the board types goes through the service; the program's notifications come to it.
    board.start(id, "read line; printf 'got %s\\n\\033]9;done\\007' \"$line\"; read line", 50, 5);
    board.status(id, |status| status.process_id.is_some());
    board.input(id, b"hello\r");
    mirror.until_shows(&board, "got HELLO");
    wait_until("the notification", || logged(&format!("notified {id} [\"done\"]")));
    assert!(logged("status Running None"));

    board.socket.send(FrameKind::Service, &[b"c", &id.as_bytes()[..]].concat());
    wait_until("the stop", || logged("status Stopped Some(143)"));
    board.socket.close();
    wait_until("the board leaving", || logged("disconnected 1"));

    // From any thread onto the main loop, with the service and the server.
    let (sender, boards) = channel();
    core.handle.post(move |service, server| sender.send((service.connected.len(), server.boards().len(), server.session(id).is_some())).unwrap());
    assert_eq!(boards.recv_timeout(TIMEOUT).unwrap(), (0, 0, false));
}

/// A keystroke's way through the core: board → socket → main loop → PTY → `cat` → PTY → the
/// session's thread (terminal, fan-out) → socket → board.
#[test]
fn a_keystroke_echoes_through_the_core_in_well_under_a_frame() {
    let core = Fixture::new();
    let board = Board::open(&core.path);
    let id = Uuid::new();
    board.start(id, "stty raw -echo; printf ready; exec cat", 80, 24);
    board.request(&CoreRequest::Observe { id, observed: true });
    Mirror::new(id).until_shows(&board, "ready");

    let mut latencies = Vec::new();
    for key in 0..300u32 {
        // A typist's pace, slower than the 8 ms the core lets output pile up while shown.
        std::thread::sleep(Duration::from_millis(12));
        let byte = b'a' + (key % 26) as u8;
        let sent = Instant::now();
        board.input(id, &[byte]);
        board.until(|kind, payload| (kind == FrameKind::Data && payload[16..].contains(&byte)).then_some(()));
        latencies.push(sent.elapsed());
    }
    latencies.sort();
    let (median, p95, worst) = (latencies[latencies.len() / 2], latencies[latencies.len() * 95 / 100], latencies[latencies.len() - 1]);
    println!("keystroke echo through the core: median {median:?}, p95 {p95:?}, max {worst:?} ({} keys)", latencies.len());
    assert!(p95 < Duration::from_millis(20), "median {median:?}, p95 {p95:?}");
    board.request(&CoreRequest::Close { id, grace: None });
}
