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
///
/// A session either owns its PTY, or mirrors one the core owns (see `host(on:id:)`): the core
/// runs the program and sends its output, and this terminal parses the same bytes, so the board
/// draws and encodes input exactly as it does for a local session.
public final class AgentSession {
    public enum State: Equatable, Sendable, Codable {
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
    /// The core that runs this session's program, when it doesn't own a PTY itself.
    private var core: (client: CoreClient, id: UUID)?
    /// The size the board last asked for, if it did; a snapshot from the core may come in
    /// another one, which is kept until the board asks.
    private var requestedSize: (cols: Int, rows: Int)?

    /// Called on the main queue while the session is observed, at most once per change the
    /// board hasn't drawn yet.
    public var onChange: (() -> Void)?

    /// Called with each chunk of program output right after the terminal parsed it, while the
    /// terminal is still locked: whoever mirrors the terminal sees the same bytes in the same
    /// order, and none between a snapshot and the next chunk. Set before starting.
    public var onOutput: ((UnsafeRawBufferPointer) -> Void)?
    /// Called whenever `state`, `processID` or `exitCode` change, on any thread. Set before starting.
    public var onStatus: ((SessionStatus) -> Void)?

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

    public var status: SessionStatus { lock.withLock { currentStatus } }

    private var currentStatus: SessionStatus { SessionStatus(state: _state, processID: _processID, exitCode: _exitCode) }

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
            if let core {
                core.client.request(.observe(id: core.id, observed: newValue))
            } else {
                let interval = newValue ? Self.observedReadInterval : Self.hiddenReadInterval
                queue.async { [pty] in pty.minimumReadInterval = interval }
            }
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

    // MARK: Handing over to another core

    /// What another process needs to carry on running a session's program.
    public struct Handoff: Sendable {
        /// The PTY's master, the receiver's to own; -1 when no program runs (only the screen
        /// carries on).
        public let master: Int32
        public let processID: Int32
        public let status: SessionStatus
        /// The terminal as `Terminal.snapshot()` gives it, with every byte read so far parsed.
        public let snapshot: [UInt8]
        /// Typed into the session but not taken by the program yet.
        public let input: [UInt8]

        public init(master: Int32, processID: Int32, status: SessionStatus, snapshot: [UInt8], input: [UInt8] = []) {
            self.master = master
            self.processID = processID
            self.status = status
            self.snapshot = snapshot
            self.input = input
        }
    }

    /// Stops running the program here, leaving it untouched, and gives what another process
    /// needs to carry on: output not read yet stays in the PTY for it. Nil for a session that
    /// mirrors a core's. The session is done with afterwards.
    public func handOff() -> Handoff? {
        guard core == nil else { return nil }
        let released = queue.sync { pty.release() }
        return lock.withLock {
            var status = currentStatus
            if released == nil, status.processID != nil { status = SessionStatus(state: .stopped, processID: nil, exitCode: nil) }
            return Handoff(master: released?.master ?? -1, processID: released?.pid ?? 0, status: status, snapshot: terminal.snapshot(),
                           input: released?.input ?? [])
        }
    }

    /// A session carrying on a program another process handed over.
    public convenience init(adopting handoff: Handoff) {
        self.init(cols: 80, rows: 24)
        lock.withLock {
            terminal.restore(handoff.snapshot)
            _state = handoff.status.state
            _processID = handoff.master >= 0 ? handoff.processID : nil
            _exitCode = handoff.status.exitCode
        }
        guard handoff.master >= 0 else { return }
        queue.async { [self] in pty.adopt(master: handoff.master, pid: handoff.processID, input: handoff.input) }
    }

    // MARK: Hosting on the core

    /// Mirrors session `id` of `client`'s core instead of running programs here. Call before
    /// `start` or `attach`.
    public func host(on client: CoreClient, id: UUID) {
        core = (client, id)
        client.register(self, id: id)
        if isObserved { client.request(.observe(id: id, observed: true)) }
    }

    /// Picks up the core's session as it is now: its status, then its whole screen.
    public func attach() {
        guard let core else { return }
        core.client.request(.attach(id: core.id))
    }

    /// Ends the program, and on the core forgets the session too. `grace` as in `terminate`;
    /// nil hangs up instead, as closing a terminal window does.
    public func close(grace: Double?) {
        if let core {
            core.client.request(.close(id: core.id, grace: grace))
            core.client.unregister(core.id)
            return
        }
        // Whoever closes a session lets go of it: it holds itself until its program is reaped.
        lock.withLock { if _processID != nil { whenStopped.append { [self] in _ = self } } }
        if let grace { terminate(grace: grace) } else { stop() }
    }

    func coreReceived(_ bytes: UnsafeRawBufferPointer) { received(bytes) }

    func coreSnapshot(_ bytes: [UInt8]) {
        let resize = lock.withLock { () -> (Int, Int)? in
            guard terminal.restore(bytes) else { return nil }
            changePending = false
            syncStart = nil
            return requestedSize
        }
        scheduleChange(force: true)
        if let resize { self.resize(cols: resize.0, rows: resize.1) }
    }

    func coreStatus(_ status: SessionStatus) {
        let completions = lock.withLock { () -> [() -> Void] in
            _state = status.state
            _processID = status.processID
            _exitCode = status.exitCode
            guard status.processID == nil, status.state != .starting else { return [] }
            defer { whenStopped.removeAll() }
            return whenStopped
        }
        scheduleChange(force: true)
        if !completions.isEmpty { DispatchQueue.main.async { completions.forEach { $0() } } }
    }

    // MARK: Control

    public func start(_ spec: LaunchSpec) {
        lock.withLock { _state = .starting }
        reportStatus()
        scheduleChange()
        let size = lock.withLock { (terminal.cols, terminal.rows) }
        if let core {
            core.client.request(.start(id: core.id, spec: spec, cols: size.0, rows: size.1))
            return
        }
        queue.async { [self] in
            do {
                try pty.start(executable: spec.executable, arguments: spec.arguments, environment: spec.environment,
                              directory: spec.directory, cols: size.0, rows: size.1)
                let pid = pty.pid
                lock.withLock {
                    _processID = pid
                    _exitCode = nil
                }
                reportStatus()
            } catch {
                fail("\(error)")
            }
        }
    }

    public func fail(_ message: String) {
        lock.withLock { _state = .failed(message) }
        reportStatus()
        scheduleChange(force: true)
    }

    public func stop() {
        if let core { return core.client.request(.stop(id: core.id)) }
        pty.terminate()
    }

    /// Marks a session that was never started as stopped, so it shows as such.
    public func markStopped() {
        lock.withLock { _state = .stopped }
        reportStatus()
        scheduleChange(force: true)
    }

    /// Stops the program and what it started: SIGTERM to its process group, then SIGKILL if it
    /// is still running after `grace` seconds. `completion` runs on the main queue once it has
    /// exited (right away when nothing runs).
    public func terminate(grace: Double = 3, then completion: (() -> Void)? = nil) {
        if let core {
            if let completion { lock.withLock { whenStopped.append(completion) } }
            return core.client.request(.terminate(id: core.id, grace: grace))
        }
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
                reportStatus()
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
        if let core { return core.client.input(bytes, to: core.id) }
        pty.write(bytes)
    }

    /// Writes `text` into the terminal as if the program printed it, starting on a fresh line
    /// when `freshLine` and the cursor isn't at the start of one. On the core, every board that
    /// mirrors the session sees it.
    public func annotate(_ text: String, freshLine: Bool = false) {
        if let core { return core.client.request(.annotate(id: core.id, text: text, freshLine: freshLine)) }
        let notify = lock.withLock { () -> Bool in
            let bytes = Array(((freshLine && terminal.cursor.column != 0 ? "\r\n" : "") + text).utf8)
            terminal.feed(bytes)
            bytes.withUnsafeBytes { onOutput?($0) }
            return _observed
        }
        if notify { scheduleChange() }
    }

    public func resize(cols: Int, rows: Int) {
        let changed = lock.withLock {
            requestedSize = (cols, rows)
            guard cols != terminal.cols || rows != terminal.rows else { return false }
            terminal.resize(cols: cols, rows: rows)
            return true
        }
        guard changed else { return }
        if let core {
            core.client.request(.resize(id: core.id, cols: cols, rows: rows))
        } else {
            pty.resize(cols: cols, rows: rows)
        }
        scheduleChange()
    }

    // MARK: Process output (on `queue`, or the core client's queue when mirroring)

    private func received(_ bytes: UnsafeRawBufferPointer) {
        let (reply, notify, started) = lock.withLock { () -> ([UInt8]?, Bool, Bool) in
            terminal.feed(bytes)
            onOutput?(bytes)
            let started = _state == .starting
            if started { _state = .running }
            if terminal.isSynchronizing {
                if syncStart == nil { syncStart = MonotonicClock.now() }
            } else {
                syncStart = nil
            }
            let waiting = syncStart.map { MonotonicClock.now() - $0 < Self.syncTimeout } ?? false
            // A mirror's replies are the core's to send: its own terminal answers the program.
            let reply = terminal.takeOutput()
            return (core == nil ? reply : nil, _observed && !waiting, started)
        }
        if let reply { pty.write(reply) }
        if started { reportStatus() }
        if notify { scheduleChange() }
    }

    private func exited(_ status: Int32?) {
        let completions = lock.withLock { () -> [() -> Void] in
            _processID = nil
            // The wait status: the exit code in the second byte, or the signal in the low 7 bits.
            // Unknown for a program this process adopted.
            _exitCode = status.map { $0 & 0x7F == 0 ? ($0 >> 8) & 0xFF : 128 + ($0 & 0x7F) }
            _state = stopping ? .stopped : .exited
            stopping = false
            defer { whenStopped.removeAll() }
            return whenStopped
        }
        reportStatus()
        scheduleChange(force: true)
        if !completions.isEmpty { DispatchQueue.main.async { completions.forEach { $0() } } }
    }

    private func reportStatus() {
        guard let onStatus else { return }
        onStatus(status)
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
