import AgentRuntime
import Darwin
import Foundation

/// What the core costs a keystroke: the time from a key typed on the board to the program's
/// echo of it parsed into the board's terminal, with the PTY in the board's process (as before
/// the core) and on the real core, over its socket. Both sessions are observed, as a card on
/// screen is.
@MainActor
func latencyRun(samples: Int) async -> Bool {
    let echo = "stty raw -echo; exec cat"

    let local = AgentSession(cols: 80, rows: 24)
    let localTimes = Echo(local)
    local.isObserved = true
    local.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", echo], environment: ["PATH": "/usr/bin:/bin"], directory: "/tmp"))

    guard let instance = try? Instance(core: coreBinary), instance.replaceCore() else {
        say("The core didn't start.")
        return false
    }
    defer {
        if let client = CoreClient.connect(socketPath: instance.socket, timeout: 3) { client.shutdown() }
        instance.remove()
    }
    let card = Card.runner("echo", echo, in: instance.home)
    let setup = Board(socket: instance.socket, cards: [], startPrograms: false)
    guard await setup.start(), let client = setup.link.client else { return false }
    client.send(.addCard(card.record))
    try? await Task.sleep(for: .milliseconds(200))
    setup.kill()
    let board = Board(socket: instance.socket, cards: [card], startPrograms: true)
    guard let mirror = board.mirrors[card.id] else { return false }
    let coreTimes = Echo(mirror)
    _ = await board.start()
    mirror.isObserved = true

    try? await Task.sleep(for: .seconds(1))
    let results = await Task.detached { () -> ([Double], [Double]) in
        // Interleaved, so both see the same load.
        var a: [Double] = [], b: [Double] = []
        for _ in 0..<samples {
            if let time = localTimes.roundTrip() { a.append(time) }
            if let time = coreTimes.roundTrip() { b.append(time) }
        }
        return (a, b)
    }.value
    local.stop()
    board.kill()
    func line(_ name: String, _ times: [Double]) -> String {
        String(format: "%@: median %.2f ms, p95 %.2f ms, p99 %.2f ms (%d samples)", name,
               percentile(times, 0.5), percentile(times, 0.95), percentile(times, 0.99), times.count)
    }
    say(line("PTY in the board", results.0))
    say(line("on the core     ", results.1))
    return results.0.count == samples && results.1.count == samples
}

/// Times a byte typed into `session` until the program's echo of it reaches its terminal.
final class Echo: @unchecked Sendable {
    private let session: AgentSession
    private let arrived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var awaited: UInt8?

    init(_ session: AgentSession) {
        self.session = session
        session.onOutput = { [weak self] bytes in
            guard let self else { return }
            let hit = self.lock.withLock { self.awaited.map { bytes.contains($0) } ?? false }
            if hit {
                self.lock.withLock { self.awaited = nil }
                self.arrived.signal()
            }
        }
    }

    /// Milliseconds, or nil if no echo came within a second.
    func roundTrip() -> Double? {
        // Apart, at a random phase: a key isn't typed in step with the PTY's read timer.
        usleep(UInt32.random(in: 15_000...45_000))
        let byte = UInt8.random(in: UInt8(ascii: "a")...UInt8(ascii: "z"))
        lock.withLock { awaited = byte }
        let start = DispatchTime.now().uptimeNanoseconds
        session.send([byte])
        guard arrived.wait(timeout: .now() + 1) == .success else { return nil }
        return milliseconds(since: start)
    }
}
