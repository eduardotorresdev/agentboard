import AgentRuntime
import Connections
import Foundation
import Testing
@testable import Orchestration

/// The Rust core (`core/`, docs/hosts.md) with its orchestrator, serving this build's board
/// over the real `CoreLink`. Needs its binary:
/// `AGENTBOARD_RUST_CORE=core/target/debug/agentboard swift test --filter RustOrchestratorTests`.
@MainActor struct RustOrchestratorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_RUST_CORE"] != nil))
    func aSwiftBoardKeepsItsCardsOnTheRustCore() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["AGENTBOARD_RUST_CORE"])
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abhome-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = NSTemporaryDirectory() + "abrust-\(UUID().uuidString.prefix(8)).sock"
        let core = Process()
        core.executableURL = URL(fileURLWithPath: binary)
        core.arguments = ["core", "--socket", path]
        core.environment = ProcessInfo.processInfo.environment.merging(["AGENTBOARD_HOME": home.path]) { $1 }
        try core.run()
        defer {
            if core.isRunning { core.terminate() }
            unlink(path)
            unlink(path + ".lock")
            try? FileManager.default.removeItem(at: home)
        }
        // Generous: the core asks the login shell for PATH, and the runner runs in one too.
        func waitUntil(_ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }

        let link = CoreLink { CoreClient.open(socketPath: path, timeout: 3) }
        var first: BoardState?
        var events: [BoardEvent] = []
        link.onConnect = { _, state, _ in first = state }
        link.onEvent = { events.append($0) }
        try await waitUntil { await link.start() }
        let board = try #require(link.client)
        #expect(board.version == CoreProtocol.version)
        #expect(first?.cards.isEmpty == true && first?.postIts?.isEmpty == true)

        let runner = AgentRecord(id: UUID(), worktree: home.path, providerID: AgentRecord.runnerProviderID, name: "web",
                                 frame: CGRect(x: 10, y: 20, width: 600, height: 340),
                                 runner: RunnerSpec(command: "printf 'serving %s\\n' rust; sleep 60", directory: home.path, owner: nil))
        link.send(.addCard(runner))
        let session = AgentSession(cols: 80, rows: 24)
        session.host(on: board, id: runner.id)
        link.send(.open(id: runner.id, cols: 80, rows: 24, start: true))
        func screen() -> String { session.withTerminal { $0.screenText().joined(separator: "\n") } }
        try await waitUntil { screen().contains("serving rust") }
        #expect(screen().contains("serving rust"), "\(screen())")
        #expect(session.state == .running)
        #expect(session.processID != nil)

        let note = PostItRecord(id: UUID(), worktree: home.path, name: "Plan", frame: CGRect(x: 700, y: 20, width: 340, height: 320))
        let line = Connection(a: runner.id, b: note.id)
        link.send(.addPostIt(note))
        link.send(.connect(line))
        link.send(.writePostIt(id: note.id, text: "- Ship on Friday"))

        // A second board gets what the first one sent, and hears what it sends next.
        var state: BoardState?
        var second: CoreClient?
        try await waitUntil {
            second?.disconnect()
            second = try? CoreClient.open(socketPath: path, timeout: 3).get()
            state = second?.serviceState.flatMap(BoardState.init)
            return state?.postIts?.first?.text == "- Ship on Friday" && state?.connections.isEmpty == false
        }
        #expect(state?.cards == [runner])
        #expect(state?.connections == [line])
        #expect(state?.postIts?.map(\.id) == [note.id])
        #expect(state?.postIts?.first.map { [$0.name, $0.worktree, $0.editorName] } == ["Plan", home.path, ""])
        #expect(state?.postIts?.first?.frame == note.frame)
        #expect(state?.postIts?.first?.edited != nil)
        #expect(state?.runners.starts[runner.id] != nil)
        #expect(state?.attention == [] && state?.images == [])
        #expect(second?.known[runner.id]?.processID == session.processID)

        second?.send(.removePostIt(note.id))
        try await waitUntil { events.contains { if case .postItRemoved(note.id) = $0 { true } else { false } } }
        #expect(events.contains { if case .postItRemoved(note.id) = $0 { true } else { false } })
        #expect(events.contains { if case .connections(let lines) = $0 { lines.isEmpty } else { false } })
        // Its own changes don't come back to the board that made them.
        #expect(!events.contains { if case .cardAdded = $0 { true } else { false } })

        link.send(.stopRunner(runner.id))
        try await waitUntil { session.processID == nil }
        #expect(session.processID == nil)
        second?.disconnect()
        board.shutdown()
        try await waitUntil { !core.isRunning }
        #expect(!core.isRunning)
    }
}
