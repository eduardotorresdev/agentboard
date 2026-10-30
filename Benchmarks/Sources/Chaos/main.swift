import AgentRuntime
import Connections
import Darwin
import Foundation
import Orchestration
import TerminalCore

// chaos: the gate of GOAL.md. Agents (FakeAgent, a Claude Code-like session) run on the real
// core while boards are killed and replaced and the core is replaced by newer ones at random
// moments, and an agent keeps calling its tools and typing into another program meanwhile.
// Then every terminal must be exactly what its program wrote (the core's and the last board's,
// against a reference terminal fed the program's own copy of its output), every message must
// have arrived once, every tool call must have been answered, and every program must still be
// the one that started.
//
//   swift run -c release Chaos [--seconds 60] [--agents 20] [--seed 1] [--core PATH]
//   swift run -c release Chaos --no-board 10    (scenario 3: ten minutes without a board)
//   swift run -c release Chaos --app 4 [--kills 3] [--agents 8]
//                                               (scenarios 1 and 2 with the real app under ./run --watch)
//   swift run -c release Chaos --side-by-side 4 (scenario 7: a stable build beside a dev one being broken)
//   swift run -c release Chaos --install 4     (./install, first and again, while agents run)
//   swift run -c release Chaos --mcp-live DIR   (the real Claude Code relists the tools of a newer core)
//   swift run -c release Chaos --latency 500    (a keystroke's echo, PTY in the board vs on the core)
//
// The core is the app package's debug build unless --core says otherwise: build it first
// (`swift build --product AgentBoardCore` at the top).

// A core that hangs up on what it was sent must not end the run.
signal(SIGPIPE, SIG_IGN)

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let key = arguments.next(), key.hasPrefix("--") { options[String(key.dropFirst(2))] = arguments.next() ?? "" }

let seconds = Double(options["seconds"] ?? "60") ?? 60
let agentCount = Int(options["agents"] ?? "20") ?? 20
var random = SystemRandomNumberGenerator()
let seed = UInt64(options["seed"] ?? "") ?? UInt64.random(in: 1...999_999, using: &random)
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let coreBinary = URL(fileURLWithPath: options["core"] ?? repository.appendingPathComponent(".build/debug/AgentBoardCore").path)
let fakeAgent = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("FakeAgent")

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

/// Seeded, so a failing run can be replayed.
struct Dice {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

@MainActor
func run() async -> Bool {
    guard FileManager.default.isExecutableFile(atPath: coreBinary.path) else {
        say("No core at \(coreBinary.path): build it with `swift build --product AgentBoardCore`.")
        return false
    }
    guard FileManager.default.isExecutableFile(atPath: fakeAgent.path) else {
        say("No FakeAgent next to this executable.")
        return false
    }
    let instance: Instance
    do { instance = try Instance(core: coreBinary) } catch {
        say("Couldn't make a data folder: \(error)")
        return false
    }
    say("chaos: \(agentCount) agents, \(Int(seconds)) s, seed \(seed), in \(instance.home.path)")
    var dice = Dice(seed: seed)
    let until = instance.home.appendingPathComponent("stop").path
    let work = instance.home.appendingPathComponent("work")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // The agents, a program messages are typed into, and the agent calling the tools.
    let agents = (0..<agentCount).map { index in
        Card.runner("agent \(index)", "exec '\(fakeAgent.path)' --mode stream --seed \(Int(seed) + index) "
                    + "--tee '\(work.appendingPathComponent("tee-\(index)").path)' --until '\(until)'", in: work)
    }
    let delivered = work.appendingPathComponent("delivered").path
    let echo = Card.runner("echo", "stty -echo; while IFS= read -r line; do echo \"$line\" >> '\(delivered)'; echo \"got $line\"; done",
                           in: work, cols: 80, rows: 24)
    let caller = Card.runner("caller", "sleep 100000", in: work, cols: 80, rows: 24)
    let cards = agents + [echo, caller]

    guard instance.replaceCore() else {
        say("The core didn't start; see \(instance.home.appendingPathComponent("core.log").path)")
        return false
    }
    // A board adds the cards; the next one opens them, as the app does after a relaunch.
    var board = Board(socket: instance.socket, cards: [], startPrograms: false)
    guard await board.start(), let client = board.link.client else {
        say("No board could connect.")
        return false
    }
    for card in cards { client.send(.addCard(card.record)) }
    for card in agents + [echo] { client.send(.connect(Connection(a: caller.id, b: card.id))) }
    try? await Task.sleep(for: .milliseconds(200))
    board.kill()
    board = Board(socket: instance.socket, cards: cards, startPrograms: true)
    _ = await board.start()

    // Every program running, with the pid it must keep.
    var deadline = Date().addingTimeInterval(60)
    while cards.contains(where: { board.mirrors[$0.id]?.processID == nil }), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
    let pids = cards.reduce(into: [UUID: Int32]()) { $0[$1.id] = board.mirrors[$1.id]?.processID }
    guard pids.count == cards.count else {
        say("Not every program started.")
        return false
    }
    deadline = Date().addingTimeInterval(60)
    while await instance.call("runner_list", as: caller.id) == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }

    // The agent calling its tools throughout: typing a numbered line into the echo program,
    // and reading an agent's output.
    let tally = Tally()
    let done = Flag()
    let calls = Task.detached { () -> Int in
        var sent = 0
        var turn = 0
        while !done.isSet {
            turn += 1
            if turn % 2 == 0 {
                let target = "agent \(turn / 2 % agentCount)"
                if let answer = await instance.call("runner_logs", ["runner": target, "lines": 5], as: caller.id) {
                    tally.add(answer.isError ? "refused" : "answered")
                    if answer.isError { tally.note("runner_logs refused: \(answer.text)") }
                } else {
                    tally.add("failed")
                }
                continue
            }
            let line = "message-\(sent + 1)"
            if let answer = await instance.call("runner_input", ["runner": "echo", "text": line], as: caller.id) {
                tally.add(answer.isError ? "refused" : "answered")
                if answer.isError { tally.note("runner_input refused: \(answer.text)") } else { sent += 1 }
            } else {
                // It may or may not have arrived: a lost answer is a failure either way.
                tally.add("failed")
                sent += 1
                tally.note("runner_input \(line): no answer")
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return sent
    }

    // The chaos itself.
    var attaches: [Double] = []
    var handoffs: [Double] = []
    var replacing: Task<Double?, Never>?
    var boardsKilled = 0, coresReplaced = 0
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        try? await Task.sleep(for: .milliseconds(Int(150 + dice.next() * 850)))
        let roll = dice.next()
        if roll < 0.45 {
            // A board killed mid-turn (a rebuild, kill -9), and the next one launched.
            board.kill()
            boardsKilled += 1
            let start = DispatchTime.now().uptimeNanoseconds
            board = Board(socket: instance.socket, cards: cards, startPrograms: false)
            _ = await board.start()
            let fresh = board
            let deadline = Date().addingTimeInterval(10)
            while !agents.allSatisfy({ fresh.mirrors[$0.id]?.withTerminal({ !$0.screenText().joined().trimmingCharacters(in: .whitespaces).isEmpty }) == true }),
                  Date() < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            attaches.append(milliseconds(since: start))
        } else if roll < 0.8, replacing == nil {
            // A newer core takes over, while the board carries on.
            coresReplaced += 1
            replacing = Task.detached {
                let start = DispatchTime.now().uptimeNanoseconds
                return instance.replaceCore() ? milliseconds(since: start) : nil
            }
        }
        if let task = replacing, roll >= 0.8 || dice.next() < 0.5 {
            replacing = nil
            guard let time = await task.value else {
                say("FAIL: a core couldn't take over:")
                for line in instance.log.split(separator: "\n").suffix(6) { say("  \(line)") }
                done.set()
                return false
            }
            handoffs.append(time)
        }
    }
    if let task = replacing {
        guard let time = await task.value else {
            say("FAIL: a core couldn't take over")
            done.set()
            return false
        }
        handoffs.append(time)
    }
    done.set()
    let sent = await calls.value

    // Quiet: the agents stop writing, and everything they wrote reaches the terminals.
    FileManager.default.createFile(atPath: until, contents: Data())
    func sizes() -> [UInt64] {
        agents.indices.map { index in
            ((try? FileManager.default.attributesOfItem(atPath: work.appendingPathComponent("tee-\(index)").path))?[.size] as? UInt64) ?? 0
        }
    }
    var last = sizes()
    var stable = 0
    while stable < 10 {
        try? await Task.sleep(for: .milliseconds(100))
        let now = sizes()
        stable = now == last ? stable + 1 : 0
        last = now
    }
    deadline = Date().addingTimeInterval(10)
    while !board.isCurrent, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    try? await Task.sleep(for: .seconds(1))

    // What a board attaching now gets: the core's own terminals.
    let check = Board(socket: instance.socket, cards: cards, startPrograms: false)
    _ = await check.start()
    deadline = Date().addingTimeInterval(10)
    while !check.isCurrent, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    try? await Task.sleep(for: .seconds(1))

    var failures: [String] = []
    for (index, card) in agents.enumerated() {
        let tee = (try? Data(contentsOf: work.appendingPathComponent("tee-\(index)"))) ?? Data()
        let reference = Terminal(cols: card.cols, rows: card.rows)
        reference.feed(Array(tee))
        let expected = reference.snapshot()
        let core = check.mirrors[card.id]?.withTerminal { $0.snapshot() } ?? []
        let mirrored = board.mirrors[card.id]?.withTerminal { $0.snapshot() } ?? []
        if core != expected {
            failures.append("agent \(index): the core's terminal differs from what the program wrote (\(tee.count) bytes)"
                            + firstDifference(check.mirrors[card.id], reference))
        }
        if mirrored != expected {
            failures.append("agent \(index): the board's terminal differs from what the program wrote" + firstDifference(board.mirrors[card.id], reference))
        }
    }
    // Every program is the one that started.
    let statuses = check.link.client?.known ?? [:]
    for card in cards where statuses[card.id]?.processID != pids[card.id] {
        failures.append("\(card.record.name): its program changed from \(pids[card.id] ?? 0) to \(statuses[card.id]?.processID ?? 0)")
    }
    // Every message arrived once, in order.
    let lines = ((try? String(contentsOfFile: delivered, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    if lines != (0..<sent).map({ "message-\($0 + 1)" }) {
        let got = Set(lines)
        let missing = (1...max(1, sent)).filter { !got.contains("message-\($0)") }.prefix(10)
        failures.append("messages: sent \(sent), the program got \(lines.count); missing \(Array(missing)), "
                        + "repeated \(lines.count - got.count)")
    }
    if tally.count("failed") > 0 { failures.append("tool calls: \(tally.count("failed")) got no answer") }
    if tally.count("refused") > 0 { failures.append("tool calls: \(tally.count("refused")) refused: \(tally.allNotes.prefix(3))") }

    let bytes = sizes().reduce(0, +)
    say("boards killed \(boardsKilled), cores replaced \(coresReplaced), tool calls answered \(tally.count("answered")), "
        + "messages \(sent), agent output \(bytes / 1024) KB")
    say(String(format: "reattaching %d sessions: median %.0f ms, p95 %.0f ms, max %.0f ms (target < 300 ms)",
               agentCount, percentile(attaches, 0.5), percentile(attaches, 0.95), attaches.max() ?? 0))
    say(String(format: "core handoff, launch to serving: median %.0f ms, max %.0f ms", percentile(handoffs, 0.5), handoffs.max() ?? 0))
    if agentCount >= 20, percentile(attaches, 0.95) >= 300 { failures.append("reattaching took 300 ms or more (p95)") }

    check.kill()
    board.kill()
    if let client = CoreClient.connect(socketPath: instance.socket, timeout: 3) { client.shutdown() }
    if failures.isEmpty {
        say("PASS")
        instance.remove()
        return true
    }
    for failure in failures { say("FAIL: \(failure)") }
    say("replay with --seed \(seed); data kept in \(instance.home.path)")
    return false
}

/// The first row where `session`'s screen and `reference`'s differ, to say how.
func firstDifference(_ session: AgentSession?, _ reference: Terminal) -> String {
    let actual = session?.withTerminal { $0.screenText() } ?? []
    let expected = reference.screenText()
    guard let row = zip(actual, expected).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else {
        return actual.count == expected.count ? " (same text; attributes, cursor or scrollback differ)" : " (row counts differ)"
    }
    return "; row \(row) is “\(actual[row].trimmingCharacters(in: .whitespaces))”, expected “\(expected[row].trimmingCharacters(in: .whitespaces))”"
}

if let edits = options["app"].flatMap(Int.init) {
    exit(await appRun(edits: edits, kills: Int(options["kills"] ?? "3") ?? 3, agentCount: Int(options["agents"] ?? "8") ?? 8) ? 0 : 1)
}
if let count = options["install"].flatMap(Int.init) {
    exit(await installRun(agentCount: count) ? 0 : 1)
}
if let directory = options["mcp-live"] {
    exit(await mcpLive(directory: directory) ? 0 : 1)
}
if let samples = options["latency"].flatMap(Int.init) {
    exit(await latencyRun(samples: samples) ? 0 : 1)
}
if let count = options["side-by-side"].flatMap(Int.init) {
    exit(await sideBySide(agentCount: count) ? 0 : 1)
}
if let minutes = options["no-board"].flatMap(Double.init) {
    exit(await quietRun(minutes: minutes) ? 0 : 1)
}
exit(await run() ? 0 : 1)
