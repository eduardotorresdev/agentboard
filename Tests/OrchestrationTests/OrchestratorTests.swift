import AgentRuntime
import CryptoKit
import Connections
import Foundation
import SQLite3
import Testing
@testable import Orchestration

func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    // Generous: conditions wait on the main queue, which slows down a lot when test runs share the machine.
    let deadline = Date().addingTimeInterval(30)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// An agent that prints `ready`, then echoes every line it reads as `got <line>`.
struct EchoAgent: AgentProvider {
    let id = "echo"
    let title = "Echo"
    let executable = "sh"
    func arguments(session: UUID, tools: ToolServerLink?) -> [String] {
        ["-c", "printf 'ready\\n'; while IFS= read -r line; do printf 'got %s\\n' \"$line\"; done"]
    }
    func environment(_ base: [String: String]) -> [String: String] { base }
}

/// A core with its own socket, data folder and tool server, and the way an agent calls its tools.
@MainActor
final class Core {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
    let path: String
    let server: CoreServer
    let orchestrator: Orchestrator

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
        server = CoreServer(socketPath: path, idleTimeout: 60, queue: .main)
        orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
        server.service = orchestrator
        try server.start()
    }

    func screen(_ id: UUID) -> String {
        orchestrator.session(id)?.withTerminal { $0.screenText().joined(separator: "\n") } ?? ""
    }

    func card(named name: String) -> AgentRecord? { orchestrator.cards.first { $0.name == name } }

    func stop() {
        for card in orchestrator.cards { server.closeSession(card.id, grace: 0.5) }
        server.stop()
        unlink(path)
    }
}

/// Calls `tool` as the agent `caller` would, over the tool server; the result's text.
func call(_ tool: String, _ arguments: [String: Any] = [:], as caller: UUID, on core: Core) async throws -> (text: String, isError: Bool) {
    let (url, token) = await MainActor.run { (core.orchestrator.toolsEndpoint, core.orchestrator.toolToken(for: caller)) }
    var request = URLRequest(url: try #require(url))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(answer["result"] as? [String: Any])
    let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    return (text, result["isError"] as? Bool ?? false)
}

/// What an agent's context hook gets back before `event`: the added context, or nil.
func context(_ event: String, as caller: UUID, on core: Core) async throws -> String? {
    let (url, token) = await MainActor.run { (core.orchestrator.toolsEndpoint, core.orchestrator.toolToken(for: caller)) }
    var request = URLRequest(url: try #require(url).appendingPathComponent("context"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": "x"])
    let (data, _) = try await URLSession.shared.data(for: request)
    let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (answer["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String
}

func board(_ core: Core) async throws -> CoreClient {
    let path = await MainActor.run { core.path }
    return try #require(CoreClient.connect(socketPath: path, timeout: 3))
}

func agent(_ name: String, in folder: URL) -> AgentRecord {
    AgentRecord(id: UUID(), worktree: folder.path, providerID: "echo", name: name, frame: CGRect(x: 0, y: 0, width: 640, height: 420))
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Events a board received, decoded.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [BoardEvent] = []
    var events: [BoardEvent] { lock.withLock { _events } }
    func add(_ event: BoardEvent) { lock.withLock { _events.append(event) } }
}

@Suite(.serialized)
struct OrchestratorTests {
    /// Scenario 3 of GOAL.md: with no board running, agents keep messaging each other, starting
    /// runners and reading their logs; the next board finds what they did.
    @Test func toolsWorkWithNoBoard() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        let first = try await board(core)
        first.send(.addCard(a))
        first.send(.addCard(b))
        first.send(.connect(Connection(a: a.id, b: b.id)))
        first.send(.open(id: a.id, cols: 80, rows: 24, start: true))
        first.send(.open(id: b.id, cols: 80, rows: 24, start: true))
        try await waitUntil { core.screen(a.id).contains("ready") && core.screen(b.id).contains("ready") }
        first.disconnect()
        try await Task.sleep(for: .milliseconds(100))

        let peers = try await call("list_peers", as: a.id, on: core)
        #expect(peers.text.contains("Bob"))
        let sent = try await call("send_message", ["to": "Bob", "message": "hello there"], as: a.id, on: core)
        #expect(!sent.isError, "\(sent.text)")
        // Unbracketed (the echo agent), the message is pasted on one line: header, then text.
        try await waitUntil { core.screen(b.id).contains("hello there") }
        #expect(await core.screen(b.id).contains("got Message from “Ada”"))

        let started = try await call("runner_start", ["command": "printf 'serving\\n'; sleep 30", "name": "web", "wait": false],
                                     as: a.id, on: core)
        #expect(!started.isError, "\(started.text)")
        let runner = try #require(await core.card(named: "web"))
        try await waitUntil { core.screen(runner.id).contains("serving") }
        let logs = try await call("runner_logs", as: a.id, on: core)
        #expect(logs.text.contains("serving"), "\(logs.text)")

        // The next board gets the runner the agent started, its line, and its session.
        let next = try await board(core)
        let state = try #require(next.serviceState.flatMap(BoardState.init))
        #expect(state.cards.map(\.id).contains(runner.id))
        #expect(state.connections.contains { $0.joins(a.id, runner.id) })
        #expect(next.known[runner.id]?.processID != nil)
        next.disconnect()
    }

    /// Agents add agents and plain terminals next to them, and close what is connected to them.
    @Test func agentsAddAndCloseCards() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let client = try await board(core)
        client.send(.addCard(a))
        try await waitUntil { core.orchestrator.record(a.id) != nil }

        let started = try await call("agent_start", ["agent": a.providerID, "name": "Helper"], as: a.id, on: core)
        #expect(!started.isError && started.text.hasPrefix("Started agent “Helper”, connected to you."), "\(started.text)")
        let helper = try #require(await core.card(named: "Helper"))
        #expect(helper.runner == nil && helper.frame.minX > a.frame.maxX)
        try await waitUntil { core.screen(helper.id).contains("ready") }
        #expect(try await call("agent_start", ["agent": "nope"], as: a.id, on: core).isError)

        let opened = try await call("terminal_open", as: a.id, on: core)
        #expect(opened.text == "Opened terminal “terminal”, connected to you.")
        #expect(await core.card(named: "terminal")?.runner?.isShell == true)

        let closed = try await call("agent_close", as: a.id, on: core)
        #expect(closed.text == "Removed “Helper” (agent).")
        #expect(await core.card(named: "Helper") == nil)

        _ = try await call("postit_create", ["name": "Plan"], as: a.id, on: core)
        let removed = try await call("postit_remove", as: a.id, on: core)
        #expect(removed.text == "Removed “Plan” (postit).")
        #expect(await core.orchestrator.postIts.isEmpty)
        _ = try await call("runner_close", as: a.id, on: core)
        client.disconnect()
    }

    /// A board mirrors what agents change through the core while it runs.
    @Test func boardHearsWhatAgentsDo() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let client = try await board(core)
        let inbox = Inbox()
        client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        client.send(.addCard(a))
        client.send(.open(id: a.id, cols: 80, rows: 24, start: true))
        try await waitUntil { core.screen(a.id).contains("ready") }

        _ = try await call("runner_start", ["command": "sleep 30", "name": "worker", "wait": false], as: a.id, on: core)
        try await waitUntil { inbox.events.contains { if case .connections(let list) = $0 { !list.isEmpty } else { false } } }
        let added = inbox.events.compactMap { event -> AgentRecord? in if case .cardAdded(let record) = event { record } else { nil } }
        #expect(added.map(\.name) == ["worker"])
        let lines = inbox.events.compactMap { event -> [Connection]? in if case .connections(let list) = event { list } else { nil } }.last ?? []
        #expect(lines.contains { $0.joins(a.id, added.first?.id ?? UUID()) })
        // Its own changes don't come back to it.
        #expect(!added.contains { $0.id == a.id })

        _ = try await call("runner_close", as: a.id, on: core)
        try await waitUntil { inbox.events.contains { if case .cardRemoved = $0 { true } else { false } } }
        #expect(await core.card(named: "worker") == nil)
        client.disconnect()
    }

    /// A remote board learns how to reach a card's stream from the core, which only boards
    /// reach (a remote one through a channel its host trusted): the answer goes to the asker
    /// alone, and says none while no board serves streams.
    @Test func boardsAskTheCoreForAStreamTicket() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let mac = try await board(core), phone = try await board(core)
        let macInbox = Inbox(), phoneInbox = Inbox()
        mac.onService { data in if let event = BoardEvent(data) { macInbox.add(event) } }
        phone.onService { data in if let event = BoardEvent(data) { phoneInbox.add(event) } }
        let card = UUID()
        func tickets(_ inbox: Inbox) -> [(Int?, String?)] {
            inbox.events.compactMap { event -> (Int?, String?)? in
                if case .streamTicket(let asked, let port, let token) = event, asked == card { (port, token) } else { nil }
            }
        }
        phone.send(.streamTicket(card: card))
        try await waitUntil { tickets(phoneInbox).count == 1 }
        #expect(tickets(phoneInbox).first.map { $0.0 == nil && $0.1 == nil } == true)

        mac.send(.servesStreams(port: 52731, token: "secret"))
        phone.send(.streamTicket(card: card))
        try await waitUntil { tickets(phoneInbox).count == 2 }
        #expect(tickets(phoneInbox).last.map { $0.0 == 52731 && $0.1 == "secret" } == true)
        #expect(tickets(macInbox).isEmpty)

        mac.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        phone.send(.streamTicket(card: card))
        try await waitUntil { tickets(phoneInbox).count == 3 }
        #expect(tickets(phoneInbox).last.map { $0.0 == nil && $0.1 == nil } == true)
        phone.disconnect()
    }

    /// The elements a Mac board runs reach the other boards (a phone can't run them), in the
    /// event and in a later board's welcome, but never go back to the board that said them.
    @Test func elementsReachTheOtherBoardsOnly() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let mac = try await board(core), phone = try await board(core)
        let macInbox = Inbox(), phoneInbox = Inbox()
        mac.onService { data in if let event = BoardEvent(data) { macInbox.add(event) } }
        phone.onService { data in if let event = BoardEvent(data) { phoneInbox.add(event) } }
        let browser = ElementInfo(id: UUID(), name: "Desktop", kind: "browser", detail: nil, worktree: folder.path,
                                  frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        func listed(_ inbox: Inbox) -> [[UUID]] {
            inbox.events.compactMap { event -> [UUID]? in if case .elements(let list) = event { list.map(\.id) } else { nil } }
        }
        mac.send(.elements([browser]))
        try await waitUntil { listed(phoneInbox) == [[browser.id]] }
        // Anything the Mac hears after its own list was sent says it wasn't echoed back.
        mac.send(.streamTicket(card: browser.id))
        try await waitUntil { macInbox.events.contains { if case .streamTicket = $0 { true } else { false } } }
        #expect(listed(macInbox).isEmpty)
        let late = try await board(core)
        let welcome = try #require(late.serviceState.flatMap(BoardState.init))
        #expect(welcome.elements?.map(\.id) == [browser.id])
        late.disconnect()
        mac.disconnect()
        phone.disconnect()
    }

    /// A browser tool goes to a board that runs browsers (it said which elements it has), never
    /// to a phone, which can't, even when the phone connected first.
    @Test func boardOnlyToolsGoToABoardThatRunsThem() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let phone = try await board(core)
        let mac = try await board(core)
        let macInbox = Inbox(), phoneInbox = Inbox()
        mac.onService { data in if let event = BoardEvent(data) { macInbox.add(event) } }
        phone.onService { data in if let event = BoardEvent(data) { phoneInbox.add(event) } }
        let a = agent("Ada", in: folder)
        mac.send(.addCard(a))
        mac.send(.elements([]))
        try await Task.sleep(for: .milliseconds(200))
        let asked = Task { try await call("browser_open", ["url": "about:blank"], as: a.id, on: core) }
        func calls(_ inbox: Inbox) -> [UUID] {
            inbox.events.compactMap { event -> UUID? in if case .toolCall(let call, _, _, _) = event { call } else { nil } }
        }
        try await waitUntil { !calls(macInbox).isEmpty }
        mac.send(.toolResult(call: calls(macInbox)[0], result: WireToolResult(.error("answered by the Mac"))))
        let answer = try await asked.value
        #expect(answer.text.contains("answered by the Mac"))
        #expect(calls(phoneInbox).isEmpty)
        mac.disconnect()
        phone.disconnect()
    }

    /// An agent's notifications queue it for the developer: its hooks raise and clear the
    /// request, a later signal keeps its place, and dismissing or removing it takes it out.
    @Test func agentsAskForTheDeveloper() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bea", in: folder)
        let client = try await board(core)
        let inbox = Inbox()
        client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        for card in [a, b] {
            client.send(.addCard(card))
            client.send(.open(id: card.id, cols: 80, rows: 24, start: true))
        }
        try await waitUntil { core.screen(a.id).contains("ready") && core.screen(b.id).contains("ready") }
        func queue() -> [AttentionRequest] {
            inbox.events.compactMap { event -> [AttentionRequest]? in if case .attention(let list) = event { list } else { nil } }.last ?? []
        }
        func notify(_ id: UUID, _ text: String) async {
            await MainActor.run { core.server.session(id)?.send(Array("\u{1B}]9;\(text)\u{07}\r".utf8)) }
        }
        func hook(_ json: String) -> String { AgentHook.prefix + Data(json.utf8).base64EncodedString() }

        await notify(a.id, hook(#"{"hook_event_name":"Stop"}"#))
        try await waitUntil { queue().map(\.reason) == [.turnEnded] }
        await notify(b.id, hook(#"{"hook_event_name":"Notification","message":"Need a hand","notification_type":"elicitation_dialog"}"#))
        try await waitUntil { queue().count == 2 }
        // Ada says more: she keeps her place, and idle reminders change nothing.
        await notify(a.id, hook(#"{"hook_event_name":"Notification","message":"Use \"Bash\"? é","notification_type":"permission_prompt"}"#))
        try await waitUntil { queue().first?.reason == .said(#"Use "Bash"? é"#) }
        // Neither idle reminders, nor what only informs, nor the program's own notifications count.
        await notify(a.id, hook(#"{"hook_event_name":"Notification","message":"idle","notification_type":"idle_prompt"}"#))
        await notify(a.id, hook(#"{"hook_event_name":"Notification","message":"signed in","notification_type":"auth_success"}"#))
        await notify(a.id, "Claude is waiting for your input")
        await notify(b.id, hook(#"{"hook_event_name":"Stop"}"#))
        try await waitUntil { queue().last?.reason == .turnEnded }
        #expect(queue().map(\.id) == [a.id, b.id])
        #expect(queue().first?.reason == .said(#"Use "Bash"? é"#))
        // Answering Ada in her terminal clears her; dismissing and removing clear the rest.
        await notify(a.id, hook(#"{"hook_event_name":"UserPromptSubmit"}"#))
        try await waitUntil { queue().map(\.id) == [b.id] }
        client.send(.dismissAttention(b.id))
        try await waitUntil { queue().isEmpty }
        await notify(b.id, hook(#"{"hook_event_name":"Stop"}"#))
        try await waitUntil { queue().count == 1 }
        client.send(.removeCard(b.id))
        try await waitUntil { queue().isEmpty }
        client.disconnect()
    }

    /// A waiting agent's request carries what it asks: its last words when its turn ends, the
    /// question it asked, or the call waiting for permission, read from its conversation.
    @Test @MainActor func requestsSayWhatTheAgentAsks() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("conversation.jsonl")
        func write(_ lines: [[String: Any]]) throws {
            let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
            try Data(("cut off line\n" + text + "\n").utf8).write(to: transcript)
        }
        func assistant(_ block: [String: Any], sidechain: Bool = false) -> [String: Any] {
            ["type": "assistant", "isSidechain": sidechain, "message": ["role": "assistant", "content": [block]]]
        }
        let prompt: [String: Any] = ["type": "user", "message": ["role": "user", "content": "Ship it"]]
        let toolResult: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]]
        let meta: [String: Any] = ["type": "user", "isMeta": true, "message": ["role": "user", "content": "reminder"]]

        try write([prompt, assistant(["type": "text", "text": "Earlier"]), toolResult,
                   assistant(["type": "thinking", "thinking": "hmm"]), assistant(["type": "text", "text": "  Merge to main?  "]),
                   assistant(["type": "text", "text": "a subagent"], sidechain: true), meta])
        #expect(TranscriptContext.lastRequest(in: transcript) == "Merge to main?")

        try write([prompt, assistant(["type": "tool_use", "name": "AskUserQuestion", "input": ["questions": [
            ["question": "Which layout?", "options": [["label": "Wide"], ["label": "Tall"]]],
        ]]])])
        #expect(TranscriptContext.lastRequest(in: transcript) == "Which layout?\n- Wide\n- Tall")

        try write([prompt, assistant(["type": "text", "text": "Cleaning up."]),
                   assistant(["type": "tool_use", "name": "Bash", "input": ["command": "rm -rf build"]])])
        #expect(TranscriptContext.lastRequest(in: transcript) == "**Bash**\n`rm -rf build`")

        // A turn that said nothing yet has nothing to show; a missing file neither.
        try write([assistant(["type": "text", "text": "Old turn"]), prompt])
        #expect(TranscriptContext.lastRequest(in: transcript) == nil)
        #expect(TranscriptContext.lastRequest(in: folder.appendingPathComponent("missing.jsonl")) == nil)

        // Through the hooks: the end of a turn queues the agent with its last words.
        let orchestrator = Orchestrator(server: CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main),
                                        dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
        let card = agent("Ada", in: folder)
        orchestrator.insert(card)
        try write([prompt, assistant(["type": "text", "text": "Done. Merge to main?"])])
        let stop = #"{"hook_event_name":"Stop","transcript_path":"\#(transcript.path)"}"#
        orchestrator.sessionNotified(card.id, [AgentHook.prefix + Data(stop.utf8).base64EncodedString()])
        #expect(orchestrator.attention.first?.context == "Done. Merge to main?")
        // Claude Code versions that send the last message directly are taken at their word.
        let direct = #"{"hook_event_name":"Stop","last_assistant_message":"Said directly"}"#
        orchestrator.sessionNotified(card.id, [AgentHook.prefix + Data(direct.utf8).base64EncodedString()])
        #expect(orchestrator.attention.first?.context == "Said directly")
    }

    /// A saved board that can't be read isn't an empty one: its lines are never replaced.
    @MainActor @Test func anUnreadableBoardKeepsItsLines() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ablines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("agentboard.sqlite")
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        do {
            let database = try CardDatabase(url: url)
            try database.saveAgent(a)
            try database.saveAgent(b)
            try database.saveConnections([Connection(a: a.id, b: b.id)])
        }
        // A post-its table that can't be read, as a damaged or newer file would have.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "DROP TABLE postits; CREATE TABLE postits (x)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let server = CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main)
        let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
        let c = agent("Cy", in: folder)
        orchestrator.insert(c)
        _ = orchestrator.bus.connect(a.id, c.id)
        #expect(try CardDatabase(url: url).connections().map(\.b) == [b.id])
    }

    /// Ending a turn isn't waiting on the user; an agent whose program ended leaves the queue.
    @MainActor @Test func attentionNeedsTheUserOnlyWhileTheAgentRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abattention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main)
        let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
        let card = agent("Ada", in: folder)
        orchestrator.insert(card)
        #expect(!AttentionRequest(id: card.id, reason: .turnEnded).needsUser)
        #expect(AttentionRequest(id: card.id, reason: .waiting).needsUser)
        #expect(AttentionRequest(id: card.id, reason: .said("Allow rm?")).needsUser)
        orchestrator.requestAttention(card.id, .waiting)
        server.onSessionStatus?(card.id, SessionStatus(state: .running, processID: 1, exitCode: nil))
        #expect(orchestrator.attention.map(\.id) == [card.id])
        server.onSessionStatus?(card.id, SessionStatus(state: .exited, processID: nil, exitCode: 1))
        #expect(orchestrator.attention.isEmpty)
    }

    /// An agent's questions (AskUserQuestion) reach the queue through its hook, which waits:
    /// answered on the board, the hook gives Claude Code the answers; sent to the terminal or
    /// dismissed, it gives nothing, and Claude Code asks there.
    @Test func questionsAreAnsweredOnTheBoard() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let client = try await board(core)
        let inbox = Inbox()
        client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        client.send(.addCard(a))
        try await waitUntil { core.card(named: "Ada") != nil }
        func queue() -> [AttentionRequest] {
            inbox.events.compactMap { event -> [AttentionRequest]? in if case .attention(let list) = event { list } else { nil } }.last ?? []
        }
        let input: [String: Any] = ["questions": [
            ["question": "Which layout?", "header": "Layout", "multiSelect": false,
             "options": [["label": "Wide", "description": "One row"], ["label": "Tall"]]],
            ["question": "Which pets?", "header": "Pets", "multiSelect": true, "options": [["label": "Cat"], ["label": "Dog"]]],
        ]]
        /// Posts the hook's input as Claude Code would, and waits for the hook's output.
        func ask() -> Task<[String: Any], Error> {
            Task {
                let (url, token) = await MainActor.run { (core.orchestrator.toolsEndpoint, core.orchestrator.toolToken(for: a.id)) }
                var request = URLRequest(url: try #require(url).appendingPathComponent("question"))
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": input,
                ])
                let (data, _) = try await URLSession.shared.data(for: request)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            }
        }

        let answered = ask()
        try await waitUntil { queue().first?.questions?.count == 2 }
        let questions = try #require(queue().first?.questions)
        #expect(questions.map(\.header) == ["Layout", "Pets"])
        #expect(questions[0].options == [.init(label: "Wide", description: "One row"), .init(label: "Tall")])
        #expect(questions.map(\.multiSelect) == [false, true])
        client.send(.answerQuestions(id: a.id, answers: ["Which layout?": "Tall", "Which pets?": "Cat, a hamster"]))
        let output = try await answered.value["hookSpecificOutput"] as? [String: Any]
        #expect(output?["permissionDecision"] as? String == "allow")
        let updated = output?["updatedInput"] as? [String: Any]
        #expect(updated?["answers"] as? [String: String] == ["Which layout?": "Tall", "Which pets?": "Cat, a hamster"])
        #expect((updated?["questions"] as? [Any])?.count == 2)
        try await waitUntil { queue().isEmpty }
        #expect(queue().isEmpty)

        // To the terminal: the hook lets go, and the agent stays queued, now without the form.
        let toTerminal = ask()
        try await waitUntil { queue().first?.questions != nil }
        client.send(.answerQuestions(id: a.id, answers: nil))
        #expect(try await toTerminal.value.isEmpty)
        try await waitUntil { queue().first?.questions == nil }
        #expect(queue().map(\.id) == [a.id])

        // Dismissed: the same.
        client.send(.dismissAttention(a.id))
        try await waitUntil { queue().isEmpty }
        let dismissed = ask()
        try await waitUntil { queue().first?.questions != nil }
        client.send(.dismissAttention(a.id))
        #expect(try await dismissed.value.isEmpty)
        client.disconnect()
        await MainActor.run { core.stop() }
    }

    /// With no board that answers questions the hook lets go at once. Once the last one leaves,
    /// held questions wait the grace for one to come back, then go to the agent's terminal.
    @Test func heldQuestionsWaitAGracePeriodForABoard() async throws {
        let core = try await MainActor.run { try Core() }
        await MainActor.run { core.orchestrator.questionGrace = .milliseconds(600) }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        func ask() -> Task<[String: Any], Error> {
            Task {
                let (url, token) = await MainActor.run { (core.orchestrator.toolsEndpoint, core.orchestrator.toolToken(for: a.id)) }
                var request = URLRequest(url: try #require(url).appendingPathComponent("question"))
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                    "tool_input": ["questions": [["question": "Which layout?", "header": "Layout", "multiSelect": false,
                                                  "options": [["label": "Wide"], ["label": "Tall"]]]]],
                ])
                let (data, _) = try await URLSession.shared.data(for: request)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            }
        }
        func held() async -> Bool { await MainActor.run { core.orchestrator.pendingQuestions[a.id] != nil } }

        let first = try await board(core)
        first.send(.addCard(a))
        try await waitUntil { core.card(named: "Ada") != nil }
        first.disconnect()
        try await waitUntil { core.orchestrator.boards.isEmpty }
        // Nobody to see them: straight to the terminal.
        #expect(try await ask().value.isEmpty)

        // Back within the grace: still held well past it, and answered from the board that came back.
        let second = try await board(core)
        let kept = ask()
        try await waitUntil { core.orchestrator.pendingQuestions[a.id] != nil }
        second.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        let third = try await board(core)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await held(), "released though a board came back")
        third.send(.answerQuestions(id: a.id, answers: ["Which layout?": "Tall"]))
        let output = try await kept.value["hookSpecificOutput"] as? [String: Any]
        #expect((output?["updatedInput"] as? [String: Any])?["answers"] as? [String: String] == ["Which layout?": "Tall"])

        // Not back: held through part of the grace, then to the terminal.
        let released = ask()
        try await waitUntil { core.orchestrator.pendingQuestions[a.id] != nil }
        third.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await held(), "released before the grace ended")
        #expect(try await released.value.isEmpty)
        #expect(await !held())
        await MainActor.run { core.stop() }
    }

    /// A newer core carries on the queue, without requests for cards it doesn't have.
    @Test @MainActor func theQueueSurvivesATakeOver() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unused = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
        let first = Orchestrator(server: CoreServer(socketPath: unused, queue: .main), dataFolder: folder, providers: [EchoAgent()],
                                 searchPath: "/usr/bin:/bin")
        let card = agent("Ada", in: folder)
        first.insert(card)
        first.sessionNotified(card.id, [AgentHook.prefix + Data(#"{"hook_event_name":"Stop"}"#.utf8).base64EncodedString()])
        first.requestAttention(UUID(), .waiting)
        #expect(first.attention.map(\.id) == [card.id])
        first.attention.append(AttentionRequest(id: UUID(), reason: .waiting))
        let (state, descriptors) = first.handOffState()
        descriptors.forEach { close($0) }
        first.handedOff()
        let next = Orchestrator(server: CoreServer(socketPath: unused, queue: .main), dataFolder: folder, providers: [EchoAgent()],
                                searchPath: "/usr/bin:/bin", inheriting: state)
        #expect(next.attention.map(\.id) == [card.id])
        #expect(next.attention.first?.reason == .turnEnded)
        next.handedOff()
    }

    /// Browser tools run on a board; with none open, the agent is told so.
    @Test func browserCallsGoToTheBoard() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let client = try await board(core)
        client.send(.addCard(a))
        client.send(.elements([]))  // a board that runs board tools says which elements it has
        try await waitUntil { core.card(named: "Ada") != nil }
        client.onService { data in
            guard case .toolCall(let call, let name, let arguments, let caller)? = BoardEvent(data) else { return }
            let platform = (try? JSONSerialization.jsonObject(with: arguments) as? [String: Any])?["platform"] as? String
            client.send(.toolResult(call: call, result: WireToolResult(.text("\(name) for \(caller == a.id ? "Ada" : "someone")\(platform.map { " on \($0)" } ?? "")"))))
        }
        let answered = try await call("browser_list", as: a.id, on: core)
        #expect(answered.text == "browser_list for Ada")
        // Simulators live in the board too.
        let tapped = try await call("simulator_tap", as: a.id, on: core)
        #expect(tapped.text == "simulator_tap for Ada")
        // The platform reaches the board as the agent gave it; whether it may run there is the board's call.
        let opened = try await call("simulator_open", ["platform": "android", "device": "tablet"], as: a.id, on: core)
        #expect(opened.text == "simulator_open for Ada on android")
        client.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        let alone = try await call("browser_list", as: a.id, on: core)
        #expect(alone.isError)
        #expect(alone.text.contains("board"))
        let noSimulator = try await call("simulator_list", as: a.id, on: core)
        #expect(noSimulator.isError)
        #expect(noSimulator.text == "Simulators run in the board, which isn't open right now. Ask the user to open it, then try again.")
    }

    /// Cards and lines are kept on disk by the core, and a new core loads them.
    @Test func cardsOutliveTheCore() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        let client = try await board(core)
        client.send(.addCard(a))
        client.send(.addCard(b))
        let line = Connection(a: a.id, b: b.id, aSide: .right, bSide: .left)
        client.send(.connect(line))
        var moved = b
        moved.frame.origin = CGPoint(x: 900, y: 40)
        client.send(.updateCard(moved))
        try await waitUntil { core.card(named: "Bob")?.frame.origin.x == 900 }
        client.disconnect()
        await MainActor.run { core.stop() }

        let reloaded = await MainActor.run { () -> ([AgentRecord], [Connection]) in
            let server = CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main)
            let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
            return (orchestrator.cards, orchestrator.bus.graph.connections)
        }
        #expect(reloaded.0.map(\.name) == ["Ada", "Bob"])
        #expect(reloaded.0.last?.frame.origin == CGPoint(x: 900, y: 40))
        #expect(reloaded.1 == [line])
    }

    /// Removing a card ends its program and drops its lines.
    @Test func removingACardEndsItsProgram() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        let client = try await board(core)
        client.send(.addCard(a))
        client.send(.addCard(b))
        client.send(.connect(Connection(a: a.id, b: b.id)))
        client.send(.open(id: a.id, cols: 80, rows: 24, start: true))
        try await waitUntil { core.orchestrator.session(a.id)?.processID != nil }
        let pid = try #require(await core.orchestrator.session(a.id)?.processID)
        client.send(.removeCard(a.id))
        try await waitUntil { kill(pid, 0) != 0 }
        #expect(kill(pid, 0) != 0)
        #expect(await core.orchestrator.bus.graph.connections.isEmpty)
        #expect(await core.card(named: "Ada") == nil)
        client.disconnect()
    }

    /// Several agents connected to one post-it read and write its markdown with the user; an
    /// agent not connected to it can't, the board hears each change, and it outlives the core.
    @Test func agentsSharePostIts() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder), c = agent("Cy", in: folder)
        let postIt = PostItRecord(id: UUID(), worktree: folder.path, name: "Post-it", frame: CGRect(origin: .zero, size: PostItRecord.size))
        let client = try await board(core)
        let inbox = Inbox()
        client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        for card in [a, b, c] { client.send(.addCard(card)) }
        client.send(.addPostIt(postIt))
        client.send(.connect(Connection(a: a.id, b: postIt.id)))
        client.send(.connect(Connection(a: b.id, b: postIt.id)))
        try await waitUntil { core.orchestrator.bus.graph.connections.count == 2 }

        let unconnected = try await call("postit_read", as: c.id, on: core)
        #expect(unconnected.isError)
        let peers = try await call("list_peers", as: a.id, on: core)
        #expect(peers.text.contains("connected: true, shared markdown note, empty"), "\(peers.text)")

        let written = try await call("postit_write", ["text": "# Export\n- CSV uses semicolons"], as: a.id, on: core)
        #expect(!written.isError, "\(written.text)")
        let appended = try await call("postit_write", ["text": "- Bob owns the tests", "append": true], as: b.id, on: core)
        #expect(!appended.isError, "\(appended.text)")
        let page = try await call("postit_read", as: a.id, on: core)
        #expect(page.text.contains("# Export\n- CSV uses semicolons\n- Bob owns the tests"), "\(page.text)")
        #expect(page.text.contains("last written by Bob"), "\(page.text)")
        // Events reach the board on the main queue: wait for it rather than assume it ran.
        try await waitUntil { inbox.events.contains { if case .postItUpdated(let record) = $0 { record.editorName == "Bob" } else { false } } }
        #expect(inbox.events.contains { if case .postItUpdated(let record) = $0 { record.editorName == "Bob" } else { false } })

        // An edit changes one passage and leaves what others wrote.
        let edited = try await call("postit_edit", ["old_text": "semicolons", "new_text": "commas"], as: a.id, on: core)
        #expect(!edited.isError, "\(edited.text)")
        let missing = try await call("postit_edit", ["old_text": "tabs", "new_text": "spaces"], as: a.id, on: core)
        #expect(missing.isError)
        #expect(await core.orchestrator.postIt(postIt.id)?.text == "# Export\n- CSV uses commas\n- Bob owns the tests")

        // What the user writes reaches the agents.
        client.send(.writePostIt(id: postIt.id, text: "Ship on Friday."))
        try await waitUntil { core.orchestrator.postIt(postIt.id)?.text == "Ship on Friday." }
        let fromUser = try await call("postit_read", as: b.id, on: core)
        #expect(fromUser.text.contains("last written by the user"), "\(fromUser.text)")
        #expect(fromUser.text.hasSuffix("Ship on Friday."))

        client.disconnect()
        await MainActor.run { core.stop() }
        let reloaded = await MainActor.run { () -> [PostItRecord] in
            let server = CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main)
            return Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin").postIts
        }
        #expect(reloaded.map(\.name) == ["Post-it"])
        #expect(reloaded.first?.text == "Ship on Friday.")
        #expect(reloaded.first?.editor == nil)
    }

    /// Connected post-its reach an agent's context through its hooks: all of them when its
    /// session starts, then only what changed, was connected or was disconnected.
    @Test func postItsReachContext() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        let plan = PostItRecord(id: UUID(), worktree: folder.path, name: "Plan", frame: CGRect(origin: .zero, size: PostItRecord.size))
        let rules = PostItRecord(id: UUID(), worktree: folder.path, name: "Rules", frame: CGRect(origin: .zero, size: PostItRecord.size))
        let client = try await board(core)
        for card in [a, b] { client.send(.addCard(card)) }
        client.send(.addPostIt(plan))
        client.send(.addPostIt(rules))
        client.send(.connect(Connection(a: a.id, b: plan.id)))
        client.send(.connect(Connection(a: b.id, b: plan.id)))
        try await waitUntil { core.orchestrator.bus.graph.connections.count == 2 }
        client.send(.writePostIt(id: plan.id, text: "- Ship on Friday"))
        try await waitUntil { core.orchestrator.postIt(plan.id)?.text == "- Ship on Friday" }

        let start = try await context("SessionStart", as: a.id, on: core)
        #expect(start?.contains("<postit name=\"Plan\">") == true, "\(start ?? "nil")")
        #expect(start?.contains("- Ship on Friday") == true)
        #expect(try await context("UserPromptSubmit", as: a.id, on: core) == nil)

        // Another agent's change reaches Ada; Ada's own change doesn't come back to her.
        _ = try await call("postit_write", ["text": "- Ship on Monday"], as: b.id, on: core)
        let changed = try await context("PostToolUse", as: a.id, on: core)
        #expect(changed?.contains("- Ship on Monday") == true, "\(changed ?? "nil")")
        _ = try await call("postit_write", ["text": "- Ship today", "append": true], as: a.id, on: core)
        #expect(try await context("PostToolUse", as: a.id, on: core) == nil)

        // Connecting and disconnecting are context too.
        client.send(.connect(Connection(a: a.id, b: rules.id)))
        try await waitUntil { core.orchestrator.bus.graph.connections.count == 3 }
        let connected = try await context("UserPromptSubmit", as: a.id, on: core)
        #expect(connected?.contains("<postit name=\"Rules\">") == true, "\(connected ?? "nil")")
        #expect(connected?.contains("Plan") == false)
        let line = try #require(await core.orchestrator.bus.graph.connections.first { Set([$0.a, $0.b]) == [a.id, rules.id] })
        client.send(.disconnect(line.id))
        try await waitUntil { core.orchestrator.bus.graph.connections.count == 2 }
        let disconnected = try await context("UserPromptSubmit", as: a.id, on: core)
        #expect(disconnected?.contains("“Rules” is no longer connected") == true, "\(disconnected ?? "nil")")
        client.disconnect()
    }

    /// The notes blocks of the build before come back as post-its: same id, so their lines hold,
    /// and their notes as a markdown list.
    /// An agent adds a post-it of its own: next to its card, in its organization, connected to it.
    @Test func agentsAddPostIts() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        var a = agent("Ada", in: folder)
        a.organization = UUID()
        let client = try await board(core)
        client.send(.addCard(a))
        try await waitUntil { core.orchestrator.record(a.id) != nil }

        let created = try await call("postit_create", ["name": "Plan", "text": "- Ship"], as: a.id, on: core)
        #expect(!created.isError, "\(created.text)")
        let record = try #require(await core.orchestrator.postIts.first)
        #expect(record.name == "Plan")
        #expect(record.organization == a.organization)
        #expect(record.frame.minX > a.frame.maxX)
        let page = try await call("postit_read", as: a.id, on: core)
        #expect(page.text.contains("- Ship"), "\(page.text)")
        client.disconnect()
    }

    @Test func notesBlocksBecomePostIts() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID(), agentID = UUID()
        let entries = #"[{"kind":"status","text":"Working"},{"kind":"note","text":"Use commas"},{"kind":"note","text":"Ship\nFriday"}]"#
        var db: OpaquePointer?
        try #require(sqlite3_open(folder.appendingPathComponent("agentboard.sqlite").path, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE notes (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, name TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL, entries TEXT NOT NULL);
            INSERT INTO notes VALUES ('\(id.uuidString)', '\(folder.path)', 'Notes', 10, 20, 380, 440, '\(entries)');
            CREATE TABLE connections (id TEXT PRIMARY KEY, a TEXT NOT NULL, b TEXT NOT NULL);
            CREATE TABLE agents (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, kind TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL);
            INSERT INTO agents VALUES ('\(agentID.uuidString)', '\(folder.path)', 'echo', 0, 0, 640, 420);
            INSERT INTO connections VALUES ('\(UUID().uuidString)', '\(agentID.uuidString)', '\(id.uuidString)');
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let (postIts, connections) = await MainActor.run { () -> ([PostItRecord], [Connection]) in
            let server = CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main)
            let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
            return (orchestrator.postIts, orchestrator.bus.graph.connections)
        }
        #expect(postIts.map(\.id) == [id])
        #expect(postIts.first?.frame == CGRect(x: 10, y: 20, width: 380, height: 440))
        #expect(postIts.first?.text == "- Use commas\n- Ship\n  Friday")
        #expect(connections.count == 1)
    }
}

/// The real core binary, in a data folder of its own: with the board gone, a runner's logs still
/// answer over the tool server, as an agent would ask for them.
@Test func theCoreBinaryServesToolsAlone() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the AgentBoardCore product first")
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abhome-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(path) }
    let board = try #require(CoreClient.connect(socketPath: path, launching: binary, environment: ["AGENTBOARD_HOME": home.path], timeout: 10))
    defer { CoreClient.connect(socketPath: path, timeout: 1)?.shutdown() }
    func runner(_ name: String, _ command: String) -> AgentRecord {
        AgentRecord(id: UUID(), worktree: home.path, providerID: AgentRecord.runnerProviderID, name: name,
                    frame: CGRect(x: 0, y: 0, width: 600, height: 340), runner: RunnerSpec(command: command, directory: home.path, owner: nil))
    }
    let watcher = runner("watcher", "sleep 60"), web = runner("web", "printf 'serving\\n'; sleep 60")
    // The core runs with its data folder and socket set; its programs mustn't (a `./run` in
    // one would reach this core).
    let env = runner("env", "printf 'settings %s\\n' \"$(env | grep -c '^AGENTBOARD_')\"; sleep 60")
    for card in [watcher, web, env] { board.send(.addCard(card)) }
    board.send(.connect(Connection(a: watcher.id, b: web.id)))
    board.send(.connect(Connection(a: watcher.id, b: env.id)))
    for card in [watcher, web, env] { board.send(.open(id: card.id, cols: 80, rows: 24, start: true)) }
    try await Task.sleep(for: .milliseconds(300))
    board.disconnect()

    // What an agent gets at launch: the server's port, and a token derived from the core's key.
    // Generous: the core asks the login shell for PATH, and the runner runs in one too.
    let deadline = Date().addingTimeInterval(60)
    var logs = ""
    while !logs.contains("serving"), Date() < deadline {
        try await Task.sleep(for: .milliseconds(200))
        logs = await binaryCall("runner_logs", ["runner": "web"], as: watcher.id, home: home) ?? ""
    }
    #expect(logs.contains("serving"), "\(logs)")
    var settings = ""
    while !settings.contains("settings "), Date() < deadline {
        settings = await binaryCall("runner_logs", ["runner": "env"], as: watcher.id, home: home) ?? ""
        if !settings.contains("settings ") { try await Task.sleep(for: .milliseconds(200)) }
    }
    #expect(settings.contains("settings 0"), "\(settings)")

    let last = try #require(CoreClient.connect(socketPath: path, timeout: 3))
    #expect(BoardState(last.serviceState ?? Data())?.cards.count == 3)
    last.shutdown()
}

/// The core this package builds.
private let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/AgentBoardCore")

/// Calls `tool` as the agent `caller` launched by the core binary serving `home` would: on the
/// port it wrote, with a token derived from its key. Nil when it doesn't answer.
private func binaryCall(_ tool: String, _ arguments: [String: Any] = [:], as caller: UUID, home: URL) async -> String? {
    guard let port = (try? String(contentsOf: home.appendingPathComponent("tools.port"), encoding: .utf8)).flatMap({ Int($0) }),
          let key = try? Data(contentsOf: home.appendingPathComponent("tools.key")) else { return nil }
    let token = HMAC<SHA256>.authenticationCode(for: Data(caller.uuidString.utf8), using: SymmetricKey(data: key))
        .map { String(format: "%02x", $0) }.joined()
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
    ])
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = answer["result"] as? [String: Any] else { return nil }
    return (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
}

/// Scenario 4 of GOAL.md: a newer core takes over the running one's programs without ending
/// them. The runner counts without pause; its output must come out whole, every number once,
/// with the same process, and a board must see the same screen afterwards.
@Test func aNewerCoreTakesOverWithoutEndingPrograms() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the AgentBoardCore product first")
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abhome-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(path) }
    let environment = ["AGENTBOARD_HOME": home.path]
    let first = try #require(CoreClient.connect(socketPath: path, launching: binary, environment: environment, timeout: 10))
    defer { CoreClient.connect(socketPath: path, timeout: 1)?.shutdown() }
    let counter = AgentRecord(id: UUID(), worktree: home.path, providerID: AgentRecord.runnerProviderID, name: "counter",
                              frame: CGRect(x: 0, y: 0, width: 600, height: 340),
                              runner: RunnerSpec(command: "i=0; while [ $i -lt 100000 ]; do i=$((i+1)); echo tick $i; sleep 0.01; done",
                                                 directory: home.path, owner: nil))
    // What reads the counter's logs, as an agent connected to it would.
    let reader = AgentRecord(id: UUID(), worktree: home.path, providerID: AgentRecord.runnerProviderID, name: "reader",
                             frame: CGRect(x: 0, y: 400, width: 600, height: 340),
                             runner: RunnerSpec(command: "sleep 600", directory: home.path, owner: nil))
    first.send(.addCard(counter))
    first.send(.addCard(reader))
    first.send(.connect(Connection(a: reader.id, b: counter.id)))
    first.send(.open(id: counter.id, cols: 80, rows: 24, start: true))

    func ticks() async -> [Int] {
        let logs = await binaryCall("runner_logs", ["lines": 1000], as: reader.id, home: home) ?? ""
        return logs.split(separator: "\n").compactMap { $0.hasPrefix("tick ") ? Int($0.dropFirst(5)) : nil }
    }
    var deadline = Date().addingTimeInterval(60)
    while (await ticks().last ?? 0) < 20, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    // A board mirrors the counter throughout.
    let mirror = AgentSession(cols: 80, rows: 24)
    mirror.host(on: first, id: counter.id)
    mirror.attach()
    deadline = Date().addingTimeInterval(5)
    while mirror.processID == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let pid = try #require(mirror.processID)

    // An agent keeps calling its tools throughout. Stopped by a flag: cancelling the task would
    // cancel the call in flight.
    let done = Flag()
    let calling = Task {
        var answered = 0, failed = 0
        while !done.isSet {
            if await binaryCall("runner_list", as: reader.id, home: home) != nil { answered += 1 } else { failed += 1 }
        }
        return (answered, failed)
    }
    let takeOver = Process()
    takeOver.executableURL = binary
    takeOver.arguments = ["--take-over"]
    takeOver.environment = ProcessInfo.processInfo.environment.merging(environment.merging(["AGENTBOARD_CORE_SOCKET": path]) { $1 }) { $1 }
    try takeOver.run()
    #expect(waitForExit(takeOver))
    #expect(takeOver.terminationStatus == 0)
    try await Task.sleep(for: .milliseconds(300))
    done.set()
    let (answered, failed) = await calling.value
    #expect(answered > 0 && failed == 0, "\(answered) calls answered, \(failed) failed")

    let second = try #require(CoreClient.connect(socketPath: path, timeout: 5))
    #expect(second.known[counter.id]?.processID == pid)
    #expect(kill(pid, 0) == 0)
    #expect(!first.isConnected)
    mirror.host(on: second, id: counter.id)
    mirror.attach()
    // It keeps counting, and every number shows up once, in order.
    let before = await ticks().last ?? 0
    deadline = Date().addingTimeInterval(30)
    var seen: [Int] = []
    while (seen.last ?? 0) < before + 50, Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
        seen = await ticks()
    }
    #expect((seen.last ?? 0) >= before + 50, "stopped at \(seen.last ?? 0)")
    let start = seen.first ?? 1
    #expect(seen == Array(start..<(start + seen.count)), "\(seen)")

    // Stopped, the board's mirror shows what a board attaching now gets.
    second.send(.stopRunner(counter.id))
    deadline = Date().addingTimeInterval(10)
    while mirror.processID != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(200))
    let fresh = AgentSession(cols: 80, rows: 24)
    let third = try #require(CoreClient.connect(socketPath: path, timeout: 5))
    fresh.host(on: third, id: counter.id)
    fresh.attach()
    try await Task.sleep(for: .milliseconds(300))
    let screen = { (session: AgentSession) in session.withTerminal { $0.screenText() } }
    #expect(screen(mirror) == screen(fresh))
    #expect(screen(mirror).contains { $0.hasPrefix("tick ") })
    second.shutdown()
}

/// Scenario 5 of GOAL.md: the core goes away while a board runs, and the board's link connects
/// to the next one by itself, with the cards it had and the changes made meanwhile.
@MainActor
@Test func linkReconnectsToTheNextCore() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    func core() throws -> (CoreServer, Orchestrator) {
        let server = CoreServer(socketPath: path, queue: .main)
        let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
        server.service = orchestrator
        try server.start()
        return (server, orchestrator)
    }
    var (server, orchestrator) = try core()
    let link = CoreLink(connect: { CoreClient.open(socketPath: path, timeout: 10) })
    link.retryInterval = 0.05
    var connections: [BoardState] = []
    link.onConnect = { _, state, waiting in connections.append(state.applying(waiting)) }
    #expect(await link.start())
    let a = agent("Ada", in: folder)
    link.send(.addCard(a))
    try await waitUntil { orchestrator.cards.count == 1 }

    server.stop()
    unlink(path)
    try await waitUntil { !link.isConnected }
    // Made while no core runs: it waits, and reaches the next one.
    let b = agent("Bob", in: folder)
    link.send(.addCard(b))
    _ = orchestrator
    (server, orchestrator) = try core()
    defer { server.stop(); unlink(path) }
    try await waitUntil { connections.count == 2 && orchestrator.cards.count == 2 }
    #expect(connections.count == 2)
    #expect(connections.last?.cards.map(\.name) == ["Ada", "Bob"])
    #expect(orchestrator.cards.map(\.name) == ["Ada", "Bob"])
}

/// Scenario 6 of GOAL.md: a core no version of this build speaks is reported once, so the
/// board can say what to do, and the link connects once a core it can talk to replaces it.
@MainActor
@Test func linkReportsACoreOfAnotherBuild() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    let newer = CoreServer(socketPath: path, queue: .main)
    newer.versions = CoreProtocol.Versions(version: CoreProtocol.version + 3, oldest: CoreProtocol.version + 2)
    try newer.start()
    let link = CoreLink(connect: { CoreClient.open(socketPath: path, timeout: 10) })
    link.retryInterval = 0.05
    var reported: [CoreProtocol.Versions] = []
    var connected = 0
    link.onIncompatible = { reported.append($0) }
    link.onConnect = { _, _, _ in connected += 1 }
    #expect(await link.start())
    try await waitUntil { !reported.isEmpty }
    try await Task.sleep(for: .milliseconds(300))
    #expect(reported == [newer.versions])
    #expect(!link.isConnected)

    newer.stop()
    unlink(path)
    let server = CoreServer(socketPath: path, queue: .main)
    let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
    server.service = orchestrator
    try server.start()
    defer { server.stop(); unlink(path) }
    try await waitUntil { link.isConnected }
    #expect(connected == 1)
    #expect(reported.count == 1)
}

/// Scenario 7 of GOAL.md: a stable and a dev instance run side by side, each with its own
/// `AGENTBOARD_HOME`: their own core, socket, cards and tool server, and stopping one leaves the
/// other's agents alone.
@Test func instancesRunSideBySide() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the AgentBoardCore product first")
    struct Instance {
        let home: URL
        let core: Process
        let board: CoreClient
        let runner: AgentRecord
        let reader: AgentRecord
    }
    var spawned: [Process] = []
    defer { for core in spawned where core.isRunning { core.terminate() } }
    func launch(_ name: String) async throws -> Instance {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abhome-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let core = Process()
        core.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTBOARD_CORE_SOCKET"] = nil
        environment["AGENTBOARD_HOME"] = home.path
        core.environment = environment
        try core.run()
        spawned.append(core)
        // Where the instance's board finds it: in its data folder.
        let socket = home.appendingPathComponent("core.sock").path
        var board: CoreClient?
        let deadline = Date().addingTimeInterval(10)
        while board == nil, Date() < deadline {
            board = CoreClient.connect(socketPath: socket, timeout: 1)
            if board == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let client = try #require(board)
        let runner = AgentRecord(id: UUID(), worktree: home.path, providerID: AgentRecord.runnerProviderID, name: "\(name) server",
                                 frame: CGRect(x: 0, y: 0, width: 600, height: 340),
                                 runner: RunnerSpec(command: "printf '\(name) serving\\n'; sleep 600", directory: home.path, owner: nil))
        let reader = AgentRecord(id: UUID(), worktree: home.path, providerID: AgentRecord.runnerProviderID, name: "\(name) reader",
                                 frame: CGRect(x: 0, y: 400, width: 600, height: 340),
                                 runner: RunnerSpec(command: "sleep 600", directory: home.path, owner: nil))
        client.send(.addCard(runner))
        client.send(.addCard(reader))
        client.send(.connect(Connection(a: reader.id, b: runner.id)))
        client.send(.open(id: runner.id, cols: 80, rows: 24, start: true))
        return Instance(home: home, core: core, board: client, runner: runner, reader: reader)
    }
    func logs(_ instance: Instance) async -> String {
        await binaryCall("runner_logs", as: instance.reader.id, home: instance.home) ?? ""
    }
    func waitFor(_ text: String, in instance: Instance) async throws -> String {
        let deadline = Date().addingTimeInterval(60)
        var output = ""
        while !output.contains(text), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            output = await logs(instance)
        }
        return output
    }

    let stable = try await launch("stable"), dev = try await launch("dev")
    #expect(stable.core.processIdentifier != dev.core.processIdentifier)
    #expect(try await waitFor("stable serving", in: stable).contains("stable serving"))
    #expect(try await waitFor("dev serving", in: dev).contains("dev serving"))
    let port = { (instance: Instance) in try? String(contentsOf: instance.home.appendingPathComponent("tools.port"), encoding: .utf8) }
    #expect(port(stable) != nil && port(stable) != port(dev))
    // Each sees only its own cards.
    #expect(BoardState(stable.board.serviceState ?? Data())?.cards.isEmpty == true)
    let again = try #require(CoreClient.connect(socketPath: stable.home.appendingPathComponent("core.sock").path, timeout: 3))
    #expect(BoardState(again.serviceState ?? Data())?.cards.map(\.name).sorted() == ["stable reader", "stable server"])
    again.disconnect()

    // The dev instance going away leaves the stable one's agents running.
    dev.board.shutdown()
    #expect(waitForExit(dev.core))
    #expect(await logs(stable).contains("stable serving"))
    stable.board.shutdown()
    #expect(waitForExit(stable.core))
}

/// Waits for `process` to end, killing it after `timeout`: a core that doesn't exit fails the
/// test instead of hanging the suite.
func waitForExit(_ process: Process, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    guard process.isRunning else { return true }
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    return false
}
