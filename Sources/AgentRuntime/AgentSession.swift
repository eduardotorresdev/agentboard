import Foundation
import TerminalCore

/// What to run for a session; built by `AgentStore` from an `AgentProvider`.
public struct LaunchSpec: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

/// A running agent: its process on a PTY and the terminal that interprets its output.
///
/// Output is parsed on the session's queue as it arrives, visible or not, so the screen is
/// always current. Only an *observed* session (one whose card is on screen) tells the main
/// thread about changes; a hidden session costs parsing and nothing else.
public final class AgentSession {
    public enum State: Equatable, Sendable {
        /// Waiting for the process to launch and print its first output.
        case starting
        case running
        case exited
        case failed(String)
        /// Not running because it was asked to stop, or was never started.
        case stopped
    }

    /// Every session's queue drains on this one: parsing is fast, and output arriving from
    /// several agents at once is then handled by one thread instead of waking one per agent.
    private static let sharedQueue = DispatchQueue(label: "agentboard.sessions", qos: .userInitiated)
    private let queue = DispatchQueue(label: "agentboard.session", target: sharedQueue)
    private let pty: PseudoTerminal
    private let lock = NSLock()
    private let terminal: Terminal
    private var _state = State.starting
    private var _observed = false
    private var _processID: Int32?
    private var _exitCode: Int32?
    /// Set by `terminate` until the program exits: the exit then counts as a stop.
    private var stopping = false
    private var whenStopped: [() -> Void] = []
    /// Set when the board has been told about a change it hasn't drawn yet; while set, more
    /// output doesn't notify again. Cleared by `withTerminalForDisplay`.
    private var changePending = false
    /// When the program began a synchronized update (DEC mode 2026), to cap how long we wait.
    private var syncStart: Double?
    private static let syncTimeout = 0.2
    /// How long output may pile up in the PTY before it is read: under a frame while on screen,
    /// longer while hidden, where nobody is waiting for it.
    private static let observedReadInterval = 0.008
    private static let hiddenReadInterval = 0.05

    /// Called on the main queue while the session is observed, at most once per change the
    /// board hasn't drawn yet.
    public var onChange: (() -> Void)?

    public init(cols: Int, rows: Int) {
        terminal = Terminal(cols: cols, rows: rows, scrollback: 5000)
        terminal.reportedForeground = 0x26213A
        terminal.reportedBackground = 0xFFFFFF
        pty = PseudoTerminal(queue: queue)
        pty.minimumReadInterval = Self.hiddenReadInterval
        pty.onOutput = { [weak self] bytes in self?.received(bytes) }
        pty.onExit = { [weak self] status in self?.exited(status) }
    }

    public var state: State { lock.withLock { _state } }

    /// The program's process id while it runs.
    public var processID: Int32? { lock.withLock { _processID } }

    /// How the program last ended: its exit code, or 128 + the signal that killed it.
    public var exitCode: Int32? { lock.withLock { _exitCode } }

    /// Runs `body` with exclusive access to the terminal (for rendering and input encoding).
    public func withTerminal<T>(_ body: (Terminal) -> T) -> T {
        lock.withLock { body(terminal) }
    }

    /// Runs `body` with the terminal to draw it, and marks its changes as seen: the next output
    /// notifies the board again.
    public func withTerminalForDisplay<T>(_ body: (Terminal) -> T) -> T {
        lock.withLock {
            changePending = false
            return body(terminal)
        }
    }

    /// Whether the board is showing this session. Turning it on schedules a redraw.
    public var isObserved: Bool {
        get { lock.withLock { _observed } }
        set {
            let changed = lock.withLock {
                defer { _observed = newValue }
                guard _observed != newValue else { return false }
                changePending = false
                return true
            }
            guard changed else { return }
            let interval = newValue ? Self.observedReadInterval : Self.hiddenReadInterval
            queue.async { [pty] in pty.minimumReadInterval = interval }
            if newValue { scheduleChange() }
        }
    }

    /// True while the program is midway through a synchronized update that hasn't timed out:
    /// the renderer keeps showing the previous frame instead of a half-drawn one.
    public var isMidUpdate: Bool {
        lock.withLock {
            guard terminal.isSynchronizing, let syncStart else { return false }
            return MonotonicClock.now() - syncStart < Self.syncTimeout
        }
    }

    public func start(_ spec: LaunchSpec) {
        lock.withLock { _state = .starting }
        scheduleChange()
        let size = lock.withLock { (terminal.cols, terminal.rows) }
        queue.async { [self] in
            do {
                try pty.start(executable: spec.executable, arguments: spec.arguments, environment: spec.environment,
                              directory: spec.directory, cols: size.0, rows: size.1)
                let pid = pty.pid
                lock.withLock {
                    _processID = pid
                    _exitCode = nil
                }
            } catch {
                fail("\(error)")
            }
        }
    }

    public func fail(_ message: String) {
        lock.withLock { _state = .failed(message) }
        scheduleChange(force: true)
    }

    public func stop() { pty.terminate() }

    /// Marks a session that was never started as stopped, so it shows as such.
    public func markStopped() {
        lock.withLock { _state = .stopped }
        scheduleChange(force: true)
    }

    /// Stops the program and what it started: SIGTERM to its process group, then SIGKILL if it
    /// is still running after `grace` seconds. `completion` runs on the main queue once it has
    /// exited (right away when nothing runs).
    public func terminate(grace: Double = 3, then completion: (() -> Void)? = nil) {
        // On the queue, so a `start` called just before has launched the program by then.
        queue.async { [self] in
            let pid = lock.withLock { () -> Int32? in
                guard let pid = _processID else { return nil }
                stopping = true
                if let completion { whenStopped.append(completion) }
                return pid
            }
            guard let pid else {
                lock.withLock { if _state == .starting { _state = .stopped } }
                scheduleChange(force: true)
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            pty.signalGroup(SIGTERM, ifStill: pid)
            // Holds the PTY, not the session: the kill must happen even if the card is gone by then.
            queue.asyncAfter(deadline: .now() + grace) { [pty] in pty.signalGroup(SIGKILL, ifStill: pid) }
        }
    }

    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pty.write(bytes)
    }

    public func resize(cols: Int, rows: Int) {
        let changed = lock.withLock {
            guard cols != terminal.cols || rows != terminal.rows else { return false }
            terminal.resize(cols: cols, rows: rows)
            return true
        }
        guard changed else { return }
        pty.resize(cols: cols, rows: rows)
        scheduleChange()
    }

    // MARK: Process output (on `queue`)

    private func received(_ bytes: UnsafeRawBufferPointer) {
        let (reply, notify) = lock.withLock { () -> ([UInt8]?, Bool) in
            terminal.feed(bytes)
            if _state == .starting { _state = .running }
            if terminal.isSynchronizing {
                if syncStart == nil { syncStart = MonotonicClock.now() }
            } else {
                syncStart = nil
            }
            let waiting = syncStart.map { MonotonicClock.now() - $0 < Self.syncTimeout } ?? false
            return (terminal.takeOutput(), _observed && !waiting)
        }
        if let reply { pty.write(reply) }
        if notify { scheduleChange() }
    }

    private func exited(_ status: Int32) {
        let completions = lock.withLock { () -> [() -> Void] in
            _processID = nil
            // The wait status: the exit code in the second byte, or the signal in the low 7 bits.
            _exitCode = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            _state = stopping ? .stopped : .exited
            stopping = false
            defer { whenStopped.removeAll() }
            return whenStopped
        }
        scheduleChange(force: true)
        if !completions.isEmpty { DispatchQueue.main.async { completions.forEach { $0() } } }
    }

    /// Coalesces notifications: one main-queue hop per frame the board draws, none while hidden.
    /// `force` notifies even with one pending: the program ended or failed, which the board must
    /// show even when it happens before the frame for its last output is drawn.
    private func scheduleChange(force: Bool = false) {
        let schedule = lock.withLock {
            guard _observed, force || !changePending else { return false }
            changePending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

enum MonotonicClock {
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
}
