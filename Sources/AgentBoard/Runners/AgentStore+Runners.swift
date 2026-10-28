import AgentRuntime
import Connections
import Foundation

/// What a runner card runs.
struct RunnerSpec: Hashable {
    /// A shell command line, run with the user's login shell.
    var command: String
    /// The folder it runs in: the worktree or a folder inside it.
    var directory: String
    /// The agent that started it, which may also close it; nil when the developer added it.
    var owner: UUID?
}

/// Runners: commands the board keeps running in a terminal card (dev servers, watchers, workers),
/// started by the developer or by an agent through the runner tools. The board shows what each
/// serves (ports, with the network address when other devices can reach it) and costs (CPU,
/// memory), and stops it with everything it started.
extension AgentStore {
    static let runnerProviderID = "runner"
    static let runnerSize = CGSize(width: 600, height: 340)
    /// How often running runners are measured.
    private static let sampleInterval: TimeInterval = 2

    func runners(in worktree: String) -> [AgentRecord] {
        agents.filter { $0.worktree == worktree && $0.runner != nil }
    }

    /// Adds a runner card and starts it. An `owner` agent gets a line to it.
    @discardableResult
    func addRunner(command: String, name: String?, directory: String?, owner: UUID?, to worktree: String,
                   at origin: CGPoint) -> AgentRecord {
        let base = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Self.runnerName(for: command)
        let record = AgentRecord(id: UUID(), worktree: worktree, providerID: Self.runnerProviderID,
                                 name: Self.uniqueName(base, among: agents(in: worktree)),
                                 frame: CGRect(origin: origin, size: Self.runnerSize),
                                 runner: RunnerSpec(command: command, directory: directory ?? worktree, owner: owner))
        appendRunner(record)
        if let owner { connect(owner, record.id) }
        startRunner(record.id)
        return record
    }

    /// Starts a runner that isn't running.
    func startRunner(_ id: UUID) {
        guard let record = record(id), record.runner != nil else { return }
        guard let session = sessions[id] else {
            runnersToStart.insert(id)
            _ = session(for: record, cols: Self.estimatedColumns(record.frame), rows: Self.estimatedRows(record.frame))
            return
        }
        guard session.processID == nil, session.state != .starting else { return }
        launch(record, in: session)
    }

    /// Stops a runner and everything it started; `completion` runs once it has exited.
    func stopRunner(_ id: UUID, then completion: (() -> Void)? = nil) {
        guard let session = sessions[id] else {
            completion?()
            return
        }
        session.terminate { [weak self] in
            self?.clearStats(id)
            self?.onRunnersChange?()
            completion?()
        }
    }

    /// Stops the runner if it runs and starts it again, with `command` instead when given.
    func restartRunner(_ id: UUID, command: String? = nil) {
        if let command { update(id) { $0.runner?.command = command } }
        stopRunner(id) { [weak self] in self?.startRunner(id) }
    }

    /// Where an agent's new runner goes: right of its card, below other cards in the way.
    func runnerOrigin(near caller: AgentRecord) -> CGPoint {
        var frame = CGRect(origin: CGPoint(x: caller.frame.maxX + 64, y: caller.frame.minY), size: Self.runnerSize)
        let others = agents(in: caller.worktree).map(\.frame)
        for _ in 0..<12 where others.contains(where: { $0.insetBy(dx: -16, dy: -16).intersects(frame) }) {
            frame.origin.y += frame.height + 32
        }
        return frame.origin
    }

    /// The addresses a runner serves, in port order: `localhost`, then the network address
    /// when the port is open to other devices.
    func urls(of id: UUID) -> [(local: String, network: String?)] {
        (runnerStats[id]?.ports ?? []).map { port in
            ("http://localhost:\(port.port)", port.exposed ? networkAddress.map { "http://\($0):\(port.port)" } : nil)
        }
    }

    /// The runner's latest output, scrollback included.
    func output(of id: UUID, lines: Int) -> [String] {
        sessions[id]?.withTerminal { $0.recentText(lines: lines) } ?? []
    }

    // MARK: Store internals

    func launchRunner(_ record: AgentRecord, _ runner: RunnerSpec, in session: AgentSession, searchPath: String) {
        guard FileManager.default.fileExists(atPath: runner.directory) else {
            session.fail(L("This folder no longer exists on disk."))
            return
        }
        // Markers of the app's own launcher (Claude Code) don't belong to the user's programs.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
        environment["PATH"] = searchPath
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        if runnerStarts[record.id] != nil {
            // Ran before: mark where the new run's output begins.
            session.withTerminal { terminal in
                terminal.feed((terminal.cursor.column == 0 ? "" : "\r\n") + "\u{1b}[2m── " + L("restarted") + " ──\u{1b}[0m\r\n")
            }
        }
        // What the last run served and cost no longer applies.
        clearStats(record.id)
        runnerStarts[record.id] = Date()
        session.start(LaunchSpec(executable: shell, arguments: ["-l", "-c", runner.command], environment: environment,
                                 directory: runner.directory))
        startMonitoring()
        onRunnersChange?()
    }

    func forgetRunner(_ id: UUID) {
        clearStats(id)
        runnerStarts[id] = nil
        runnersToStart.remove(id)
    }

    private func clearStats(_ id: UUID) {
        runnerStats[id] = nil
        runnerSamples[id] = nil
    }

    private func appendRunner(_ record: AgentRecord) {
        insert(record)
        bus.register(RunnerElement(id: record.id, store: self))
    }

    /// Measures running runners every few seconds; stops once none runs.
    private func startMonitoring() {
        guard runnerMonitor == nil else { return }
        networkAddress = ProcessInspector.networkAddress()
        runnerMonitor = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleRunners() }
        }
        // A server takes a moment to open its port: look once soon, not only after the interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sampleRunners() }
    }

    func sampleRunners() {
        var roots: [UUID: pid_t] = [:]
        for record in agents where record.runner != nil {
            if let pid = sessions[record.id]?.processID { roots[record.id] = pid }
        }
        guard !roots.isEmpty else {
            runnerMonitor?.invalidate()
            runnerMonitor = nil
            if !runnerStats.isEmpty || !runnerSamples.isEmpty {
                runnerStats = [:]
                runnerSamples = [:]
                onRunnersChange?()
            }
            return
        }
        let previous = runnerSamples
        Task { [weak self] in
            let (samples, address) = await Task.detached(priority: .utility) {
                (ProcessInspector.sample(roots, previous: previous), ProcessInspector.networkAddress())
            }.value
            self?.received(samples, address: address, for: roots)
        }
    }

    private func received(_ samples: [UUID: ProcessInspector.Sample], address: String?, for roots: [UUID: pid_t]) {
        // Runners that stopped while being measured drop out.
        let live = samples.filter { sessions[$0.key]?.processID == roots[$0.key] }
        runnerSamples = live
        networkAddress = address
        let stats = live.mapValues(\.stats)
        guard stats != runnerStats else { return }
        runnerStats = stats
        onRunnersChange?()
    }

    /// A card name from a command: the script of `npm run dev` (dev), else the program's name.
    static func runnerName(for command: String) -> String {
        let words = command.split(separator: " ").map(String.init).filter { !$0.contains("=") }
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return "Runner" }
        if ["npm", "pnpm", "yarn", "bun", "deno"].contains(first), words.count > 1 {
            let rest = words.dropFirst().filter { !$0.hasPrefix("-") }
            return (rest.first == "run" ? rest.dropFirst().first : rest.first) ?? first
        }
        return first
    }

    /// Terminal size before the board has measured the card: close enough for a program to start.
    private static func estimatedColumns(_ frame: CGRect) -> Int { max(20, Int((frame.width - 24) / 7.2)) }
    private static func estimatedRows(_ frame: CGRect) -> Int { max(4, Int((frame.height - 80) / 15)) }
}

/// A runner as the message bus sees it: reachable along lines, driven with the runner tools.
@MainActor
final class RunnerElement: BoardElement {
    let id: UUID
    private weak var store: AgentStore?

    init(id: UUID, store: AgentStore) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .runner }

    var detail: String? {
        guard let command = store?.record(id)?.runner?.command else { return nil }
        return "runs `\(command)`"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
