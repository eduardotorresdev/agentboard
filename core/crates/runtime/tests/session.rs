//! A session owning a real PTY: what the program prints, how it ends, and what it is given.

use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use runtime::{AgentSession, LaunchSpec, SessionStatus, State};

fn script(text: &str) -> LaunchSpec {
    spec(text, &[])
}

fn spec(text: &str, environment: &[(&str, &str)]) -> LaunchSpec {
    let mut all: HashMap<String, String> = [("PATH", "/usr/bin:/bin"), ("TERM", "xterm-256color")].into_iter().chain(environment.iter().copied()).map(|(key, value)| (key.to_string(), value.to_string())).collect();
    all.entry("HOME".into()).or_insert_with(|| "/tmp".into());
    LaunchSpec { executable: "/bin/sh".into(), arguments: vec!["-c".into(), text.into()], environment: all, directory: std::env::temp_dir().to_string_lossy().into_owned() }
}

fn screen(session: &AgentSession) -> String {
    session.with_terminal(|terminal| terminal.screen_text().join("\n"))
}

/// Waits for `condition`, woken by every status the session reports and checking the screen
/// in between; panics with the screen when it never holds.
fn wait_until(session: &AgentSession, statuses: &Receiver<SessionStatus>, what: &str, condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "never: {what}\n{:?}\n{}", session.status(), screen(session));
        let _ = statuses.recv_timeout(Duration::from_millis(5));
    }
}

/// A session and every status it reported, in order.
fn session(cols: usize, rows: usize) -> (AgentSession, Receiver<SessionStatus>, Arc<Mutex<Vec<SessionStatus>>>) {
    let session = AgentSession::new(cols, rows);
    let (sender, statuses) = channel();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    session.set_on_status(move |status| {
        log.lock().unwrap().push(status.clone());
        let _ = sender.send(status);
    });
    (session, statuses, seen)
}

#[test]
fn output_arrives_and_the_exit_code_is_reported() {
    let (session, statuses, seen) = session(40, 6);
    assert_eq!(session.state(), State::Starting);
    session.start(script("printf 'ready\\n'; read line; printf 'got %s\\n' \"$line\"; exit 3"));
    wait_until(&session, &statuses, "ready", || screen(&session).contains("ready"));
    assert_eq!(session.state(), State::Running);
    let pid = session.process_id().expect("a running program has a pid");
    session.send(b"hello\r".to_vec());
    wait_until(&session, &statuses, "exit", || session.state() == State::Exited);
    assert!(screen(&session).contains("got hello"), "{}", screen(&session));
    assert_eq!((session.exit_code(), session.process_id()), (Some(3), None));

    let seen = seen.lock().unwrap().clone();
    let status = |state, process_id, exit_code| SessionStatus { state, process_id, exit_code };
    assert_eq!(seen, [status(State::Starting, None, None), status(State::Starting, Some(pid), None), status(State::Running, Some(pid), None), status(State::Exited, None, Some(3))]);
}

#[test]
fn the_program_sees_its_window_and_every_resize() {
    let (session, statuses, _) = session(72, 9);
    session.start(script("stty size; read line; stty size; read line"));
    wait_until(&session, &statuses, "the first size", || screen(&session).contains("9 72"));
    session.resize(100, 30);
    assert_eq!(session.with_terminal(|terminal| (terminal.cols(), terminal.rows())), (100, 30));
    session.send(b"\r".to_vec());
    wait_until(&session, &statuses, "the new size", || screen(&session).contains("30 100"));
    session.stop();
    wait_until(&session, &statuses, "exit", || session.process_id().is_none());
}

#[test]
fn terminate_stops_the_program_and_what_it_started() {
    let (session, statuses, _) = session(40, 6);
    session.start(script("sleep 300 & echo child $!; wait"));
    wait_until(&session, &statuses, "the child", || screen(&session).contains("child "));
    let child: i32 = screen(&session).split("child ").nth(1).unwrap().split_whitespace().next().unwrap().parse().unwrap();
    let (done, completed) = channel();
    let started = Instant::now();
    session.terminate(5.0, Some(Box::new(move || done.send(()).unwrap())));
    completed.recv_timeout(Duration::from_secs(10)).expect("the completion runs once it has exited");
    assert!(started.elapsed() < Duration::from_secs(4), "it ended at SIGTERM, without waiting for the grace");
    // Asked to stop, so stopped rather than exited; 128 + SIGTERM.
    assert_eq!(session.status(), SessionStatus { state: State::Stopped, process_id: None, exit_code: Some(128 + libc::SIGTERM) });
    // SAFETY: signal 0 only asks whether the process exists.
    wait_until(&session, &statuses, "the child to end", || unsafe { libc::kill(child, 0) } != 0);
}

#[test]
fn a_program_that_ignores_sigterm_is_killed_after_the_grace() {
    let (session, statuses, _) = session(40, 6);
    session.start(script("trap '' TERM; echo armed; while :; do sleep 1; done"));
    wait_until(&session, &statuses, "the trap", || screen(&session).contains("armed"));
    let started = Instant::now();
    session.terminate(0.4, None);
    wait_until(&session, &statuses, "the kill", || session.process_id().is_none());
    assert!(started.elapsed() >= Duration::from_millis(400), "killed before the grace: {:?}", started.elapsed());
    assert_eq!(session.status(), SessionStatus { state: State::Stopped, process_id: None, exit_code: Some(128 + libc::SIGKILL) });
}

#[test]
fn stop_hangs_up_and_terminate_without_a_program_completes() {
    let (session, statuses, _) = session(40, 6);
    session.start(script("echo up; sleep 300"));
    wait_until(&session, &statuses, "up", || screen(&session).contains("up"));
    session.stop();
    wait_until(&session, &statuses, "the hang-up", || session.process_id().is_none());
    // Not asked to stop through `terminate`: it exited, on SIGHUP.
    assert_eq!(session.status(), SessionStatus { state: State::Exited, process_id: None, exit_code: Some(128 + libc::SIGHUP) });

    // The same session starts again.
    session.start(script("echo again"));
    wait_until(&session, &statuses, "the second run", || session.exit_code() == Some(0) && screen(&session).contains("again"));

    let (never_started, _, seen) = self::session(40, 6);
    let (done, completed) = channel();
    never_started.terminate(1.0, Some(Box::new(move || done.send(()).unwrap())));
    completed.recv_timeout(Duration::from_secs(10)).expect("nothing runs: the completion comes at once");
    assert_eq!(never_started.state(), State::Stopped);
    never_started.mark_stopped();
    never_started.fail("no such agent".into());
    assert_eq!(seen.lock().unwrap().last().unwrap().state, State::Failed("no such agent".into()));
}

#[test]
fn a_program_that_cannot_be_executed_exits_with_127() {
    let (session, statuses, _) = session(40, 6);
    let mut missing = script("");
    missing.executable = "/nonexistent/agent".into();
    session.start(missing);
    wait_until(&session, &statuses, "exit", || session.state() == State::Exited);
    assert_eq!(session.exit_code(), Some(127));
}

/// What a launched program gets from the core: its environment, its folder, a controlling
/// terminal, default signals, and none of the core's open descriptors.
#[test]
fn programs_get_their_environment_but_not_our_descriptors() {
    let mut pipe = [0; 2];
    // SAFETY: plain descriptor calls on values this test owns.
    let probe = unsafe {
        assert_eq!(libc::pipe(pipe.as_mut_ptr()), 0);
        // Far above what the program opens itself, so the check can't confuse the two.
        libc::fcntl(pipe[1], libc::F_DUPFD, 200)
    };
    assert!(probe >= 200);
    let (session, statuses, _) = session(120, 8);
    let folder = std::env::temp_dir().canonicalize().unwrap();
    let mut launch = spec("printf 'v=%s fds=' \"$F1_PROBE\"; ls /dev/fd | tr '\\n' ' '; printf 'end\\n'; pwd -P; trap; echo \"pipe=$?\"; (: < /dev/tty) && echo tty=yes; sleep 30", &[("F1_PROBE", "here")]);
    launch.directory = folder.to_string_lossy().into_owned();
    session.start(launch);
    wait_until(&session, &statuses, "the listing", || screen(&session).contains("tty=yes"));
    session.stop();
    let text = session.with_terminal(|terminal| terminal.screen_text().concat());
    assert!(text.contains("v=here"), "{text}");
    let listed: Vec<i32> = text.split("fds=").nth(1).unwrap().split("end").next().unwrap().split_whitespace().filter_map(|fd| fd.parse().ok()).collect();
    assert!(listed.contains(&2), "{text}");
    assert!(!listed.contains(&probe) && listed.iter().all(|fd| *fd < 20), "{text}");
    assert!(text.contains(&*folder.to_string_lossy()), "{text}");
    // The core ignores SIGPIPE; the program must not inherit that.
    assert!(!text.contains("trap -- '' "), "{text}");
    // SAFETY: closing the descriptors opened above.
    [pipe[0], pipe[1], probe].into_iter().for_each(|fd| unsafe { let _ = libc::close(fd); });
}

#[test]
fn the_terminal_answers_the_program_and_reports_its_notifications() {
    let (session, statuses, _) = session(40, 6);
    let (sender, notified) = channel();
    session.set_on_notify(move |notifications| sender.send(notifications).unwrap());
    let chunks = Arc::new(Mutex::new(Vec::new()));
    let mirror = chunks.clone();
    session.set_on_output(move |bytes| mirror.lock().unwrap().extend_from_slice(bytes));
    // Asks where the cursor is (the terminal's reply is typed back into the PTY) and notifies.
    session.start(script("stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -c | tr -d ' '; stty sane; printf '\\033]9;build done\\007'; echo over"));
    wait_until(&session, &statuses, "exit", || session.state() == State::Exited);
    let text = screen(&session);
    assert!(text.contains("033[1;1R"), "{text}");
    assert_eq!(notified.recv_timeout(Duration::from_secs(5)).unwrap(), ["build done"]);

    // What the output callback saw, fed to another terminal, is the same screen.
    session.annotate("-- restarted --", true);
    let mut copy = terminal::Terminal::with_scrollback(40, 6, 5000);
    copy.feed(&chunks.lock().unwrap());
    assert_eq!(copy.snapshot(), session.with_terminal(|terminal| terminal.snapshot()));
    assert!(screen(&session).contains("over\n-- restarted --"), "{}", screen(&session));
}

#[test]
fn a_session_let_go_hangs_up_on_its_program() {
    let (session, statuses, _) = session(40, 6);
    session.start(script("echo up; sleep 300"));
    wait_until(&session, &statuses, "up", || screen(&session).contains("up"));
    let pid = session.process_id().unwrap();
    drop(session);
    let deadline = Instant::now() + Duration::from_secs(10);
    // SAFETY: signal 0 only asks whether the process exists; it is gone once reaped.
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "the program outlived its session");
        std::thread::sleep(Duration::from_millis(5));
    }
}
