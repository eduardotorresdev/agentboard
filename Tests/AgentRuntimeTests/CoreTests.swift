import Foundation
import Testing
@testable import AgentRuntime

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
}

private func screen(_ session: AgentSession) -> String {
    session.withTerminal { $0.screenText().joined(separator: "\n") }
}

private let shell = LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf 'ready\\n'; while read line; do printf 'got %s\\n' \"$line\"; done"],
                               environment: ["PATH": "/usr/bin:/bin"], directory: NSTemporaryDirectory())

/// A core on a socket of its own, and a way to connect boards to it.
private final class Fixture {
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    let server: CoreServer

    init() throws {
        server = CoreServer(socketPath: path, idleTimeout: 60)
        try server.start()
    }

    func board() throws -> CoreClient { try #require(CoreClient.connect(socketPath: path, timeout: 3)) }

    deinit {
        server.stop()
        unlink(path)
    }
}

/// A core of the build before this one: answers hello with `welcome`, as that build wrote it.
private final class OldCore {
    let path = NSTemporaryDirectory() + "abold-\(UUID().uuidString.prefix(8)).sock"
    private let queue = DispatchQueue(label: "old-core")
    private var sockets: [CoreSocket] = []
    private let listener: Int32
    private(set) var hello: [String: Any]?

    init(welcome: String) throws {
        listener = try UnixSocket.listen(at: path)
        let listener = self.listener
        Thread.detachNewThread { [weak self] in
            let fd = accept(listener, nil, nil)
            guard fd >= 0, let self else { return }
            let socket = CoreSocket(fd: fd, queue: self.queue)
            socket.onFrame = { [weak self] kind, payload in
                guard kind == .control, let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { return }
                self?.hello = json["hello"] as? [String: Any]
                socket.send(.control, Array(welcome.utf8))
            }
            self.queue.sync { self.sockets.append(socket) }
            socket.start()
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

/// What a core sends a board: the welcome, decoded loosely.
private func welcome(from path: String, hello: String) throws -> [String: Any]? {
    let socket = CoreSocket(fd: try UnixSocket.connect(to: path), queue: DispatchQueue(label: "old-board"))
    let got = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var welcome: [String: Any]?
    socket.onFrame = { kind, payload in
        guard kind == .control, let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { return }
        welcome = json["welcome"] as? [String: Any]
        got.signal()
    }
    socket.start()
    socket.send(.control, Array(hello.utf8))
    _ = got.wait(timeout: .now() + 3)
    socket.close()
    return welcome
}

struct CoreTests {
    /// Scenario 6 of GOAL.md: a board of the build before talks to this core, which answers in
    /// the version that board speaks.
    @Test func talksToTheBoardBefore() throws {
        let core = try Fixture()
        // As that build says hello: it doesn't say which versions it still speaks.
        let answer = try #require(try welcome(from: core.path, hello: #"{"hello":{"version":2}}"#))
        #expect(answer["version"] as? Int == 2)
        #expect(answer["sessions"] != nil)
    }

    /// Scenario 6: this board talks to a core of the build before, in that build's version.
    @Test func talksToTheCoreBefore() throws {
        let old = try OldCore(welcome: #"{"welcome":{"version":2,"sessions":[]}}"#)
        let board = try CoreClient.open(socketPath: old.path, timeout: 3).get()
        #expect(board.version == 2)
        #expect(old.hello?["version"] as? Int == CoreProtocol.version)
        #expect(old.hello?["oldest"] as? Int == CoreProtocol.oldest)
        board.disconnect()
    }

    /// Scenario 6: builds with no version in common don't talk, and the board learns which
    /// versions the core speaks, to say what to do.
    @Test func buildsTooFarApartDontTalk() throws {
        let core = try Fixture()
        core.server.versions = CoreProtocol.Versions(version: CoreProtocol.version + 3, oldest: CoreProtocol.version + 2)
        let newer = CoreClient.open(socketPath: core.path, timeout: 3)
        #expect(throws: CoreClient.Failure.incompatible(core: core.server.versions)) { try newer.get() }

        core.server.versions = CoreProtocol.Versions(version: CoreProtocol.oldest - 1, oldest: CoreProtocol.oldest - 1)
        let older = CoreClient.open(socketPath: core.path, timeout: 3)
        #expect(throws: CoreClient.Failure.incompatible(core: core.server.versions)) { try older.get() }

        // And this core turns away a board too old for it.
        core.server.versions = CoreProtocol.versions
        let answer = try #require(try welcome(from: core.path, hello: #"{"hello":{"version":1}}"#))
        #expect(answer["version"] as? Int == CoreProtocol.version)
        #expect((answer["sessions"] as? [Any])?.isEmpty == true)
    }

    /// A mirrored session shows the program's output and sends it input, like a local one.
    @Test func mirrorsAProgram() async throws {
        let core = try Fixture()
        let board = try core.board()
        let id = UUID()
        let session = AgentSession(cols: 40, rows: 6)
        session.host(on: board, id: id)
        session.start(shell)
        try await waitUntil { screen(session).contains("ready") }
        #expect(session.state == .running)
        #expect(session.processID != nil)
        session.send(Array("hello\r".utf8))
        try await waitUntil { screen(session).contains("got hello") }
        #expect(screen(session).contains("got hello"))
        session.close(grace: 1)
    }

    /// The point of the core: the board goes away, the program keeps running, and a new board
    /// picks up the same screen and keeps talking to it.
    @Test func programOutlivesTheBoard() async throws {
        let core = try Fixture()
        let id = UUID()
        var first: AgentSession? = AgentSession(cols: 40, rows: 6)
        let firstBoard = try core.board()
        first!.host(on: firstBoard, id: id)
        first!.start(shell)
        try await waitUntil { screen(first!).contains("ready") }
        first!.send(Array("before\r".utf8))
        try await waitUntil { screen(first!).contains("got before") }
        let pid = first!.processID
        let before = screen(first!)
        firstBoard.disconnect()
        first = nil

        let board = try core.board()
        #expect(board.known[id]?.state == .running)
        #expect(board.known[id]?.processID == pid)
        let session = AgentSession(cols: 30, rows: 4)
        session.host(on: board, id: id)
        session.attach()
        try await waitUntil { screen(session).contains("got before") }
        #expect(session.processID == pid)
        #expect(session.state == .running)
        // The snapshot comes at the core's size, kept until the board asks for its own.
        #expect(session.withTerminal { ($0.cols, $0.rows) } == (40, 6))
        session.resize(cols: 30, rows: 4)
        #expect(session.withTerminal { ($0.cols, $0.rows) } == (30, 4))
        #expect(before.contains("got before"))
        session.send(Array("after\r".utf8))
        try await waitUntil { screen(session).contains("got after") }
        #expect(screen(session).contains("got after"))
        session.close(grace: 1)
    }

    /// Terminating through the core reports the stop back and runs the completion.
    @Test func terminateCompletes() async throws {
        let core = try Fixture()
        let board = try core.board()
        let session = AgentSession(cols: 40, rows: 6)
        session.host(on: board, id: UUID())
        session.start(shell)
        try await waitUntil { session.processID != nil }
        let done = Counter()
        session.terminate(grace: 1) { done.increment() }
        try await waitUntil { done.value == 1 }
        #expect(session.state == .stopped)
        #expect(session.processID == nil)
    }

    /// Text the board writes into a terminal (a restart marker) reaches every mirror in order.
    @Test func annotationsReachEveryBoard() async throws {
        let core = try Fixture()
        let id = UUID()
        let a = AgentSession(cols: 40, rows: 6), b = AgentSession(cols: 40, rows: 6)
        a.host(on: try core.board(), id: id)
        a.start(shell)
        try await waitUntil { screen(a).contains("ready") }
        b.host(on: try core.board(), id: id)
        b.attach()
        try await waitUntil { screen(b).contains("ready") }
        a.annotate("-- restarted --", freshLine: true)
        try await waitUntil { screen(a).contains("restarted") && screen(b).contains("restarted") }
        #expect(screen(a) == screen(b))
        a.close(grace: 1)
    }

    /// The real core binary: launched detached when no core answers, keeps the program running
    /// after the board leaves, and ends everything on shutdown.
    @Test func launchesTheCoreBinary() async throws {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/AgentBoardCore")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the AgentBoardCore product first")
        let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let id = UUID()
        let first = try #require(CoreClient.connect(socketPath: path, launching: binary, timeout: 5))
        let session = AgentSession(cols: 40, rows: 6)
        session.host(on: first, id: id)
        session.start(shell)
        try await waitUntil { session.processID != nil }
        let pid = try #require(session.processID)
        first.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(pid, 0) == 0)

        let second = try #require(CoreClient.connect(socketPath: path, timeout: 3))
        #expect(second.known[id]?.processID == pid)
        second.shutdown()
        try await waitUntil { kill(pid, 0) != 0 }
        #expect(kill(pid, 0) != 0)
        try await waitUntil { (try? UnixSocket.connect(to: path)).map { close($0); return false } ?? true }
        #expect((try? UnixSocket.connect(to: path)) == nil)
    }
}
