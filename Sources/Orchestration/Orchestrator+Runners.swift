import AgentRuntime
import Connections
import Foundation

/// Runners: commands kept running in a terminal card (dev servers, watchers, workers), started
/// by the developer or by an agent through the runner tools. The core measures what each serves
/// (ports, with the network address when other devices can reach it) and costs (CPU, memory),
/// and stops it with everything it started.
extension Orchestrator {
    /// How often running runners are measured.
    private static let sampleInterval: TimeInterval = 2

    /// Adds a runner card and starts it. An `owner` agent gets a line to it.
    @discardableResult
    func addRunner(command: String, name: String?, directory: String?, owner: UUID?, to worktree: String,
                   at origin: CGPoint) -> AgentRecord {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = trimmed.isEmpty ? AgentRecord.runnerName(for: command) : trimmed
        let record = AgentRecord(id: UUID(), worktree: worktree, providerID: AgentRecord.runnerProviderID,
                                 name: AgentRecord.uniqueName(base, among: cards(in: worktree)),
                                 frame: CGRect(origin: origin, size: AgentRecord.runnerSize),
                                 runner: RunnerSpec(command: command, directory: directory ?? worktree, owner: owner),
                                 // Shown with the agent that started it.
                                 organization: owner.flatMap { self.record($0)?.organization })
        insert(record)
        if let owner { bus.connect(owner, record.id) }
        startRunner(record.id)
        return record
    }

    /// Starts a runner that isn't running.
    func startRunner(_ id: UUID) {
        guard let record = record(id), record.runner != nil else { return }
        guard let session = session(id) else {
            server.openSession(id, cols: Self.estimatedColumns(record.frame), rows: Self.estimatedRows(record.frame), for: nil)
            return launch(id)
        }
        guard session.processID == nil else { return }
        launch(id)
    }

    /// Stops a runner and everything it started; `completion` runs once it has exited.
    func stopRunner(_ id: UUID, then completion: (() -> Void)? = nil) {
        guard let session = session(id) else {
            completion?()
            return
        }
        session.terminate { [weak self] in
            self?.clearStats(id)
            self?.runnersChanged()
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
        origin(near: caller, size: AgentRecord.runnerSize)
    }

    /// Where a card of `size` an agent adds goes: right of its card, below other cards in the way.
    func origin(near caller: AgentRecord, size: CGSize) -> CGPoint {
        var frame = CGRect(origin: CGPoint(x: caller.frame.maxX + 64, y: caller.frame.minY), size: size)
        let others = frames(in: caller.worktree)
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
        session(id)?.withTerminal { $0.recentText(lines: lines) } ?? []
    }

    // MARK: Internals

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
        // As for agents: a runner running `./run` must not reach this core.
        for key in environment.keys where key.hasPrefix("AGENTBOARD_") { environment[key] = nil }
        let shell = environment["SHELL"] ?? "/bin/zsh"
        if runnerStarts[record.id] != nil {
            // Ran before: mark where the new run's output begins.
            session.annotate("\u{1b}[2m── " + L("restarted") + " ──\u{1b}[0m\r\n", freshLine: true)
        }
        // What the last run served and cost no longer applies.
        clearStats(record.id)
        runnerStarts[record.id] = Date()
        session.start(LaunchSpec(executable: shell, arguments: ["-l", "-c", runner.command], environment: environment,
                                 directory: runner.directory))
        startMonitoring()
        runnersChanged()
    }

    func forgetRunner(_ id: UUID) {
        clearStats(id)
        runnerStarts[id] = nil
        runnersChanged()
    }

    private func clearStats(_ id: UUID) {
        runnerStats[id] = nil
        runnerSamples[id] = nil
    }

    /// Tells the boards what the runners serve and cost, when that changed.
    func runnersChanged() {
        var report = RunnerReport()
        report.stats = runnerStats
        report.starts = runnerStarts
        report.networkAddress = networkAddress
        guard report != reportedRunners else { return }
        reportedRunners = report
        broadcast(.runners(report))
    }

    /// Measures running runners every few seconds; stops once none runs.
    func startMonitoring() {
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
        for record in cards where record.runner != nil {
            if let pid = session(record.id)?.processID { roots[record.id] = pid }
        }
        guard !roots.isEmpty else {
            runnerMonitor?.invalidate()
            runnerMonitor = nil
            if !runnerStats.isEmpty || !runnerSamples.isEmpty {
                runnerStats = [:]
                runnerSamples = [:]
                runnersChanged()
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
        let live = samples.filter { session($0.key)?.processID == roots[$0.key] }
        runnerSamples = live
        networkAddress = address
        runnerStats = live.mapValues(\.stats)
        runnersChanged()
    }

    /// Terminal size before a board has measured the card: close enough for a program to start.
    static func estimatedColumns(_ frame: CGRect) -> Int { max(20, Int((frame.width - 24) / 7.2)) }
    static func estimatedRows(_ frame: CGRect) -> Int { max(4, Int((frame.height - 80) / 15)) }
}
