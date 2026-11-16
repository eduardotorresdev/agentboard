use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::core_protocol::LaunchSpec;

/// Held while a descriptor exists that isn't close-on-exec yet (a PTY's master just opened) and
/// while another program is forked, so none inherits a master: its PTY would never end.
pub(crate) static FORK_LOCK: Mutex<()> = Mutex::new(());

/// A child process attached to a pseudo-terminal, run by a thread of its own (the Swift one's
/// queue): it waits on the PTY, on a pipe that says a command came and on its timers, never
/// polling. Every method is safe from any thread and returns at once; commands run in the
/// order they were given.
pub struct PseudoTerminal {
    commands: Sender<Command>,
    wake: Arc<OwnedFd>,
}

type Started = Box<dyn FnOnce(Result<i32, String>) + Send>;

enum Command {
    Start { spec: LaunchSpec, cols: u16, rows: u16, done: Started },
    Write(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Terminate,
    SignalGroup { signal: i32, expected: i32, after: Duration },
    MinimumReadInterval(f64),
    Run(Box<dyn FnOnce() + Send>),
}

impl PseudoTerminal {
    /// `on_output` is called on the PTY's thread with each chunk the program writes; `on_exit`
    /// once the program has exited, with its wait status.
    pub fn new(on_output: impl FnMut(&[u8]) + Send + 'static, on_exit: impl FnMut(i32) + Send + 'static) -> io::Result<Self> {
        let (wake_read, wake) = pipe()?;
        let wake = Arc::new(wake);
        let (commands, receiver) = channel();
        let mut worker = Worker {
            commands: receiver,
            wake_read,
            wake: wake.clone(),
            exited: Arc::new(AtomicBool::new(false)),
            disconnected: false,
            master: None,
            pid: 0,
            reading: false,
            pending_write: Vec::new(),
            read_buffer: vec![0; 64 * 1024],
            minimum_read_interval: 0.0,
            last_read: Instant::now(),
            paused_until: None,
            signals: Vec::new(),
            on_output: Box::new(on_output),
            on_exit: Box::new(on_exit),
        };
        std::thread::Builder::new().name("agentboard.session".into()).spawn(move || worker.run())?;
        Ok(Self { commands, wake })
    }

    fn command(&self, command: Command) {
        if self.commands.send(command).is_ok() {
            wake(&self.wake);
        }
    }

    /// Starts the program; `done` is called on the PTY's thread with its process id, or why it
    /// couldn't be forked. A program that can't be executed exits with 127, as in a shell.
    pub fn start(&self, spec: LaunchSpec, cols: u16, rows: u16, done: impl FnOnce(Result<i32, String>) + Send + 'static) {
        self.command(Command::Start { spec, cols, rows, done: Box::new(done) });
    }

    /// Queues bytes for the program.
    pub fn write(&self, bytes: Vec<u8>) {
        self.command(Command::Write(bytes));
    }

    /// Tells the program its window changed size (it receives SIGWINCH).
    pub fn resize(&self, cols: u16, rows: u16) {
        self.command(Command::Resize { cols, rows });
    }

    /// SIGHUP, as when a terminal window closes.
    pub fn terminate(&self) {
        self.command(Command::Terminate);
    }

    /// Sends `signal` to the program and every process in its group (what it started, unless
    /// those made groups of their own) `after` that long, when the program running is still
    /// `expected`. The PTY's thread holds the timer: it fires even if the session is gone by then.
    pub fn signal_group(&self, signal: i32, expected: i32, after: Duration) {
        self.command(Command::SignalGroup { signal, expected, after });
    }

    /// The least time between two reads. A program that writes in many small pieces would
    /// otherwise wake the thread for each one; when output comes faster than this, reading
    /// pauses so the pieces pile up in the PTY and arrive in one read. Output after a quiet
    /// spell is read at once, and heavy output (a large read) is never held back.
    pub fn set_minimum_read_interval(&self, seconds: f64) {
        self.command(Command::MinimumReadInterval(seconds));
    }

    /// Runs `body` on the PTY's thread, after the commands given before it.
    pub fn run(&self, body: impl FnOnce() + Send + 'static) {
        self.command(Command::Run(Box::new(body)));
    }
}

impl Drop for PseudoTerminal {
    /// The program is hung up on; the thread ends once it has exited (it still reaps it).
    fn drop(&mut self) {
        wake(&self.wake);
    }
}

pub(crate) fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: `fds` has room for the two descriptors, which are then owned exactly once.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
        }
        Ok((OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])))
    }
}

fn wake(fd: &OwnedFd) {
    // SAFETY: writes one byte from a live buffer; a full pipe already holds a wake-up.
    unsafe { libc::write(fd.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
}

/// A turn's worth of output that counts as heavy and is never paced: what a PTY holds at
/// most, so reading it means the program is being held back. macOS gives 1024 bytes at a time
/// (measured), Linux 4096. The Swift core compares one read against 4096, which on macOS
/// never is: there the pacing also slows a program that prints a lot.
#[cfg(target_vendor = "apple")]
const HEAVY_READ: usize = 1024;
#[cfg(not(target_vendor = "apple"))]
const HEAVY_READ: usize = 4096;
/// The most read in one turn before commands (input, signals) get theirs.
const READ_TURN: usize = 1024 * 1024;

struct Worker {
    commands: Receiver<Command>,
    wake_read: OwnedFd,
    wake: Arc<OwnedFd>,
    /// Set by the thread that waits for the program to exit.
    exited: Arc<AtomicBool>,
    /// The `PseudoTerminal` was dropped: no more commands come.
    disconnected: bool,
    master: Option<OwnedFd>,
    /// The running program, 0 when none.
    pid: i32,
    /// False once the PTY reported end-of-file: the program's side is closed.
    reading: bool,
    pending_write: Vec<u8>,
    read_buffer: Vec<u8>,
    minimum_read_interval: f64,
    last_read: Instant,
    paused_until: Option<Instant>,
    /// Signals to send later: when, which, and to which program.
    signals: Vec<(Instant, i32, i32)>,
    on_output: Box<dyn FnMut(&[u8]) + Send>,
    on_exit: Box<dyn FnMut(i32) + Send>,
}

impl Worker {
    fn run(&mut self) {
        loop {
            // The session is gone; a program still running is reaped first.
            if self.disconnected && self.pid == 0 {
                return;
            }
            let now = Instant::now();
            if self.paused_until.is_some_and(|until| until <= now) {
                self.paused_until = None;
            }
            self.signals.retain(|&(when, signal, expected)| {
                if when > now {
                    return true;
                }
                if self.pid > 0 && self.pid == expected {
                    // SAFETY: forkpty made the program a session leader, so its group id is
                    // its pid; it isn't reaped yet, so the id can't be another program's.
                    unsafe { libc::kill(-self.pid, signal) };
                }
                false
            });

            let mut events = 0;
            if self.reading && self.paused_until.is_none() {
                events |= libc::POLLIN;
            }
            if !self.pending_write.is_empty() {
                events |= libc::POLLOUT;
            }
            // Left out while nothing is wanted from it: a hung-up PTY would wake the poll forever.
            let master = self.master.as_ref().filter(|_| events != 0).map_or(-1, |fd| fd.as_raw_fd());
            let mut fds = [libc::pollfd { fd: self.wake_read.as_raw_fd(), events: libc::POLLIN, revents: 0 }, libc::pollfd { fd: master, events, revents: 0 }];
            let deadline = self.signals.iter().map(|signal| signal.0).chain(self.paused_until).min();
            let timeout = deadline.map_or(-1, |deadline| deadline.saturating_duration_since(now).as_micros().div_ceil(1000).min(i32::MAX as u128) as i32);
            // SAFETY: `fds` is a live array of two pollfds.
            if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } <= 0 {
                continue;
            }

            if fds[1].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 && events & libc::POLLIN != 0 {
                self.read_available();
            }
            if fds[1].revents != 0 && !self.pending_write.is_empty() {
                self.flush();
            }
            if fds[0].revents != 0 {
                let mut drained = [0u8; 64];
                // SAFETY: reads into a live buffer from a non-blocking pipe.
                unsafe { libc::read(self.wake_read.as_raw_fd(), drained.as_mut_ptr().cast(), drained.len()) };
                loop {
                    match self.commands.try_recv() {
                        Ok(command) => self.handle(command),
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Disconnected) => {
                            if !self.disconnected && self.pid > 0 {
                                // Nobody can stop the program any more: hang up, as closing
                                // its terminal window would. (The Swift core leaves it running.)
                                // SAFETY: the program isn't reaped yet, so the pid is its own.
                                unsafe { libc::kill(self.pid, libc::SIGHUP) };
                            }
                            self.disconnected = true;
                            break;
                        }
                    }
                }
                if self.exited.load(Ordering::Acquire) {
                    self.reap();
                }
            }
        }
    }

    fn handle(&mut self, command: Command) {
        match command {
            Command::Start { spec, cols, rows, done } => {
                // shortcut: starting over a program still running keeps that one (the Swift core
                // would orphan it); end it first to restart.
                let result = if self.pid > 0 { Ok(self.pid) } else { self.start(&spec, cols, rows) };
                done(result);
            }
            Command::Write(bytes) => {
                if self.pid > 0 {
                    self.pending_write.extend_from_slice(&bytes);
                    self.flush();
                }
            }
            Command::Resize { cols, rows } => {
                if let (true, Some(master)) = (self.pid > 0, &self.master) {
                    let size = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
                    // SAFETY: TIOCSWINSZ reads a winsize, which outlives the call.
                    unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ as _, &size) };
                }
            }
            Command::Terminate => {
                if self.pid > 0 {
                    // SAFETY: the program isn't reaped yet, so the pid is still its own.
                    unsafe { libc::kill(self.pid, libc::SIGHUP) };
                }
            }
            Command::SignalGroup { signal, expected, after } => self.signals.push((Instant::now() + after, signal, expected)),
            Command::MinimumReadInterval(seconds) => self.minimum_read_interval = seconds,
            Command::Run(body) => body(),
        }
    }

    fn start(&mut self, spec: &LaunchSpec, cols: u16, rows: u16) -> Result<i32, String> {
        // Everything the child needs is prepared before fork: between fork and exec only
        // async-signal-safe calls are allowed (no allocation, no locks).
        let text = |text: &str| CString::new(text).map_err(|_| "a NUL byte in the launch".to_string());
        let path = text(&spec.executable)?;
        let directory = text(&spec.directory)?;
        let mut arguments = vec![path.clone()];
        for argument in &spec.arguments {
            arguments.push(text(argument)?);
        }
        let mut environment = Vec::new();
        for (key, value) in &spec.environment {
            environment.push(text(&format!("{key}={value}"))?);
        }
        let pointers = |strings: &[CString]| strings.iter().map(|string| string.as_ptr()).chain([std::ptr::null()]).collect::<Vec<_>>();
        let (argv, envp) = (pointers(&arguments), pointers(&environment));
        let mut size = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
        // SAFETY: sysconf only reads a limit.
        let open_limit = unsafe { libc::sysconf(libc::_SC_OPEN_MAX) }.clamp(256, 65_536) as i32;

        let forking = FORK_LOCK.lock().unwrap();
        let mut master: RawFd = -1;
        // SAFETY: forkpty writes the master into `master`; the size outlives the call. The child
        // branch below calls only async-signal-safe functions on memory prepared above, and
        // never returns.
        let child = unsafe { libc::forkpty(&mut master, std::ptr::null_mut(), std::ptr::null_mut(), &mut size) };
        if child < 0 {
            return Err(crate::error_text(&io::Error::last_os_error()));
        }
        if child == 0 {
            // SAFETY: see above.
            unsafe {
                // Don't pass the core's signal dispositions (SIGPIPE is ignored here) or mask on.
                let mut default_action: libc::sigaction = std::mem::zeroed();
                default_action.sa_sigaction = libc::SIG_DFL;
                for signal in 1..65 {
                    if signal != libc::SIGKILL && signal != libc::SIGSTOP {
                        libc::sigaction(signal, &default_action, std::ptr::null_mut());
                    }
                }
                let mut empty_mask: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut empty_mask);
                libc::sigprocmask(libc::SIG_SETMASK, &empty_mask, std::ptr::null_mut());
                // Nor the core's other descriptors: a pipe open elsewhere in the process would
                // never reach end-of-file while the program holds a copy.
                for descriptor in 3..open_limit {
                    libc::close(descriptor);
                }
                libc::chdir(directory.as_ptr());
                libc::execve(path.as_ptr(), argv.as_ptr(), envp.as_ptr());
                libc::_exit(127);
            }
        }
        // SAFETY: `master` is the descriptor forkpty just opened, owned from here on.
        let master = unsafe {
            libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC);
            libc::fcntl(master, libc::F_SETFL, libc::fcntl(master, libc::F_GETFL) | libc::O_NONBLOCK);
            OwnedFd::from_raw_fd(master)
        };
        drop(forking);

        self.master = Some(master);
        self.pid = child;
        self.reading = true;
        self.paused_until = None;
        self.exited = Arc::new(AtomicBool::new(false));
        let (exited, wake_fd) = (self.exited.clone(), self.wake.clone());
        // Waits for the exit without reaping: the pid stays the program's until this thread
        // reaps it, so a signal sent meanwhile can't reach another process.
        let waiter = std::thread::Builder::new().name("agentboard.exit".into()).stack_size(64 * 1024).spawn(move || {
            loop {
                // SAFETY: waitid fills `info`; WNOWAIT leaves the child to be reaped.
                let waited = unsafe {
                    let mut info: libc::siginfo_t = std::mem::zeroed();
                    libc::waitid(libc::P_PID, child as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
                };
                if waited == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                    break;
                }
            }
            exited.store(true, Ordering::Release);
            wake(&wake_fd);
        });
        if waiter.is_err() {
            // No thread to notice the exit: end the program rather than never report it.
            // SAFETY: the child isn't reaped, so the pid is its own.
            unsafe { libc::kill(-child, libc::SIGKILL) };
            self.exited.store(true, Ordering::Release);
            wake(&self.wake);
        }
        Ok(child)
    }

    fn read_available(&mut self) {
        let Some(master) = self.master.as_ref().map(|fd| fd.as_raw_fd()) else { return };
        let mut total = 0;
        loop {
            // SAFETY: reads into the live buffer, at most its length.
            let count = unsafe { libc::read(master, self.read_buffer.as_mut_ptr().cast(), self.read_buffer.len()) };
            if count > 0 {
                total += count as usize;
                (self.on_output)(&self.read_buffer[..count as usize]);
                // Until the PTY is empty, not until a short read: a PTY gives far less than
                // the buffer at a time even when more is waiting.
                if total >= READ_TURN {
                    break;
                }
            } else if count < 0 && matches!(io::Error::last_os_error().kind(), io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted) {
                break;
            } else {
                // EOF or EIO: the program's side closed. The exit is reported when it is reaped.
                self.reading = false;
                return;
            }
        }
        if total == 0 {
            return;
        }
        let now = Instant::now();
        let resume = self.last_read + Duration::from_secs_f64(self.minimum_read_interval);
        self.last_read = now;
        // Only a program writing faster than the interval is paused; a slow one costs no timer.
        if now < resume && total < HEAVY_READ {
            self.paused_until = Some(resume);
        }
    }

    fn flush(&mut self) {
        let Some(master) = self.master.as_ref().map(|fd| fd.as_raw_fd()) else { return };
        while !self.pending_write.is_empty() {
            // SAFETY: writes from the live buffer, at most its length.
            let written = unsafe { libc::write(master, self.pending_write.as_ptr().cast(), self.pending_write.len()) };
            if written > 0 {
                self.pending_write.drain(..written as usize);
                continue;
            }
            match io::Error::last_os_error().kind() {
                io::ErrorKind::Interrupted => continue,
                // The PTY buffer is full: the poll resumes this when it drains.
                io::ErrorKind::WouldBlock => break,
                _ => self.pending_write.clear(),
            }
        }
    }

    fn reap(&mut self) {
        if self.pid <= 0 {
            return;
        }
        let mut status = 0;
        // SAFETY: waitpid writes the status of our own child.
        if unsafe { libc::waitpid(self.pid, &mut status, libc::WNOHANG) } != self.pid {
            return;
        }
        self.pid = 0;
        self.exited.store(false, Ordering::Release);
        // Drain whatever the program wrote last, then stop reading.
        if self.reading {
            self.read_available();
        }
        self.reading = false;
        self.paused_until = None;
        self.master = None;
        self.pending_write.clear();
        self.signals.clear();
        (self.on_exit)(status);
    }
}
