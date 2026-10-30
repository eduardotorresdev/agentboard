import AgentRuntime
import Connections
import Darwin
import Foundation
import Orchestration

/// Scenario 3 of GOAL.md: no board runs for `minutes`, and meanwhile agents message each other,
/// start a runner and read its logs. Every call must be answered and every message delivered,
/// once.
///
/// The agents are a stand-in `claude` (a script that writes down each line it gets), found
/// before any real one on the core's PATH; the run refuses to start if a real one would be.
@MainActor
func quietRun(minutes: Double) async -> Bool {
    let instance: Instance
    do { instance = try Instance(core: coreBinary) } catch {
        say("Couldn't make a data folder: \(error)")
        return false
    }
    let work = instance.home.appendingPathComponent("work")
    let bin = instance.home.appendingPathComponent("bin")
    let inbox = instance.home.appendingPathComponent("inbox")
    for folder in [work, bin, inbox] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let fake = bin.appendingPathComponent("claude")
    let script = """
        #!/bin/sh
        # Stands in for Claude Code: writes down every line typed into it.
        stty -echo 2>/dev/null
        echo "ready"
        while IFS= read -r line; do
            printf '%s\\n' "$line" >> '\(inbox.path)/'$$
            echo "got it"
        done
        """
    FileManager.default.createFile(atPath: fake.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    instance.environment["PATH"] = bin.path + ":/usr/bin:/bin"
    let environment = instance.environment
    let quiet = instance

    // The core finds programs on its login shell's PATH: `claude` must be the stand-in there.
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/sh")
    probe.arguments = ["-l", "-i", "-c", "command -v claude"]
    probe.environment = environment
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    probe.standardInput = FileHandle.nullDevice
    try? probe.run()
    probe.waitUntilExit()
    let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard found == fake.path else {
        say("Refusing to run: `claude` on the core's PATH is \(found.isEmpty ? "missing" : found), not the stand-in.")
        return false
    }

    say("quiet: no board for \(minutes) min, in \(instance.home.path)")
    guard quiet.replaceCore() else {
        say("The core didn't start.")
        return false
    }
    func agent(_ name: String, x: Double) -> AgentRecord {
        AgentRecord(id: UUID(), worktree: work.path, providerID: "claude", name: name, frame: CGRect(x: x, y: 0, width: 640, height: 420))
    }
    let ada = agent("Ada", x: 0), bob = agent("Bob", x: 700)
    // Opened by the board, then left alone: the board goes away before anything else happens.
    let setup = Board(socket: instance.socket, cards: [], startPrograms: false)
    guard await setup.start(), let client = setup.link.client else {
        say("No board could connect.")
        return false
    }
    client.send(.addCard(ada))
    client.send(.addCard(bob))
    client.send(.connect(Connection(a: ada.id, b: bob.id)))
    try? await Task.sleep(for: .milliseconds(200))
    setup.kill()
    let opener = Board(socket: instance.socket,
                       cards: [Card(record: ada, cols: 100, rows: 30), Card(record: bob, cols: 100, rows: 30)], startPrograms: true)
    _ = await opener.start()
    let deadline = Date().addingTimeInterval(90)
    while [ada, bob].contains(where: { opener.mirrors[$0.id]?.state != .running }), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }
    let pids = [ada.id: opener.mirrors[ada.id]?.processID, bob.id: opener.mirrors[bob.id]?.processID]
    guard let adaPID = pids[ada.id] ?? nil, let bobPID = pids[bob.id] ?? nil else {
        say("The agents didn't start.")
        return false
    }
    opener.kill()
    say("agents up (Ada \(adaPID), Bob \(bobPID)); no board from now on")

    var failures: [String] = []
    var answered = 0
    var sent: [Int32: [String]] = [adaPID: [], bobPID: []]
    func expect(_ answer: Instance.Answer?, _ what: String, containing text: String? = nil) {
        guard let answer else { return failures.append("\(what): no answer") }
        if answer.isError { return failures.append("\(what): \(answer.text)") }
        if let text, !answer.text.contains(text) { return failures.append("\(what): “\(answer.text.prefix(200))” lacks “\(text)”") }
        answered += 1
    }
    let start = Date()
    let end = start.addingTimeInterval(minutes * 60)
    var round = 0
    var startedRunner = false
    while Date() < end {
        round += 1
        let note = "note-\(round)", reply = "reply-\(round)"
        expect(await quiet.call("send_message", ["to": "Bob", "message": note], as: ada.id), "Ada → Bob \(round)")
        sent[bobPID]?.append(note)
        expect(await quiet.call("send_message", ["to": "Ada", "message": reply], as: bob.id), "Bob → Ada \(round)")
        sent[adaPID]?.append(reply)
        if !startedRunner, Date().timeIntervalSince(start) > min(60, minutes * 30) {
            startedRunner = true
            expect(await quiet.call("runner_start", ["command": "echo ticker up; while true; do echo tick; sleep 2; done", "name": "ticker",
                                                     "wait": false], as: ada.id), "runner_start", containing: "ticker")
        }
        if startedRunner {
            expect(await quiet.call("runner_logs", ["runner": "ticker", "lines": 5], as: ada.id), "runner_logs \(round)", containing: "tick")
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        if round % 6 == 0 { say("\(elapsed / 60) min \(elapsed % 60) s: \(answered) calls answered, \(failures.count) failures") }
        try? await Task.sleep(for: .seconds(5))
    }
    if !startedRunner { failures.append("the run was too short to start a runner") }

    // Every message arrived at its agent's program once, in order.
    try? await Task.sleep(for: .seconds(2))
    for (pid, messages) in sent {
        let got = ((try? String(contentsOf: inbox.appendingPathComponent(String(pid)), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        // `note-1` is in `note-12` too.
        let arrived = messages.map { message in
            got.filter { $0.range(of: NSRegularExpression.escapedPattern(for: message) + "(?![0-9])", options: .regularExpression) != nil }.count
        }
        let missing = zip(messages, arrived).filter { $0.1 == 0 }.map(\.0)
        let repeated = zip(messages, arrived).filter { $0.1 > 1 }.map(\.0)
        if !missing.isEmpty || !repeated.isEmpty {
            failures.append("pid \(pid): missing \(missing.prefix(5)), repeated \(repeated.prefix(5)) of \(messages.count)")
        }
    }
    // And the agents are the ones that started.
    if let look = CoreClient.connect(socketPath: instance.socket, timeout: 3) {
        if look.known[ada.id]?.processID != adaPID || look.known[bob.id]?.processID != bobPID { failures.append("an agent's program changed") }
        look.shutdown()
    } else {
        failures.append("the core is gone")
    }
    say("\(round) rounds, \(answered) calls answered, \(sent.values.map(\.count).reduce(0, +)) messages")
    if failures.isEmpty {
        say("PASS")
        instance.remove()
        return true
    }
    for failure in failures.prefix(20) { say("FAIL: \(failure)") }
    say("data kept in \(instance.home.path)")
    return false
}
