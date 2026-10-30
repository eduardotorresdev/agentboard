import AgentRuntime
import Connections
import Darwin
import Foundation
import Orchestration
import TerminalCore

/// A data folder with agents on a core, and the real app showing them: what a developer has
/// open. An agent calls its tools throughout. At the end, the app's terminals and the core's
/// must be exactly what each program wrote, every message must have arrived once, every call
/// must have been answered, and every program must be the one that started.
///
/// The app stays behind other windows. Its terminals are read from the dump it writes on
/// SIGUSR1 (`AGENTBOARD_SCREENS`), not from the screen.
@MainActor
final class AppBench {
    let instance: Instance
    let work: URL
    let agents: [Card]
    let echo: Card
    let caller: Card
    var cards: [Card] { agents + [echo, caller] }
    var ids: Set<UUID> { Set(cards.map(\.id)) }
    /// What the app runs with: the developer's environment, on this data folder.
    private(set) var appEnvironment: [String: String]
    let coreLog: CoreLog
    private let until: String
    private let go: String
    private let screens: String
    private let delivered: String
    private var pids: [UUID: Int32] = [:]
    private let tally = Tally()
    private let done = Flag()
    private var calls: Task<Int, Never>?
    private var defaultsKey: String { "openWorktree:" + instance.home.path }

    init(core: URL, agentCount: Int, seed: UInt64) throws {
        instance = try Instance(core: core)
        instance.environment["AGENTBOARD_CORE_VERBOSE"] = "1"
        // The worktree's path as git gives it (/private/var, not /var), or the cards aren't its.
        guard let real = realpath(instance.home.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        work = URL(fileURLWithPath: String(cString: real)).appendingPathComponent("work")
        free(real)
        until = instance.home.appendingPathComponent("stop").path
        go = instance.home.appendingPathComponent("go").path
        screens = instance.home.appendingPathComponent("screens.json").path
        delivered = work.appendingPathComponent("delivered").path
        coreLog = CoreLog(url: instance.home.appendingPathComponent("core.log"))

        // Laid out in a grid, as a developer would. The agents wait for `go`: they start
        // writing once the app gave their terminals its size.
        let work = work, go = go, until = until
        func card(_ index: Int, _ name: String, _ command: String) -> Card {
            let frame = CGRect(x: Double(index % 4) * 720, y: Double(index / 4) * 480, width: 700, height: 460)
            return Card(record: AgentRecord(id: UUID(), worktree: work.path, providerID: AgentRecord.runnerProviderID, name: name, frame: frame,
                                            runner: RunnerSpec(command: command, directory: work.path, owner: nil)),
                        cols: 100, rows: 30)
        }
        agents = (0..<agentCount).map { index in
            card(index, "agent \(index)", "while [ ! -f '\(go)' ]; do sleep 0.05; done; exec '\(fakeAgent.path)' --mode stream --seed \(Int(seed) + index) "
                 + "--tee '\(work.appendingPathComponent("tee-\(index)").path)' --until '\(until)'")
        }
        echo = card(agentCount, "echo", "stty -echo; while IFS= read -r line; do echo \"$line\" >> '\(delivered)'; echo \"got $line\"; done")
        caller = card(agentCount + 1, "caller", "sleep 100000")

        appEnvironment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        appEnvironment["AGENTBOARD_HOME"] = instance.home.path
        appEnvironment["AGENTBOARD_CORE_SOCKET"] = instance.socket
        appEnvironment["AGENTBOARD_CORE_VERBOSE"] = "1"
        appEnvironment["AGENTBOARD_SCREENS"] = screens
        appEnvironment["AGENTBOARD_BACKGROUND"] = "1"
    }

    /// Starts the core and every card's program, and adds the worktree as a project the app
    /// opens by itself (as it reopens the last one). Nil, or what went wrong.
    func prepare() async -> String? {
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard shell("git init -q '\(work.path)' && git -C '\(work.path)' -c user.name=chaos -c user.email=chaos@localhost commit -q --allow-empty -m start") else {
            return "couldn't make the worktree"
        }
        guard instance.replaceCore() else { return "the core didn't start; see \(coreLog.url.path)" }
        let setup = Board(socket: instance.socket, cards: [], startPrograms: false)
        guard await setup.start(), let client = setup.link.client else { return "no board could connect" }
        for card in cards { client.send(.addCard(card.record)) }
        for card in agents + [echo] { client.send(.connect(Connection(a: caller.id, b: card.id))) }
        try? await Task.sleep(for: .milliseconds(200))
        setup.kill()
        let opener = Board(socket: instance.socket, cards: cards, startPrograms: true)
        _ = await opener.start()
        let deadline = Date().addingTimeInterval(60)
        while cards.contains(where: { opener.mirrors[$0.id]?.processID == nil }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        pids = cards.reduce(into: [UUID: Int32]()) { $0[$1.id] = opener.mirrors[$1.id]?.processID }
        opener.kill()
        guard pids.count == cards.count else { return "not every program started" }

        let database = instance.home.appendingPathComponent("agentboard.sqlite").path
        guard shell("/usr/bin/sqlite3 '\(database)' \"CREATE TABLE IF NOT EXISTS projects (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                    + "name TEXT NOT NULL, path TEXT NOT NULL UNIQUE); INSERT INTO projects (name, path) VALUES ('work', '\(work.path)');\"")
                && shell("defaults write AgentBoard '\(defaultsKey)' '\(work.path)'") else { return "couldn't add the project" }
        return nil
    }

    /// Launches the app at `binary` on this data folder.
    func launch(_ binary: URL) -> Process? {
        let app = Process()
        app.executableURL = binary
        app.environment = appEnvironment
        app.standardOutput = FileHandle.nullDevice
        app.standardError = FileHandle.nullDevice
        return (try? app.run()).map { app }
    }

    /// The agents start writing, and the caller calling.
    func begin() {
        FileManager.default.createFile(atPath: go, contents: Data())
        let instance = instance, tally = tally, done = done, agentCount = agents.count, caller = caller.id
        calls = Task.detached { () -> Int in
            var sent = 0
            var turn = 0
            while !done.isSet {
                turn += 1
                if turn % 2 == 0 {
                    if let answer = await instance.call("runner_logs", ["runner": "agent \(turn / 2 % agentCount)", "lines": 5], as: caller) {
                        tally.add(answer.isError ? "refused" : "answered")
                        if answer.isError { tally.note("runner_logs refused: \(answer.text)") }
                    } else {
                        tally.add("failed")
                    }
                    continue
                }
                let line = "message-\(sent + 1)"
                if let answer = await instance.call("runner_input", ["runner": "echo", "text": line], as: caller) {
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
    }

    /// Stops the agents and the caller, then checks everything against what the programs
    /// wrote: the terminals of `app` (which then quits as a rebuild would, leaving the
    /// agents) and the core's. What failed.
    func finish(app: Process?) async -> [String] {
        await finish(appPID: app?.processIdentifier)
    }

    /// As `finish(app:)`, for an app this process didn't launch.
    func finish(appPID: Int32?) async -> [String] {
        done.set()
        let sent = await calls?.value ?? 0
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
        try? await Task.sleep(for: .seconds(1))

        unlink(screens)
        if let pid = appPID { kill(pid, SIGUSR1) }
        var deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: screens), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        let dumped = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: screens)))) as? [String: String] ?? [:])
            .reduce(into: [UUID: [UInt8]]()) { result, entry in
                if let id = UUID(uuidString: entry.key), let data = Data(base64Encoded: entry.value) { result[id] = Array(data) }
            }
        if let pid = appPID {
            kill(pid, SIGTERM)
            let gone = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0, Date() < gone { try? await Task.sleep(for: .milliseconds(50)) }
        }

        // The core's terminals, at the size the app gave them.
        let check = Board(socket: instance.socket, cards: cards, startPrograms: false, watching: true)
        _ = await check.start()
        deadline = Date().addingTimeInterval(10)
        while !check.isCurrent, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .seconds(1))

        var failures: [String] = []
        for (index, card) in agents.enumerated() {
            let tee = (try? Data(contentsOf: work.appendingPathComponent("tee-\(index)"))) ?? Data()
            guard let core = check.mirrors[card.id] else { continue }
            let size = core.withTerminal { ($0.cols, $0.rows) }
            let reference = Terminal(cols: size.0, rows: size.1)
            reference.feed(Array(tee))
            let expected = reference.snapshot()
            if core.withTerminal({ $0.snapshot() }) != expected {
                failures.append("agent \(index): the core's terminal differs from what the program wrote (\(tee.count) bytes)" + firstDifference(core, reference))
            }
            guard let shown = dumped[card.id] else {
                failures.append("agent \(index): the app had no terminal for it")
                continue
            }
            if shown != expected {
                let mirror = AgentSession(cols: size.0, rows: size.1)
                mirror.withTerminal { _ = $0.restore(shown) }
                failures.append("agent \(index): the app's terminal differs from what the program wrote" + firstDifference(mirror, reference))
            }
        }
        let statuses = check.link.client?.known ?? [:]
        for card in cards where statuses[card.id]?.processID != pids[card.id] {
            failures.append("\(card.record.name): its program changed from \(pids[card.id] ?? 0) to \(statuses[card.id]?.processID ?? 0)")
        }
        let lines = ((try? String(contentsOfFile: delivered, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        if lines != (0..<sent).map({ "message-\($0 + 1)" }) {
            let got = Set(lines)
            let missing = (1...max(1, sent)).filter { !got.contains("message-\($0)") }.prefix(10)
            failures.append("messages: sent \(sent), the program got \(lines.count); missing \(Array(missing)), repeated \(lines.count - got.count)")
        }
        if tally.count("failed") > 0 { failures.append("tool calls: \(tally.count("failed")) got no answer: \(tally.allNotes.prefix(3))") }
        if tally.count("refused") > 0 { failures.append("tool calls: \(tally.count("refused")) refused: \(tally.allNotes.prefix(3))") }
        say("tool calls answered \(tally.count("answered")), messages \(sent), agent output \(sizes().reduce(0, +) / 1024) KB, "
            + "app terminals checked \(dumped.count)")
        check.kill()
        return failures
    }

    /// Ends the core and its programs; the data folder goes too unless the run failed.
    func remove(keeping: Bool) {
        done.set()
        if let client = CoreClient.connect(socketPath: instance.socket, timeout: 3) { client.shutdown() }
        _ = shell("defaults delete AgentBoard '\(defaultsKey)'")
        if !keeping { instance.remove() }
    }
}

/// `./run --watch` on `bench`'s data folder, as a developer leaves it running.
func watch(_ bench: AppBench) -> Process? {
    let log = bench.instance.home.appendingPathComponent("run.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repository.appendingPathComponent("run").path, "--watch"]
    process.currentDirectoryURL = repository
    process.environment = MainActor.assumeIsolated { bench.appEnvironment }
    process.standardOutput = try? FileHandle(forWritingTo: log)
    process.standardError = process.standardOutput
    process.standardInput = FileHandle.nullDevice
    return (try? process.run()).map { process }
}

func stop(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
}

/// Touches a source file as saving it in an editor would.
func edit(_ path: String) -> Date {
    let now = Date()
    utimes(repository.appendingPathComponent(path).path, nil)
    return now
}

let boardSource = "Sources/AgentBoard/Board/WorktreeCanvas.swift"
let coreSource = "Sources/Orchestration/L10n.swift"

/// Scenarios 1 and 2 of GOAL.md with the real app: `./run --watch` rebuilds the board
/// `edits` times (the last edit is to the core's sources, so the core is replaced too), then
/// the board is killed with `kill -9` and launched again `kills` times. Edit to new board is
/// timed (target < 10 s).
@MainActor
func appRun(edits: Int, kills: Int, agentCount: Int) async -> Bool {
    let bench: AppBench
    do { bench = try AppBench(core: coreBinary, agentCount: agentCount, seed: seed) } catch {
        say("Couldn't make a data folder: \(error)")
        return false
    }
    say("app: \(agentCount) agents, \(edits) rebuilds, \(kills) kills, in \(bench.instance.home.path)")
    if let problem = await bench.prepare() {
        say("FAIL: \(problem)")
        return false
    }
    // Waits count boards from their launch on: not the ones that set the cards up.
    let watchStart = Date()
    let watching = watch(bench)
    defer { stop(watching) }
    guard let first = await bench.coreLog.boardAttached(to: bench.ids, after: watchStart, timeout: 600) else {
        say("FAIL: the app never showed every card; see run.log in \(bench.instance.home.path)")
        bench.remove(keeping: true)
        return false
    }
    say("the app shows every card (board \(first.board))")
    bench.begin()

    var failures: [String] = []
    var rebuilds: [Double] = []
    for index in 0..<edits {
        try? await Task.sleep(for: .seconds(3))
        let coreEdit = index == edits - 1
        let start = edit(coreEdit ? coreSource : boardSource)
        guard let attached = await bench.coreLog.boardAttached(to: bench.ids, after: start, timeout: 300) else {
            failures.append("rebuild \(index + 1): the new board never showed every card")
            break
        }
        let took = attached.at.timeIntervalSince(start)
        rebuilds.append(took)
        let tookOver = coreEdit && bench.coreLog.lines(after: start).contains { $0.contains("sessions over") }
        say(String(format: "rebuild %d (%@): edit to new board %.1f s%@", index + 1, coreEdit ? "core and board" : "board", took,
                   coreEdit ? (tookOver ? ", core replaced" : ", core NOT replaced") : ""))
        if coreEdit, !tookOver { failures.append("editing the core's sources didn't replace the core") }
    }
    stop(watching)

    // kill -9, then launched again by hand.
    let appBinary = repository.appendingPathComponent(".build/debug/AgentBoard")
    var relaunches: [Double] = []
    let launched = Date()
    var app = bench.launch(appBinary)
    if await bench.coreLog.boardAttached(to: bench.ids, after: launched, timeout: 60) == nil {
        failures.append("the app launched by hand never showed every card")
    }
    for index in 0..<kills {
        try? await Task.sleep(for: .seconds(2))
        if let pid = app?.processIdentifier { kill(pid, SIGKILL) }
        app?.waitUntilExit()
        let start = Date()
        app = bench.launch(appBinary)
        guard let attached = await bench.coreLog.boardAttached(to: bench.ids, after: start, timeout: 60) else {
            failures.append("kill \(index + 1): the relaunched board never showed every card")
            break
        }
        relaunches.append(attached.at.timeIntervalSince(start))
    }
    // The last board mirrors a good while of output, not just the screen it attached to.
    try? await Task.sleep(for: .seconds(15))
    failures += await bench.finish(app: app)

    say(String(format: "edit to new board: %@ (max %.1f s, target < 10 s)", rebuilds.map { String(format: "%.1f s", $0) }.joined(separator: ", "),
               rebuilds.max() ?? 0))
    say(String(format: "kill -9 to relaunched board showing every card: median %.2f s, max %.2f s", percentile(relaunches, 0.5), relaunches.max() ?? 0))
    if (rebuilds.max() ?? 0) >= 10 { failures.append("a rebuild took 10 s or more from edit to new board") }
    return report(failures, keeping: [bench])
}

/// Scenario 7 of GOAL.md: a stable build (a copy of this one, as an installed app would be)
/// runs agents on its own data folder while a dev instance of this checkout, under
/// `./run --watch` on another, is rebuilt, has its core replaced, killed with `kill -9` and
/// sent garbage. The stable board must never notice: same connection, same core, its agents
/// and their terminals untouched.
@MainActor
func sideBySide(agentCount: Int) async -> Bool {
    // The stable build: this one's app and core, copied away from the checkout.
    let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abstable-\(UUID().uuidString.prefix(8))")
    let built = repository.appendingPathComponent(".build/debug")
    for name in ["AgentBoard", "AgentBoardCore", "AgentBoard_AgentBoard.bundle", "AgentBoard_Orchestration.bundle"] {
        guard (try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.copyItem(at: built.appendingPathComponent(name), to: copy.appendingPathComponent(name))) != nil else {
            say("Couldn't copy \(name) of the build; build it first.")
            return false
        }
    }
    defer { try? FileManager.default.removeItem(at: copy) }
    let stableBench: AppBench, devBench: AppBench
    do {
        stableBench = try AppBench(core: copy.appendingPathComponent("AgentBoardCore"), agentCount: agentCount, seed: seed)
        devBench = try AppBench(core: coreBinary, agentCount: 2, seed: seed + 100)
    } catch {
        say("Couldn't make the data folders: \(error)")
        return false
    }
    say("side by side: stable in \(stableBench.instance.home.path), dev in \(devBench.instance.home.path)")
    for bench in [stableBench, devBench] {
        if let problem = await bench.prepare() {
            say("FAIL: \(problem)")
            return false
        }
    }
    let stableLaunch = Date()
    let stableApp = stableBench.launch(copy.appendingPathComponent("AgentBoard"))
    guard let stableBoard = await stableBench.coreLog.boardAttached(to: stableBench.ids, after: stableLaunch, timeout: 60) else {
        say("FAIL: the stable app never showed every card")
        stop(stableApp)
        return false
    }
    stableBench.begin()
    let stableCore = stableBench.coreLog.lines(after: .distantPast).last.flatMap(corePID)
    let devLaunch = Date()
    let watching = watch(devBench)
    defer { stop(watching) }
    guard await devBench.coreLog.boardAttached(to: devBench.ids, after: devLaunch, timeout: 600) != nil else {
        say("FAIL: the dev app never showed every card")
        stop(stableApp)
        return false
    }
    devBench.begin()
    let started = Date()

    var failures: [String] = []
    // Dev is rebuilt, then its core sources change (its core is replaced).
    for path in [boardSource, coreSource] {
        let start = edit(path)
        if await devBench.coreLog.boardAttached(to: devBench.ids, after: start, timeout: 300) == nil {
            failures.append("dev: the board rebuilt after editing \(path) never showed every card")
        } else {
            say("dev rebuilt after editing \(path)")
        }
        try? await Task.sleep(for: .seconds(2))
    }
    // A broken dev board: garbage on dev's socket.
    if let fd = connectUnix(devBench.instance.socket) {
        var garbage = [UInt8](repeating: 0, count: 64 * 1024)
        for index in garbage.indices { garbage[index] = UInt8.random(in: 0...255) }
        _ = garbage.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        say("dev: sent garbage to its core")
    }
    try? await Task.sleep(for: .seconds(2))
    // Dev's core dies: kill -9. Its board launches another (dev's agents end with it).
    let devCores = shellOutput("lsof -t -- '\(devBench.instance.socket)'").split(separator: "\n").compactMap { Int32($0) }
    for pid in devCores where shellOutput("ps -o command= -p \(pid)").contains("AgentBoardCore") { kill(pid, SIGKILL) }
    say("dev: killed its core (\(devCores.map(String.init).joined(separator: ", ")))")
    try? await Task.sleep(for: .seconds(5))
    stop(watching)
    devBench.remove(keeping: false)

    // Stable never noticed: its board stayed on the same connection to the same core.
    let stableLines = stableBench.coreLog.lines(after: started)
    if stableLines.contains(where: { $0.contains("went away") || $0.contains("connected") || $0.contains("took over") }) {
        failures.append("stable: its core saw boards come and go: \(stableLines.filter { $0.contains("board") }.prefix(3))")
    }
    if stableBench.coreLog.lines(after: .distantPast).last.flatMap(corePID) != stableCore {
        failures.append("stable: its core changed")
    }
    say("stable board \(stableBoard.board) kept its connection to core[\(stableCore.map(String.init) ?? "?")] throughout")
    failures += await stableBench.finish(app: stableApp)
    return report(failures, keeping: [stableBench])
}

private func corePID(_ line: String) -> Int32? {
    guard let word = line.split(separator: " ").dropFirst().first, word.hasPrefix("core["), word.hasSuffix("]") else { return nil }
    return Int32(word.dropFirst(5).dropLast())
}

@MainActor
private func report(_ failures: [String], keeping benches: [AppBench]) -> Bool {
    for bench in benches { bench.remove(keeping: !failures.isEmpty) }
    if failures.isEmpty {
        say("PASS")
        return true
    }
    for failure in failures { say("FAIL: \(failure)") }
    say("data kept in \(benches.map(\.instance.home.path).joined(separator: ", "))")
    return false
}

/// Runs `command` in sh; true if it succeeded.
func shell(_ command: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// A connection to the Unix socket at `path`, as any client makes one.
func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.utf8CString.withUnsafeBytes { buffer.copyBytes(from: $0.prefix(buffer.count - 1)) } }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}

func shellOutput(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// The core's log, read for when boards attach (`AGENTBOARD_CORE_VERBOSE=1`).
struct CoreLog {
    let url: URL
    private static let time: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func lines(after start: Date) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { line in
            guard let stamp = line.split(separator: " ").first, let date = Self.time.date(from: String(stamp)) else { return false }
            return date >= start
        }
    }

    /// The first board, connected after `start`, that attached to every session in `ids`, and
    /// when it attached the last one.
    @MainActor
    func boardAttached(to ids: Set<UUID>, after start: Date, timeout: Double) async -> (board: Int, at: Date)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var attached: [Int: Set<UUID>] = [:]
            for line in lines(after: start) {
                let words = line.split(separator: " ")
                // <time> core[pid] board <n> attached to <id>
                guard words.count == 7, words[2] == "board", words[4] == "attached", let board = Int(words[3]),
                      let id = UUID(uuidString: String(words[6])), ids.contains(id) else { continue }
                attached[board, default: []].insert(id)
                if attached[board] == ids, let date = Self.time.date(from: String(words[0])) { return (board, date) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
