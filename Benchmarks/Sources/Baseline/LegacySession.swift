import Foundation
import SwiftTerm

/// One running agent: a child process on a PTY whose output is parsed by SwiftTerm's headless
/// `Terminal`. Parsing happens on a private queue; the renderer pulls snapshots when it draws.
final class LegacySession: TerminalDelegate, LocalProcessDelegate {
    enum State: Equatable {
        /// Waiting for the process to launch and print its first output.
        case starting
        case running
        case exited
        case failed(String)
    }

    private(set) var terminal: Terminal!
    private var process: LocalProcess!
    private let queue = DispatchQueue(label: "agentboard.session")
    private let lock = NSLock()
    private var _dirty = true
    private var _cursorVisible = true
    private var _state: State = .starting
    /// Mirrors the terminal size so the PTY can read it without taking the terminal lock.
    private var size: (cols: Int, rows: Int)

    /// Called on the main queue, at most once per run loop turn, after new output arrives.
    var onChange: (() -> Void)?
    private var changeScheduled = false

    init(cols: Int, rows: Int) {
        size = (cols, rows)
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    var state: State { lock.withLock { _state } }
    var cursorVisible: Bool { lock.withLock { _cursorVisible } }

    /// True once since the last call when output changed the screen.
    func takeDirty() -> Bool {
        lock.withLock {
            defer { _dirty = false }
            return _dirty
        }
    }

    func fail(_ message: String) {
        lock.withLock { _state = .failed(message) }
        markChanged()
    }

    func start(executable: String, args: [String], directory: String, path: String) {
        // Drop markers inherited when the app itself was launched from an agent, so the child
        // behaves like a top-level session (Claude Code disables transcripts for child sessions).
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
        env["PATH"] = path
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        lock.withLock { _state = .starting }
        process.startProcess(executable: executable, args: args,
                             environment: env.map { "\($0)=\($1)" },
                             currentDirectory: directory)
    }

    func stop() {
        if process.running { process.terminate() }
    }

    func snapshot() -> TerminalContentSnapshot {
        terminal.contentSnapshot(region: .viewport)
    }

    func send(_ bytes: [UInt8]) {
        guard process.running else { return }
        process.send(data: bytes[...])
    }

    func resize(cols: Int, rows: Int) {
        let changed = terminal.terminalLock.withLock {
            guard cols != terminal.cols || rows != terminal.rows else { return false }
            terminal.resize(cols: cols, rows: rows)
            return true
        }
        guard changed else { return }
        lock.withLock { self.size = (cols, rows) }
        var windowSize = getWindowSize()
        if process.running { _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &windowSize) }
        markChanged()
    }

    private func markChanged() {
        let notify = lock.withLock {
            _dirty = true
            defer { self.changeScheduled = true }
            return !self.changeScheduled
        }
        guard notify else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lock.withLock { self.changeScheduled = false }
            onChange?()
        }
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock { terminal.feed(buffer: slice) }
        lock.withLock { if _state == .starting { _state = .running } }
        markChanged()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.withLock { _state = .exited }
        markChanged()
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        lock.withLock { _state = .failed("\(error)") }
        markChanged()
    }

    func getWindowSize() -> winsize {
        let (cols, rows) = lock.withLock { size }
        return winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalDelegate

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func showCursor(source: Terminal) { lock.withLock { _cursorVisible = true } }
    func hideCursor(source: Terminal) { lock.withLock { _cursorVisible = false } }
}
