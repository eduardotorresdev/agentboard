import AgentRuntime
import Connections
import Darwin
import Foundation
@testable import Orchestration
import Testing
@testable import AgentBoard

/// Prints `ready`, then echoes every line it reads as `got <line>`.
private struct Echo: AgentProvider {
    let id = "echo"
    let title = "Echo"
    let executable = "sh"
    func arguments(session: UUID, tools: ToolServerLink?) -> [String] {
        ["-c", "printf 'ready\\n'; while IFS= read -r line; do printf 'got %s\\n' \"$line\"; done"]
    }
    func environment(_ base: [String: String]) -> [String: String] { base }
}

/// A core in this process on a socket of its own: this Mac's, or one standing in for a host's.
@MainActor
private final class Machine {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ablink-\(UUID().uuidString.prefix(8))")
    let path = NSTemporaryDirectory() + "ablink-\(UUID().uuidString.prefix(8)).sock"
    let server: CoreServer
    let orchestrator: Orchestrator
    let store: AgentStore

    init(host: (id: UUID, name: String)? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server = CoreServer(socketPath: path, queue: .main)
        server.lock = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [Echo()], searchPath: "/usr/bin:/bin")
        server.service = orchestrator
        try server.start(listening: nil)
        let path = path
        store = AgentStore(connect: { CoreClient.open(socketPath: path, timeout: 10) }, host: host)
    }

    /// An echo agent on this machine's board, running.
    func agent(_ name: String) async throws -> (AgentRecord, AgentSession) {
        try await waitFor { self.store.isLoaded }
        var record = store.add(Echo(), to: folder.path, at: .zero)
        record.name = name
        store.rename(record.id, to: name)
        let session = store.session(for: record, cols: 200, rows: 40)
        try await waitFor { self.screen(session).contains("ready") }
        return (store.record(record.id) ?? record, session)
    }

    func screen(_ session: AgentSession) -> String {
        session.withTerminal { $0.recentText(lines: 400) }.joined(separator: "\n")
    }

    /// Calls a board tool as agent `caller` would.
    func call(_ tool: String, _ arguments: [String: Any], as caller: UUID) async throws -> (text: String, isError: Bool) {
        var request = URLRequest(url: try #require(orchestrator.toolsEndpoint))
        request.httpMethod = "POST"
        request.setValue("Bearer \(orchestrator.toolToken(for: caller))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false)
    }

    func stop() {
        for card in orchestrator.cards { server.closeSession(card.id, grace: 0.5) }
        server.stop()
        unlink(path)
        unlink(path + ".lock")
    }
}

private func waitFor(_ seconds: Double = 30, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await condition())
}

/// `@@` from Ada's composer (on this Mac) to Bob (on a host): Bob gets the message, Ada is told
/// how to reach him, each board shows the other as a relay connected to its agent, and from then
/// on they message each other both ways across the two cores, through this board. The link is
/// kept in the database, and taking a relay's line away ends it on both boards.
@MainActor
@Test func mentioningAnAgentElsewhereLinksTheTwo() async throws {
    let mac = try Machine()
    let host = try Machine(host: (UUID(), "Builder"))
    defer { mac.stop(); host.stop() }
    let databaseURL = mac.folder.appendingPathComponent("board.sqlite")
    let links = AgentLinks(database: try Database(url: databaseURL), projects: nil)
    links.store = { $0 == nil ? mac.store : host.store }
    links.stores = { [mac.store, host.store] }
    links.attach(to: mac.store)
    links.attach(to: host.store)
    let (ada, adaScreen) = try await mac.agent("Ada")
    let (bob, bobScreen) = try await host.agent("Bob")

    #expect(mac.store.sendElsewhere("please run the tests", to: [(bob.id, host.store)], from: ada.id) == nil)
    let link = try #require(links.links.first)
    let adaEnd = try #require(link.ends.first { $0.agent == ada.id })
    let bobEnd = try #require(link.ends.first { $0.agent == bob.id })
    let bobRelay = links.relayName(on: adaEnd, in: link)
    #expect(bobRelay.hasPrefix("Bob (") && bobRelay.hasSuffix(" on Builder)"))
    try await waitFor { bobScreen.withTerminal { $0.recentText(lines: 400) }.joined().contains("got please run the tests") }
    // Ada hears it from the board, with the name to reach Bob by.
    try await waitFor { mac.screen(adaScreen).contains("got [Board] The user sent the message below to “\(bobRelay)”") }

    // A line on each board, between the agent and the relay standing for the other.
    try await waitFor { mac.store.connections.contains { $0.joins(ada.id, adaEnd.relay) } }
    try await waitFor { host.store.connections.contains { $0.joins(bob.id, bobEnd.relay) } }
    #expect(try Database(url: databaseURL).agentLinks().map(\.id) == [link.id])
    // After a restart the relays come back where they were.
    let reopened = AgentLinks(database: try Database(url: databaseURL), projects: nil)
    reopened.store = links.store
    #expect(reopened.relays(on: nil).map(\.id) == [adaEnd.relay] && reopened.relays(on: nil).first?.frame == adaEnd.frame)

    // Ada → Bob and back, with the tools any line gives.
    let peers = try await mac.call("list_peers", [:], as: ada.id)
    #expect(peers.text.contains("“\(bobRelay)” (agent,") && peers.text.contains("connected: true"), "\(peers.text)")
    let sent = try await mac.call("send_message", ["to": bobRelay, "message": "ping from Ada"], as: ada.id)
    #expect(!sent.isError, "\(sent.text)")
    try await waitFor { mac.screen(bobScreen).contains("ping from Ada") && mac.screen(bobScreen).contains("Message from “Ada (") }
    let adaRelay = links.relayName(on: bobEnd, in: link)
    let back = try await host.call("send_message", ["to": adaRelay, "message": "pong from Bob"], as: bob.id)
    #expect(!back.isError, "\(back.text)")
    try await waitFor { mac.screen(adaScreen).contains("pong from Bob") }

    // The user takes Ada's line to the relay away: the link ends on both boards.
    let line = try #require(mac.store.connections.first { $0.joins(ada.id, adaEnd.relay) })
    mac.store.disconnect(line.id)
    try await waitFor { links.links.isEmpty }
    try await waitFor { !host.store.connections.contains { $0.touches(bobEnd.relay) } }
    #expect(try Database(url: databaseURL).agentLinks().isEmpty)
}

@Test func theNoticeSaysWhoGotItAndHowToReachThem() {
    let notice = AgentStore.linkNotice(names: ["“Bob (shop › checkout)”"], text: "run the tests")
    #expect(notice.hasPrefix("[Board] "))
    #expect(notice.contains("send_message to “Bob (shop › checkout)”"))
    #expect(notice.hasSuffix("\n\nrun the tests"))
}

/// Both agents on one core (two worktrees of this Mac): the core lists the first relay's line
/// before it has the second, and that isn't the user taking the second away.
@MainActor
@Test func aLinkOnOneCoreKeepsBothRelays() async throws {
    let mac = try Machine()
    defer { mac.stop() }
    let links = AgentLinks(database: nil, projects: nil)
    links.store = { _ in mac.store }
    links.stores = { [mac.store] }
    links.attach(to: mac.store)
    let (ada, _) = try await mac.agent("Ada")
    let (bob, _) = try await mac.agent("Bob")

    let link = try #require(links.link(ada.id, in: mac.store, with: bob.id, in: mac.store))
    for end in link.ends {
        try await waitFor { mac.store.connections.contains { $0.joins(end.agent, end.relay) } }
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(links.links.map(\.id) == [link.id])
    #expect(link.ends.allSatisfy { end in mac.store.connections.contains { $0.joins(end.agent, end.relay) } })
}
