use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use terminal::Terminal;

use crate::core_protocol::{LaunchSpec, SessionStatus};
use crate::pseudo_terminal::PseudoTerminal;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "StateWire", into = "StateWire")]
pub enum State {
    /// Waiting for the process to launch and print its first output.
    Starting,
    Running,
    Exited,
    Failed(String),
    /// Not running because it was asked to stop, or was never started.
    Stopped,
}

/// `State` as Swift's synthesized `Codable` writes it: `{"running":{}}`, `{"failed":{"_0":"…"}}`.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum StateWire {
    Starting {},
    Running {},
    Exited {},
    Failed {
        #[serde(rename = "_0")]
        message: String,
    },
    Stopped {},
}

impl From<StateWire> for State {
    fn from(wire: StateWire) -> Self {
        match wire {
            StateWire::Starting {} => Self::Starting,
            StateWire::Running {} => Self::Running,
            StateWire::Exited {} => Self::Exited,
            StateWire::Failed { message } => Self::Failed(message),
            StateWire::Stopped {} => Self::Stopped,
        }
    }
}

impl From<State> for StateWire {
    fn from(state: State) -> Self {
        match state {
            State::Starting => Self::Starting {},
            State::Running => Self::Running {},
            State::Exited => Self::Exited {},
            State::Failed(message) => Self::Failed { message },
            State::Stopped => Self::Stopped {},
        }
    }
}

/// A running agent: its process on a PTY and the terminal that interprets its output.
///
/// Output is parsed on the session's own thread as it arrives, mirrored or not, so the screen
/// is always current. This is the owning side only: the board's mirror (`host(on:)` in Swift)
/// and everything that serves drawing (`onChange`, synchronized-update pacing) stay in the board.
#[derive(Clone)]
pub struct AgentSession {
    inner: Arc<Inner>,
}

type Completion = Box<dyn FnOnce() + Send>;

struct Inner {
    pty: PseudoTerminal,
    lock: Mutex<Locked>,
    on_status: OnceLock<Box<dyn Fn(SessionStatus) + Send + Sync>>,
    on_notify: OnceLock<Box<dyn Fn(Vec<String>) + Send + Sync>>,
}

struct Locked {
    terminal: Terminal,
    state: State,
    observed: bool,
    process_id: Option<i32>,
    exit_code: Option<i32>,
    /// Set by `terminate` until the program exits: the exit then counts as a stop.
    stopping: bool,
    when_stopped: Vec<Completion>,
    on_output: Option<Box<dyn FnMut(&[u8]) + Send>>,
}

impl Locked {
    fn status(&self) -> SessionStatus {
        SessionStatus { state: self.state.clone(), process_id: self.process_id, exit_code: self.exit_code }
    }
}

/// How long output may pile up in the PTY before it is read: under a frame while a board shows
/// the session, longer while hidden, where nobody is waiting for it.
const OBSERVED_READ_INTERVAL: f64 = 0.008;
const HIDDEN_READ_INTERVAL: f64 = 0.05;

impl AgentSession {
    pub fn new(cols: usize, rows: usize) -> Self {
        let mut terminal = Terminal::with_scrollback(cols, rows, 5000);
        terminal.reported_foreground = 0x14233D;
        terminal.reported_background = 0xFFFFFF;
        let inner = Arc::new_cyclic(|inner: &std::sync::Weak<Inner>| {
            let (output, exit) = (inner.clone(), inner.clone());
            let pty = PseudoTerminal::new(
                move |bytes| {
                    if let Some(inner) = output.upgrade() {
                        AgentSession { inner }.received(bytes)
                    }
                },
                move |status| {
                    if let Some(inner) = exit.upgrade() {
                        AgentSession { inner }.exited(status)
                    }
                },
            )
            // As the Swift core, which traps when it can't make a dispatch source; the server
            // raises the descriptor limit so this stays out of reach.
            .expect("no descriptor or thread left for a session");
            pty.set_minimum_read_interval(HIDDEN_READ_INTERVAL);
            Inner {
                pty,
                lock: Mutex::new(Locked { terminal, state: State::Starting, observed: false, process_id: None, exit_code: None, stopping: false, when_stopped: Vec::new(), on_output: None }),
                on_status: OnceLock::new(),
                on_notify: OnceLock::new(),
            }
        });
        Self { inner }
    }

    /// Called with each chunk of program output right after the terminal parsed it, while the
    /// terminal is still locked: whoever mirrors the terminal sees the same bytes in the same
    /// order, and none between a snapshot and the next chunk. Set before starting.
    pub fn set_on_output(&self, on_output: impl FnMut(&[u8]) + Send + 'static) {
        self.inner.lock.lock().unwrap().on_output = Some(Box::new(on_output));
    }

    /// Called whenever `state`, `process_id` or `exit_code` change, on any thread. Set once,
    /// before starting.
    pub fn set_on_status(&self, on_status: impl Fn(SessionStatus) + Send + Sync + 'static) {
        let _ = self.inner.on_status.set(Box::new(on_status));
    }

    /// Called with the desktop notifications (OSC 9 and 777) the program sent, on the
    /// session's thread, outside the terminal's lock. Set once, before starting.
    pub fn set_on_notify(&self, on_notify: impl Fn(Vec<String>) + Send + Sync + 'static) {
        let _ = self.inner.on_notify.set(Box::new(on_notify));
    }

    pub fn state(&self) -> State {
        self.inner.lock.lock().unwrap().state.clone()
    }

    /// The program's process id while it runs.
    pub fn process_id(&self) -> Option<i32> {
        self.inner.lock.lock().unwrap().process_id
    }

    /// How the program last ended: its exit code, or 128 + the signal that killed it.
    pub fn exit_code(&self) -> Option<i32> {
        self.inner.lock.lock().unwrap().exit_code
    }

    pub fn status(&self) -> SessionStatus {
        self.inner.lock.lock().unwrap().status()
    }

    /// Runs `body` with exclusive access to the terminal. No output is parsed or fanned out
    /// meanwhile: a snapshot taken here and a subscription made here are one step.
    pub fn with_terminal<T>(&self, body: impl FnOnce(&mut Terminal) -> T) -> T {
        body(&mut self.inner.lock.lock().unwrap().terminal)
    }

    /// Whether a board is showing this session: its output is then read sooner.
    pub fn is_observed(&self) -> bool {
        self.inner.lock.lock().unwrap().observed
    }

    pub fn set_observed(&self, observed: bool) {
        let changed = std::mem::replace(&mut self.inner.lock.lock().unwrap().observed, observed) != observed;
        if changed {
            self.inner.pty.set_minimum_read_interval(if observed { OBSERVED_READ_INTERVAL } else { HIDDEN_READ_INTERVAL });
        }
    }

    // MARK: Control

    pub fn start(&self, spec: LaunchSpec) {
        let (cols, rows) = {
            let mut locked = self.inner.lock.lock().unwrap();
            locked.state = State::Starting;
            (locked.terminal.cols(), locked.terminal.rows())
        };
        self.report_status();
        let session = self.clone();
        self.inner.pty.start(spec, cols as u16, rows as u16, move |started| match started {
            Ok(pid) => {
                {
                    let mut locked = session.inner.lock.lock().unwrap();
                    locked.process_id = Some(pid);
                    locked.exit_code = None;
                }
                session.report_status();
            }
            Err(message) => session.fail(message),
        });
    }

    pub fn fail(&self, message: String) {
        self.inner.lock.lock().unwrap().state = State::Failed(message);
        self.report_status();
    }

    /// SIGHUP, as when a terminal window closes.
    pub fn stop(&self) {
        self.inner.pty.terminate();
    }

    /// Marks a session that was never started as stopped, so it shows as such.
    pub fn mark_stopped(&self) {
        self.inner.lock.lock().unwrap().state = State::Stopped;
        self.report_status();
    }

    /// Stops the program and what it started: SIGTERM to its process group, then SIGKILL if it
    /// is still running after `grace` seconds. `completion` runs on the session's thread once
    /// it has exited (right away when nothing runs).
    pub fn terminate(&self, grace: f64, completion: Option<Completion>) {
        let session = self.clone();
        // On the session's thread, so a `start` called just before has launched the program by then.
        self.inner.pty.run(move || {
            let mut locked = session.inner.lock.lock().unwrap();
            let Some(pid) = locked.process_id else {
                if locked.state == State::Starting {
                    locked.state = State::Stopped;
                }
                drop(locked);
                session.report_status();
                if let Some(completion) = completion {
                    completion();
                }
                return;
            };
            locked.stopping = true;
            locked.when_stopped.extend(completion);
            drop(locked);
            session.inner.pty.signal_group(libc::SIGTERM, pid, Duration::ZERO);
            session.inner.pty.signal_group(libc::SIGKILL, pid, Duration::try_from_secs_f64(grace).unwrap_or(Duration::ZERO));
        });
    }

    /// Types `bytes` into the program.
    pub fn send(&self, bytes: Vec<u8>) {
        if !bytes.is_empty() {
            self.inner.pty.write(bytes);
        }
    }

    /// Writes `text` into the terminal as if the program printed it, starting on a fresh line
    /// when `fresh_line` and the cursor isn't at the start of one. Every board that mirrors
    /// the session sees it.
    pub fn annotate(&self, text: &str, fresh_line: bool) {
        let locked = &mut *self.inner.lock.lock().unwrap();
        let fresh = if fresh_line && locked.terminal.cursor().column != 0 { "\r\n" } else { "" };
        let bytes = [fresh.as_bytes(), text.as_bytes()].concat();
        locked.terminal.feed(&bytes);
        if let Some(on_output) = &mut locked.on_output {
            on_output(&bytes);
        }
    }

    pub fn resize(&self, cols: usize, rows: usize) {
        {
            let mut locked = self.inner.lock.lock().unwrap();
            if cols == locked.terminal.cols() && rows == locked.terminal.rows() {
                return;
            }
            locked.terminal.resize(cols, rows);
        }
        self.inner.pty.resize(cols as u16, rows as u16);
    }

    // MARK: Process output (on the session's thread)

    fn received(&self, bytes: &[u8]) {
        let (reply, started, notifications) = {
            let locked = &mut *self.inner.lock.lock().unwrap();
            locked.terminal.feed(bytes);
            // In the same critical section as the parse: see `set_on_output`.
            if let Some(on_output) = &mut locked.on_output {
                on_output(bytes);
            }
            // Drained on every feed, so they never pile up where nobody listens.
            let notifications = locked.terminal.take_events().notifications;
            let started = locked.state == State::Starting;
            if started {
                locked.state = State::Running;
            }
            (locked.terminal.take_output(), started, notifications)
        };
        if let Some(reply) = reply {
            self.inner.pty.write(reply);
        }
        if started {
            self.report_status();
        }
        if let (false, Some(on_notify)) = (notifications.is_empty(), self.inner.on_notify.get()) {
            on_notify(notifications);
        }
    }

    fn exited(&self, status: i32) {
        let completions = {
            let mut locked = self.inner.lock.lock().unwrap();
            locked.process_id = None;
            // The wait status: the exit code in the second byte, or the signal in the low 7 bits.
            locked.exit_code = Some(if status & 0x7F == 0 { (status >> 8) & 0xFF } else { 128 + (status & 0x7F) });
            locked.state = if locked.stopping { State::Stopped } else { State::Exited };
            locked.stopping = false;
            std::mem::take(&mut locked.when_stopped)
        };
        self.report_status();
        completions.into_iter().for_each(|completion| completion());
    }

    fn report_status(&self) {
        if let Some(on_status) = self.inner.on_status.get() {
            on_status(self.status());
        }
    }
}
