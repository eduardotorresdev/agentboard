import AgentRuntime
import Connections
import Foundation
import Observation
import Orchestration

/// The board's view of the terminal cards (agents and runners), their live sessions, and the
/// lines between elements. The core keeps all of it (see `Orchestrator`): this mirrors the cards
/// and lines, sends the user's changes, and mirrors each session once its card is first shown.
/// Sessions keep running while the user looks at other worktrees, and while no board runs.
///
/// Connected agents message each other through the core's tool server: each agent is launched
/// with it as an MCP server, and a message reaches its recipient typed into their terminal.
@MainActor
@Observable
final class AgentStore {
    private(set) var agents: [AgentRecord] = []
    /// Lines between elements, in the order they were drawn.
    private(set) var connections: [Connection] = []
    /// Post-its (see AgentStore+PostIts.swift).
    var postIts: [PostItRecord] = []
    /// Images (see AgentStore+Images.swift).
    var images: [ImageRecord] = []
    /// Where pictures are stored: the folder the core shares. For another host, this Mac's copy
    /// of that host's pictures (see AgentStore+Images.swift).
    @ObservationIgnored var dataFolder = DataFolder.url
    /// The host's own data folder, asked once (`agentboard data-folder`); tests give their own.
    @ObservationIgnored var hostDataFolder: String?
    /// The host's pictures on their way here or that couldn't come, by file name, with what the
    /// card says meanwhile.
    @ObservationIgnored var mediaNotes: [String: String] = [:]
    /// Called with the file name when a host's picture arrived or couldn't, so the board redraws its card.
    @ObservationIgnored var onMediaChange: ((String) -> Void)?
    /// Pictures still on their way to the host, by file: their cards wait, dimmed, with a spinner.
    @ObservationIgnored var sendingMedia: Set<String> = []
    /// The user's unsent annotations, by image.
    @ObservationIgnored var imageMarks: [UUID: ImageMarks] = [:]
    /// The agent annotations were last sent to: the one offered next time.
    var lastMarkedAgent: UUID?
    /// A card's note or waiting changed; its picture didn't.
    @ObservationIgnored var onMediaNote: ((String) -> Void)?
    /// Called each time the host's core answers (see `HostStores`).
    @ObservationIgnored var onConnect: (() -> Void)?
    /// The card streams this board serves (StreamServer), told to the core on every connection
    /// so it can answer a remote board's `streamTicket`.
    @ObservationIgnored var servedStreams: (port: Int, token: String)? {
        didSet { if let streams = servedStreams { send(.servesStreams(port: streams.port, token: streams.token)) } }
    }
    /// Agents waiting on the developer, in every organization, oldest first.
    private(set) var attention: [AttentionRequest] = []
    /// What agents asked the developer, oldest first. One the agent closed with an echo stays
    /// a while as `closed`, so the echo can be read.
    private(set) var decisions: [Decision] = [] { didSet { onDecisionsChange?() } }
    @ObservationIgnored var onDecisionsChange: (() -> Void)?
    private(set) var pendingAnswers: [UUID: PendingAnswer] = [:]
    /// Questions answered so far in each agent's current run, for “2 of 3”.
    private var answeredInRun: [UUID: Int] = [:]
    /// How long a closed decision's echo stays on the board.
    static let echoLinger: TimeInterval = 8
    /// Messages held behind the text the user typed in an agent's terminal, by agent.
    var heldMessages: [UUID: Int] = [:]
    /// Why the core gave a composer prompt back, by agent: shown in its composer.
    var composerNotices: [UUID: String] = [:]
    /// Files being sent to the host from an agent's composer or terminal, by agent: shown under its composer.
    var uploads: [UUID: [Upload]] = [:] {
        didSet { for id in Set(oldValue.keys).union(uploads.keys) { ComposerDrafts.setUploads(uploads[id]?.count ?? 0, for: id) } }
    }
    /// False until the core has said which cards there are.
    private(set) var isLoaded = false
    /// Why the cards can't be shown, when the core runs another build this one can't talk to.
    private(set) var notice: String?
    /// The organization shown: only its cards are on the canvas, and new ones join it.
    var organizationID: UUID = OrganizationHome.defaultID
    @ObservationIgnored private(set) var sessions: [UUID: AgentSession] = [:]
    /// Called with the card's id when an observed session changes, so the board redraws it.
    @ObservationIgnored var onSessionChange: ((UUID) -> Void)?
    /// Who is showing each session, and what each wants called when it changes; a session stays
    /// observed while anyone shows it.
    @ObservationIgnored private var viewers: [UUID: [ObjectIdentifier: () -> Void]] = [:]
    /// Called after a message travels along a line, so the board can show it.
    @ObservationIgnored var onMessage: ((Message) -> Void)?

    /// The line to the process that runs the cards' programs and keeps the cards, the lines and
    /// the agents' tools, so they outlive this one (see `CoreServer`). It reconnects by itself
    /// when that process goes away.
    @ObservationIgnored private let link: CoreLink
    /// A core in this process, when the real one couldn't be reached: programs then end with
    /// the board.
    @ObservationIgnored private var local: InProcessCore?
    /// Sessions that mirror the core's, on the connection they were last attached on.
    /// By the number of the connection (`connection`): a client's address can be reused by the
    /// next one, so it can't tell connections apart.
    @ObservationIgnored private var hosted: [UUID: Int] = [:]
    /// Counts the connections to a core, the current one last.
    @ObservationIgnored private var connection = 0
    /// No core could be reached or started at all.
    @ObservationIgnored private var isUnavailable = false
    /// Replacing a core of an older build with this build's is under way, or failed.
    @ObservationIgnored private var replacedCore = false
    /// Runs the browser tools agents call through the core.
    @ObservationIgnored var browserTools: BrowserTools?
    /// Runs the simulator tools agents call through the core.
    @ObservationIgnored var simulatorTools: SimulatorTools?
    @ObservationIgnored var projectTools: ProjectTools?
    /// Where the board's other elements come from (browsers, file trees), by family; the core
    /// keeps lines to them.
    @ObservationIgnored var elementSources: [String: () -> [ElementInfo]] = [:]
    /// Removes one of those elements, by family; each ignores ids that aren't its own.
    @ObservationIgnored var elementRemovers: [String: (UUID) -> Void] = [:]
    /// Removals agents asked for that wait for the user's answer, oldest first (see `RemovalDialog`).
    private(set) var removalRequests: [RemovalRequest] = []

    /// A sample request, to look at the dialog (`AGENTBOARD_SHOW=removal-dialog`).
    func showSampleRemoval() {
        removalRequests.append(RemovalRequest(asker: "Ada", items: [("agent", "Reviewer"), ("postit", "Plan"), ("image", "Checkout screen"), ("connection", "Ada - Dev server")]) { _ in })
    }

    /// The user's answer to the oldest request.
    func answerRemoval(_ allowed: Bool) {
        guard !removalRequests.isEmpty else { return }
        removalRequests.removeFirst().answer(allowed)
    }

    /// The removal tools the core leaves to the board: asking the user, and removing its own elements.
    private func removalCall(_ name: String, _ arguments: [String: Any]) async -> ToolResult {
        switch name {
        case "board_confirm_removal":
            let items = (arguments["items"] as? [[String: String]] ?? []).map { (kind: $0["kind"] ?? "", name: $0["name"] ?? "") }
            guard !items.isEmpty else { return .error("Nothing to confirm.") }
            let allowed = await withCheckedContinuation { done in
                removalRequests.append(RemovalRequest(asker: arguments["asker"] as? String ?? "", items: items) { done.resume(returning: $0) })
            }
            return .text(allowed ? "allowed" : "refused")
        case "board_remove":
            for id in (arguments["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)) {
                elementRemovers.values.forEach { $0(id) }
            }
            return .text("removed")
        default:
            return .error("This board can't run “\(name)”.")
        }
    }

    func elements() -> [ElementInfo] {
        elementSources.keys.sorted().flatMap { elementSources[$0]?() ?? [] }
    }

    // Runners (see AgentStore+Runners.swift).
    /// What each running runner serves and costs, and when it started, as the core measures it.
    @ObservationIgnored var runnerReport = RunnerReport() {
        didSet {
            let running = Set(runnerReport.starts.keys)
            if running != runningRunners { runningRunners = running }
        }
    }
    /// Each card's last session status as the core reported it; the sidebar reads it.
    private(set) var statuses: [UUID: SessionStatus] = [:]
    /// The runners running now. Observed, unlike the report, whose stats change every second.
    private(set) var runningRunners: Set<UUID> = []
    /// Runners to start when their session is created; the others come back stopped.
    @ObservationIgnored var runnersToStart: Set<UUID> = []
    /// Called when runner stats or states change, so the board redraws their cards.
    @ObservationIgnored var onRunnersChange: (() -> Void)?

    /// The host whose core this mirrors (see docs/hosts.md); nil for this Mac's. Another host's
    /// core is only ever connected to: never launched, replaced, run in this process or shut down.
    @ObservationIgnored let host: (id: UUID, name: String)?
    /// The host's machine stats, as its core last reported them; nil for this Mac and while
    /// the host doesn't answer.
    private(set) var hostStats: HostStats?
    /// How the host was last reached, straight or through the account server's relay.
    var hostPath: HostChannel.Path?
    /// Why the host can't be reached, when it is more than being offline (see `HostStores`).
    @ObservationIgnored var downReason: (() -> String?)?

    /// `database`: where a core in this process keeps the cards (the data folder's by default).
    /// `connect` finds the core (the one next to this executable by default; another in tests).
    init(database: URL? = nil, connect: (@Sendable () -> Result<CoreClient, CoreClient.Failure>)? = nil,
         host: (id: UUID, name: String)? = nil) {
        self.host = host
        if let host { dataFolder = DataFolder.url.appendingPathComponent("hosts/\(host.id.uuidString)", isDirectory: true) }
        link = CoreLink(connect: connect ?? { AgentStore.connectCore() })
        if host != nil {
            // Over the network: slower to retry, quicker to say the host can't be reached.
            link.retryInterval = 5
            link.patience = 2
        }
        link.onConnect = { [weak self] client, state, waiting in self?.connected(client, state.applying(waiting)) }
        link.onEvent = { [weak self] event in self?.received(event) }
        link.onDown = { [weak self] in self?.coreDown() }
        link.onIncompatible = { [weak self] core in self?.incompatible(core) }
        Task {
            let started = host != nil ? await link.start(retrying: true) : await link.start { [weak self] in
                self?.local = try? InProcessCore(database: database)
                return self?.local?.socketPath
            }
            if !started { unavailable() }
        }
    }


    var core: CoreClient? { link.client }

    /// Runs a program on the store's machine through its core, giving a core that is still
    /// connecting a few seconds; nil when it can't be reached.
    /// On another host: what sends more than `HostFiles.bulkBytes`, or is `bulk` (a lot comes
    /// back), goes over `bulkRun`'s connection, so keys and screens never wait behind it; and an
    /// answer is waited for `patience` seconds (nil: by what is sent), then given up on as
    /// `HostFiles.unanswered`.
    func run(_ executable: String, _ arguments: [String], input: Data? = nil, bulk: Bool = false, patience: Double? = nil) async -> CoreClient.Ran? {
        let deadline = Date().addingTimeInterval(8)
        while core == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard host != nil else { return await core?.run(executable, arguments, input: input) }
        let size = input?.count ?? 0
        let apart = bulk || size > HostFiles.bulkBytes ? bulkRun : nil
        let answered = await HostFiles.within(patience ?? HostFiles.patience(sending: size)) { [weak self] () -> CoreClient.Ran? in
            // No connection of its own to be had: the one there is.
            if let apart, let ran = await apart(executable, arguments, input) { return ran }
            return await self?.core?.run(executable, arguments, input: input)
        }
        return answered ?? HostFiles.unanswered
    }

    /// Runs a program on the store's host over a connection apart from the store's own, opened
    /// when needed; the outer nil when there is none to be had.
    @ObservationIgnored var bulkRun: (@Sendable (String, [String], Data?) async -> CoreClient.Ran??)?

    /// The host's files, for what reads a worktree's folder; nil on this Mac, whose disk is
    /// read as it always was.
    var files: HostFiles? {
        guard host != nil else { return nil }
        return HostFiles(run: { [weak self] executable, arguments, input in await self?.run(executable, arguments, input: input) },
                         carry: { [weak self] executable, arguments, input, bulk, patience in
                             await self?.run(executable, arguments, input: input, bulk: bulk, patience: patience)
                         })
    }

    /// The core next to this executable, launched if it isn't running. `AGENTBOARD_LOCAL=1`
    /// skips it, as bench builds do: programs then run in this process and end with it.
    nonisolated private static func connectCore() -> Result<CoreClient, CoreClient.Failure> {
        #if BENCH
        return .failure(.noCore)
        #else
        guard ProcessInfo.processInfo.environment["AGENTBOARD_LOCAL"] != "1", let executable = coreExecutable else { return .failure(.noCore) }
        let result = CoreClient.open(launching: executable)
        if case .failure(let failure) = result { NSLog("AgentBoard: no core at \(CoreProtocol.socketPath): \(failure)") }
        return result
        #endif
    }

    nonisolated private static var coreExecutable: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentBoardCore")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// The core runs a build this one can't talk to. An older one is replaced with this build's,
    /// which takes its programs over; a newer one is the user's to open.
    private func incompatible(_ core: CoreProtocol.Versions) {
        if let host {
            return show(core.version < CoreProtocol.oldest
                ? L("\(host.name) runs an older version this app can't talk to. Update it to see its agents.")
                : L("\(host.name) runs a newer version. Update this app to see its agents."))
        }
        guard core.version < CoreProtocol.oldest else {
            return show(L("Your agents run on a newer build. Open that build to see them."))
        }
        // Once: if it can't hand over, saying so is all that's left.
        guard !replacedCore, let executable = Self.coreExecutable else { return }
        replacedCore = true
        NSLog("AgentBoard: the core speaks \(core.version), older than this build; replacing it")
        Task.detached(priority: .userInitiated) {
            let replace = Process()
            replace.executableURL = executable
            replace.arguments = ["--take-over"]
            let replaced = (try? replace.run()).map { replace.waitUntilExit(); return replace.terminationStatus == 0 } ?? false
            guard !replaced else { return }
            await MainActor.run {
                self.show(L("Your agents run on an older build that can't hand them over to this one. Open that build to carry on with them."))
            }
        }
    }

    private func show(_ message: String) {
        notice = message
        for session in sessions.values { session.fail(message) }
    }

    /// The core answered, for the first time or again after going away: take its cards and
    /// lines, and mirror its sessions. A core that restarted without the programs starts again
    /// the ones that were running.
    private func connected(_ client: CoreClient, _ state: BoardState) {
        connection += 1
        // What couldn't be fetched while the host was away is tried again.
        mediaNotes = [:]
        notice = nil
        replacedCore = false
        agents = state.cards
        postIts = state.postIts ?? []
        images = state.images ?? []
        attention = state.attention ?? []
        decisions = state.decisions ?? []
        settleDecisions()
        connections = state.connections
        runnerReport = state.runners
        isLoaded = true
        statuses = client.known
        client.onStatus = { [weak self] id, status in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.statuses[id] = status } }
        }
        client.subscribeToStatuses()
        client.onHost = { [weak self] stats in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hostStats = stats } }
        }
        if host != nil { client.subscribeToHost() }
        onConnect?()
        client.send(.elements(elements()))
        if let streams = servedStreams { client.send(.servesStreams(port: streams.port, token: streams.token)) }
        for (id, session) in sessions {
            guard let record = record(id) else {
                sessions[id] = nil
                continue
            }
            begin(record, in: session, on: client)
        }
        onRunnersChange?()
    }

    /// The core has been gone a while: say so on every card until it is back.
    private func coreDown() {
        guard let host else {
            NSLog("AgentBoard: the core stopped; reconnecting")
            for session in sessions.values { session.fail(L("Lost the process that runs the agents. Reconnecting…")) }
            return
        }
        // Its agents keep running there; cards shown meanwhile say the same (see `session(for:)`).
        hostStats = nil
        saidDown = downNote(host.name)
        show(saidDown ?? "")
    }

    /// The last thing `coreDown` showed.
    @ObservationIgnored private var saidDown: String?

    private func downNote(_ name: String) -> String {
        downReason?() ?? L("Can't reach \(name). Its agents keep running there; reconnecting…")
    }

    /// Says again why the host can't be reached, when that changed.
    func explainDown() {
        // Only over its own words: a core of another build says something else.
        guard let host, notice != nil, notice == saidDown, core == nil, downNote(host.name) != notice else { return }
        coreDown()
    }

    /// Connects to the host again, onto a better path that just opened.
    func reconnect() { link.reconnectNow() }

    private func unavailable() {
        isUnavailable = true
        isLoaded = true
        for session in sessions.values { session.fail(L("Couldn't start the process that runs the agents.")) }
    }

    func received(_ event: BoardEvent) {
        switch event {
        case .streamTicket:
            // For boards that show another host's cards; this one serves its own.
            return
        case .cardAdded(let record):
            guard self.record(record.id) == nil else { return }
            agents.append(record)
        case .cardUpdated(let record):
            guard let index = agents.firstIndex(where: { $0.id == record.id }) else { return }
            agents[index] = record
        case .cardRemoved(let id):
            forget(id)
        case .connections(let list):
            connections = list
        case .message(let message):
            onMessage?(message)
        case .runners(let report):
            runnerReport = report
            onRunnersChange?()
        case .postItAdded(let record):
            guard postIt(record.id) == nil else { return }
            postIts.append(record)
        case .postItUpdated(let record):
            guard let index = postIts.firstIndex(where: { $0.id == record.id }) else { return }
            postIts[index] = record
        case .postItRemoved(let id):
            postIts.removeAll { $0.id == id }
            connections.removeAll { $0.touches(id) }
        case .imageAdded(let record):
            guard image(record.id) == nil else { return }
            images.append(record)
        case .imageUpdated(let record):
            guard let index = images.firstIndex(where: { $0.id == record.id }) else { return }
            images[index] = record
        case .imageRemoved(let id):
            forgetHostMedia(of: id)
            imageMarks[id] = nil
            ImageMarks.forget(id)
            images.removeAll { $0.id == id }
            connections.removeAll { $0.touches(id) }
        case .attention(let list):
            attention = list
        case .decisions(let list):
            let lingering = decisions.filter { old in old.state == .closed && !list.contains { $0.id == old.id } }
            decisions = lingering + list.filter { $0.state != .closed || $0.echo != nil }
            for closed in list where closed.state == .closed && closed.echo != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.echoLinger) { [weak self] in
                    self?.decisions.removeAll { $0.id == closed.id }
                }
            }
            settleDecisions()
        case .held(let id, let count):
            heldMessages[id] = count == 0 ? nil : count
        case .promptReturned(let id, let text, let reason):
            ComposerDrafts.restore(text, for: id)
            composerNotices[id] = L("Not sent: \(reason).")
        case .toolCall(let call, let name, let arguments, let caller):
            let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
            Task {
                let result: ToolResult? = name.hasPrefix("board_") ? await removalCall(name, parsed)
                    : name.hasPrefix("project_") || name.hasPrefix("worktree_") || name.hasPrefix("host_")
                    ? await projectTools?.call(name, arguments: parsed, caller: caller)
                    : name.hasPrefix("simulator_") ? await simulatorTools?.call(name, arguments: parsed, caller: caller)
                    : await browserTools?.call(name, arguments: parsed, caller: caller)
                link.send(.toolResult(call: call, result: WireToolResult(result
                    ?? .error("This board can't run “\(name)”."))))
            }
        }
    }

    /// Sends a change to the core, now or once it is back.
    /// Whether the core speaks the composer's `prompt` (protocol 6).
    var coreTakesPrompts: Bool { (link.client?.version ?? 0) >= 6 }

    func send(_ request: BoardRequest) {
        guard !isUnavailable else { return }
        link.send(request)
    }

    // MARK: Decisions

    /// The last answer of an agent's questions, held for the undo window before the core hears it.
    struct PendingAnswer: Equatable {
        let decision: UUID
        let answer: Decision.Answer
        var secondsLeft: Int
    }

    /// Where the user is in an agent's questions: the one to show and its place in the run.
    struct DecisionSequence: Equatable {
        var shown: Decision
        var position: Int
        var total: Int
        /// Still the user's to answer (or to undo), as opposed to sent and waiting on the agent.
        var isWaiting: Bool
    }

    /// An agent's decisions read as one run of questions: the oldest unanswered, else the answer
    /// in its undo window, else an answer the agent still has to echo.
    func decisionSequence(of agent: UUID) -> DecisionSequence? {
        let mine = decisions.filter { $0.agent == agent }
        let pending = pendingAnswers[agent]
        let unanswered = mine.filter { $0.state == .open && $0.answer == nil && $0.id != pending?.decision }
        let done = answeredInRun[agent] ?? 0
        if let next = unanswered.first {
            return DecisionSequence(shown: next, position: done + 1, total: done + unanswered.count, isWaiting: true)
        }
        if let held = mine.first(where: { $0.id == pending?.decision }) {
            return DecisionSequence(shown: held, position: max(done, 1), total: max(done, 1), isWaiting: true)
        }
        // OK and a picked alternative need nothing more from the agent: their balloon leaves at once.
        let echoing = mine.last { decision in
            if decision.echo != nil { return true }
            switch decision.answer {
            case .redirect, .useRecommended: return true
            default: return false
            }
        }
        return echoing.map { DecisionSequence(shown: $0, position: max(done, 1), total: max(done, 1), isWaiting: false) }
    }

    /// The user's answer. With more questions of the agent waiting it goes to the core at once
    /// and the next one shows; the last one waits out the undo window first.
    func answer(_ decision: Decision, _ answer: Decision.Answer) {
        guard decisions.contains(where: { $0.id == decision.id && $0.state == .open && $0.answer == nil }),
              pendingAnswers[decision.agent] == nil else { return }
        answeredInRun[decision.agent, default: 0] += 1
        if decisions.contains(where: { $0.agent == decision.agent && $0.id != decision.id && $0.state == .open && $0.answer == nil }) {
            commit(decision.id, answer)
        } else {
            pendingAnswers[decision.agent] = PendingAnswer(decision: decision.id, answer: answer, secondsLeft: DecisionMetrics.undoSeconds)
            countDown(decision.agent, decision.id)
        }
    }

    /// Takes back the answer in its undo window: the question shows again.
    func undoAnswer(of agent: UUID) {
        guard pendingAnswers.removeValue(forKey: agent) != nil else { return }
        answeredInRun[agent] = (answeredInRun[agent] ?? 1) - 1
        onDecisionsChange?()
    }

    /// Ends the undo window now: the core hears the answer.
    func confirmAnswer(of agent: UUID) {
        guard let pending = pendingAnswers.removeValue(forKey: agent) else { return }
        commit(pending.decision, pending.answer)
    }

    /// Sends the answer and shows it as given before the core says so, so the next question
    /// takes over without a gap.
    private func commit(_ id: UUID, _ answer: Decision.Answer) {
        send(.answerDecision(id: id, answer: answer))
        guard let index = decisions.firstIndex(where: { $0.id == id }) else { return }
        decisions[index].answer = answer
    }

    /// The window lives here, not in a view: it closes whatever happens to the screen.
    private func countDown(_ agent: UUID, _ decision: UUID) {
        onDecisionsChange?()
        Task { @MainActor [weak self] in
            while let pending = self?.pendingAnswers[agent], pending.decision == decision {
                guard pending.secondsLeft > 0 else { self?.confirmAnswer(of: agent); return }
                try? await Task.sleep(for: .seconds(1))
                guard self?.pendingAnswers[agent]?.decision == decision else { return }
                self?.pendingAnswers[agent]?.secondsLeft -= 1
            }
        }
    }

    /// After the core's list changed: a question that arrived during the undo window is just the
    /// next one, so the held answer goes now; one whose decision is gone is dropped.
    private func settleDecisions() {
        for (agent, pending) in pendingAnswers {
            if !decisions.contains(where: { $0.id == pending.decision && $0.state == .open && $0.answer == nil }) {
                pendingAnswers[agent] = nil
            } else if decisions.contains(where: { $0.agent == agent && $0.id != pending.decision && $0.state == .open && $0.answer == nil }) {
                confirmAnswer(of: agent)
            }
        }
        for agent in answeredInRun.keys where !decisions.contains(where: { $0.agent == agent }) { answeredInRun[agent] = nil }
    }

    /// Tells the core the board's other elements changed (a browser added, removed, renamed…).
    func elementsChanged() {
        guard link.isConnected else { return }
        send(.elements(elements()))
    }

    /// Ends every card's program as the app quits; a board that is killed or rebuilt instead
    /// leaves them running on the core, to attach to next launch.
    func quit() {
        // Another host's agents keep running there: only hang up.
        guard host == nil else { return link.close() }
        core?.shutdown()
    }

    func agents(in worktree: String) -> [AgentRecord] {
        agents.filter { $0.worktree == worktree && $0.organizationID == organizationID }
    }

    func record(_ id: UUID) -> AgentRecord? {
        agents.first { $0.id == id }
    }

    @discardableResult
    func add(_ provider: any AgentProvider, to worktree: String, at origin: CGPoint) -> AgentRecord {
        let record = AgentRecord(id: UUID(), worktree: worktree, providerID: provider.id,
                                 name: AgentRecord.uniqueName(provider.title, among: agents(in: worktree)),
                                 frame: CGRect(origin: origin, size: CGSize(width: 640, height: 420)),
                                 organization: organizationID)
        insert(record)
        return record
    }

    /// Adds a card built elsewhere (a runner).
    func insert(_ record: AgentRecord) {
        agents.append(record)
        send(.addCard(record))
    }

    func remove(_ id: UUID) {
        forget(id)
        send(.removeCard(id))
    }

    /// Drops the card here; the core ends its program.
    private func forget(_ id: UUID) {
        if sessions.removeValue(forKey: id) != nil { core?.unregister(id) }
        viewers[id] = nil
        attention.removeAll { $0.id == id }
        decisions.removeAll { $0.agent == id }
        statuses[id] = nil
        hosted[id] = nil
        runnersToStart.remove(id)
        agents.removeAll { $0.id == id }
        connections.removeAll { $0.touches(id) }
    }

    // MARK: Connections

    /// The lines between cards of `worktree`; `elements` are its other cards (browsers…).
    func connections(in worktree: String, elements: Set<UUID> = []) -> [Connection] {
        let ids = Set(agents(in: worktree).map(\.id)).union(postIts(in: worktree).map(\.id))
            .union(images(in: worktree).map(\.id)).union(elements)
        return connections.filter { ids.contains($0.a) && ids.contains($0.b) }
    }

    @discardableResult
    func connect(_ a: UUID, _ b: UUID, sides: (Side?, Side?) = (nil, nil)) -> Connection? {
        guard a != b, !connections.contains(where: { $0.joins(a, b) }) else { return nil }
        let connection = Connection(a: a, b: b, aSide: sides.0, bSide: sides.1)
        connections.append(connection)
        send(.connect(connection))
        return connection
    }

    func disconnect(_ id: UUID) {
        connections.removeAll { $0.id == id }
        send(.disconnect(id))
    }

    /// Lines touching an element the board removed (a browser) go with it.
    func dropConnections(touching id: UUID) {
        connections.removeAll { $0.touches(id) }
    }

    /// Moves the card to the top of the stack.
    func raise(_ id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }), index != agents.count - 1 else { return }
        agents.append(agents.remove(at: index))
    }

    /// Renames the card, numbered if another in its worktree has the name.
    func rename(_ id: UUID, to name: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }), agents[index].name != name else { return }
        let others = agents.filter { $0.worktree == agents[index].worktree && $0.id != id }
        agents[index].name = AgentRecord.uniqueName(name, among: others)
        send(.updateCard(agents[index]))
    }

    /// Makes the agent coordinate the ones connected to it, or stop.
    func setOrchestrator(_ id: UUID, _ orchestrates: Bool) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].orchestrates = orchestrates
        send(.updateCard(agents[index]))
    }

    func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].frame = frame
        if persist { send(.updateCard(agents[index])) }
    }

    // MARK: Sessions

    /// The live session for `record`, launching it on first use.
    func session(for record: AgentRecord, cols: Int, rows: Int) -> AgentSession {
        if let session = sessions[record.id] { return session }
        let session = AgentSession(cols: cols, rows: rows)
        let id = record.id
        session.onChange = { [weak self] in
            self?.onSessionChange?(id)
            self?.viewers[id]?.values.forEach { $0() }
        }
        sessions[record.id] = session
        if isUnavailable {
            session.fail(L("Couldn't start the process that runs the agents."))
        } else if let core {
            begin(record, in: session, on: core)
        } else if host != nil, let notice {
            session.fail(notice)
        }
        return session
    }

    /// Mirrors the core's session, which starts the program if the core doesn't have it. The
    /// first time, agents start and runners come back stopped (starting them is the
    /// developer's call); after the core came back, whatever was running starts again.
    private func begin(_ record: AgentRecord, in session: AgentSession, on client: CoreClient) {
        let again = hosted[record.id] != nil
        guard hosted[record.id] != connection else { return }
        hosted[record.id] = connection
        session.host(on: client, id: record.id)
        let size = session.withTerminal { ($0.cols, $0.rows) }
        let start = again ? session.processID != nil || session.state == .starting
                          : record.runner == nil || runnersToStart.contains(record.id)
        runnersToStart.remove(record.id)
        client.send(.open(id: record.id, cols: size.0, rows: size.1, start: start))
    }

    /// Shows the session in `viewer`, which `onChange` tells when it changes (the board draws
    /// through `onSessionChange` instead). The board and the attention deck can show the same one.
    func observe(_ id: UUID, by viewer: AnyObject, onChange: @escaping () -> Void = {}) {
        viewers[id, default: [:]][ObjectIdentifier(viewer)] = onChange
        sessions[id]?.isObserved = true
    }

    func stopObserving(_ id: UUID, by viewer: AnyObject) {
        viewers[id]?[ObjectIdentifier(viewer)] = nil
        if viewers[id]?.isEmpty == true { viewers[id] = nil }
        sessions[id]?.isObserved = viewers[id] != nil
    }

    // MARK: Attention

    /// The developer dealt with the agent: its request leaves the queue.
    func dismissAttention(_ id: UUID) {
        attention.removeAll { $0.id == id }
        send(.dismissAttention(id))
    }

    /// Answers the questions the agent asked, keyed by question text; nil leaves them to its
    /// terminal.
    func answerQuestions(_ id: UUID, _ answers: [String: String]?) {
        send(.answerQuestions(id: id, answers: answers))
    }

    /// Starts an agent that ended again.
    func restart(_ record: AgentRecord) {
        send(.restart(id: record.id, command: nil))
    }
}
