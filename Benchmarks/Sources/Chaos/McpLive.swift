import AgentRuntime
import Darwin
import Foundation
import Orchestration

/// With the real Claude Code: an agent picks up the tools of a newer core without being
/// restarted. The agent opens its event stream, the core is replaced, and the new core's
/// `tools/list_changed` must make the agent list the tools again. Nothing is typed into the
/// agent, so no prompt is sent.
///
/// Runs in `directory`, which Claude Code must already trust (no trust dialog to answer).
@MainActor
func mcpLive(directory: String) async -> Bool {
    guard let instance = try? Instance(core: coreBinary) else { return false }
    // The developer's own Claude Code: their home (its login) and shell (its PATH).
    instance.environment["HOME"] = NSHomeDirectory()
    instance.environment["SHELL"] = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    instance.environment["AGENTBOARD_CORE_VERBOSE"] = "1"
    let log = CoreLog(url: instance.home.appendingPathComponent("core.log"))
    var failures: [String] = []
    defer {
        if let client = CoreClient.connect(socketPath: instance.socket, timeout: 3) { client.shutdown() }
        if failures.isEmpty { instance.remove() } else { say("data kept in \(instance.home.path)") }
    }
    guard instance.replaceCore() else {
        failures.append("the core didn't start")
        say("FAIL: the core didn't start")
        return false
    }
    let card = Card(record: AgentRecord(id: UUID(), worktree: directory, providerID: "claude", name: "Claude",
                                        frame: CGRect(x: 0, y: 0, width: 900, height: 600)),
                    cols: 120, rows: 40)
    let setup = Board(socket: instance.socket, cards: [], startPrograms: false)
    guard await setup.start(), let client = setup.link.client else { return false }
    client.send(.addCard(card.record))
    try? await Task.sleep(for: .milliseconds(200))
    setup.kill()
    let board = Board(socket: instance.socket, cards: [card], startPrograms: true)
    _ = await board.start()
    defer { board.kill() }

    func requests(_ text: String, after start: Date) -> Int {
        log.lines(after: start).filter { $0.contains("tools: \(card.id) \(text)") }.count
    }
    func waitFor(_ text: String, after start: Date, count: Int = 1, timeout: Double = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while requests(text, after: start) < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return requests(text, after: start) >= count
    }
    let began = Date.distantPast
    guard await waitFor("tools/list", after: began) else {
        failures.append("Claude Code never listed the tools")
        return report(failures, board.mirrors[card.id])
    }
    say("Claude Code listed the tools (pid \(board.mirrors[card.id]?.processID ?? 0))")
    guard await waitFor("opened a stream", after: began, timeout: 20) else {
        failures.append("Claude Code didn't open an event stream")
        return report(failures, board.mirrors[card.id])
    }
    say("it opened an event stream")
    let pid = board.mirrors[card.id]?.processID
    try? await Task.sleep(for: .seconds(2))

    let replaced = Date()
    guard instance.replaceCore() else {
        failures.append("the new core didn't take over")
        return report(failures, board.mirrors[card.id])
    }
    say("a newer core took over")
    if await waitFor("tools/list", after: replaced, timeout: 30) {
        say("Claude Code listed the tools again, from the new core")
    } else {
        failures.append("Claude Code didn't list the tools again after the new core said they changed")
    }
    if let status = CoreClient.connect(socketPath: instance.socket, timeout: 3)?.known[card.id], status.processID != pid {
        failures.append("the agent's program changed")
    }
    return report(failures, board.mirrors[card.id])
}

@MainActor
private func report(_ failures: [String], _ session: AgentSession?) -> Bool {
    if failures.isEmpty {
        say("PASS")
        return true
    }
    for failure in failures { say("FAIL: \(failure)") }
    if let screen = session?.withTerminal({ $0.screenText() }) {
        say("the agent's screen:")
        for line in screen where !line.trimmingCharacters(in: .whitespaces).isEmpty { say("  \(line)") }
    }
    return false
}
