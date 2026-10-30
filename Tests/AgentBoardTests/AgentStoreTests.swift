import AgentRuntime
import Darwin
import Foundation
import Orchestration
import Testing
@testable import AgentBoard

/// A core in this process, on `path`: the first one, or one taking over from the one there.
@MainActor
private func core(at path: String, folder: URL, inheriting inheritance: Inheritance? = nil) throws -> (CoreServer, Orchestrator) {
    let server = CoreServer(socketPath: path, queue: .main)
    server.lock = inheritance?.lock ?? open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    if let inheritance { server.adopt(inheritance.sessions) }
    let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [], searchPath: "/usr/bin:/bin",
                                    inheriting: inheritance?.service, descriptors: inheritance?.serviceDescriptors ?? [])
    server.service = orchestrator
    try server.start(listening: inheritance?.listener)
    return (server, orchestrator)
}

private func waitUntil(_ seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// Scenario 5 of GOAL.md, with the board's own store: the core is replaced while the board
/// runs, and the board reconnects by itself. No card shows as failed meanwhile, and the card's
/// program and screen carry on.
@MainActor
@Test func theBoardCarriesOnWhenTheCoreIsReplaced() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abstore-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    defer {
        unlink(path)
        unlink(path + ".lock")
    }
    // Held: a server's service is weak.
    let (old, oldOrchestrator) = try core(at: path, folder: folder)
    var handedOff = false
    old.onHandedOff = { handedOff = true }

    let store = AgentStore(connect: { CoreClient.open(socketPath: path, timeout: 2) })
    try await waitUntil { store.isLoaded }
    let record = store.addRunner(command: "i=0; while true; do i=$((i+1)); echo tick $i; sleep 0.05; done", name: "counter",
                                 directory: folder.path, to: folder.path, at: .zero)
    let session = store.session(for: record, cols: 80, rows: 24)
    func ticks() -> [Int] {
        session.withTerminal { $0.recentText(lines: 2000) }.compactMap { $0.hasPrefix("tick ") ? Int($0.dropFirst(5)) : nil }
    }
    try await waitUntil(60) { (ticks().last ?? 0) >= 10 }
    let pid = try #require(session.processID, "\(session.state)")
    let firstClient = try #require(store.core)

    // Watched throughout: a card that shows as failed even for a moment fails the test.
    var states: [AgentSession.State] = []
    let watching = Task { @MainActor in
        while !Task.isCancelled {
            if states.last != session.state { states.append(session.state) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    let inheritance = try #require(await Task.detached { CoreHandoff.takeOver(socketPath: path) }.value)
    let (new, newOrchestrator) = try core(at: path, folder: folder, inheriting: inheritance)
    defer {
        new.closeSession(record.id, grace: 0.5)
        new.stop()
        _ = (oldOrchestrator, newOrchestrator)
    }
    #expect(handedOff)
    try await waitUntil { store.core !== firstClient && store.core?.mirrors(session, id: record.id) == true }
    let after = ticks().last ?? 0
    try await waitUntil { (ticks().last ?? 0) >= after + 20 }
    watching.cancel()

    #expect(store.core !== firstClient)
    #expect(store.notice == nil)
    #expect(states == [.running], "states seen: \(states)")
    #expect(session.processID == pid)
    #expect((ticks().last ?? 0) >= after + 20)
    #expect(store.agents.map(\.id) == [record.id])
    // The mirror's screen is whole: every number once, in order.
    let seen = ticks()
    #expect(seen == Array((seen.first ?? 1)..<((seen.first ?? 1) + seen.count)), "\(seen)")
}
