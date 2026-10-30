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
    /// False until the core has said which cards there are.
    private(set) var isLoaded = false
    /// Why the cards can't be shown, when the core runs another build this one can't talk to.
    private(set) var notice: String?
    /// The organization shown: only its cards are on the canvas, and new ones join it.
    var organizationID: UUID = OrganizationHome.defaultID
    @ObservationIgnored private(set) var sessions: [UUID: AgentSession] = [:]
    /// Called with the card's id when an observed session changes, so the board redraws it.
    @ObservationIgnored var onSessionChange: ((UUID) -> Void)?
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
    /// The board's other elements (browsers), which the core keeps lines to.
    @ObservationIgnored var elements: () -> [ElementInfo] = { [] }

    // Runners (see AgentStore+Runners.swift).
    /// What each running runner serves and costs, and when it started, as the core measures it.
    @ObservationIgnored var runnerReport = RunnerReport()
    /// Runners to start when their session is created; the others come back stopped.
    @ObservationIgnored var runnersToStart: Set<UUID> = []
    /// Called when runner stats or states change, so the board redraws their cards.
    @ObservationIgnored var onRunnersChange: (() -> Void)?

    /// `database`: where a core in this process keeps the cards (the data folder's by default).
    /// `connect` finds the core (the one next to this executable by default; another in tests).
    init(database: URL? = nil, connect: (@Sendable () -> Result<CoreClient, CoreClient.Failure>)? = nil) {
        link = CoreLink(connect: connect ?? { AgentStore.connectCore() })
        link.onConnect = { [weak self] client, state, waiting in self?.connected(client, state.applying(waiting)) }
        link.onEvent = { [weak self] event in self?.received(event) }
        link.onDown = { [weak self] in self?.coreDown() }
        link.onIncompatible = { [weak self] core in self?.incompatible(core) }
        Task {
            let started = await link.start { [weak self] in
                self?.local = try? InProcessCore(database: database)
                return self?.local?.socketPath
            }
            if !started { unavailable() }
        }
    }

    var core: CoreClient? { link.client }

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
        notice = nil
        replacedCore = false
        agents = state.cards
        postIts = state.postIts ?? []
        connections = state.connections
        runnerReport = state.runners
        isLoaded = true
        client.send(.elements(elements()))
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
        NSLog("AgentBoard: the core stopped; reconnecting")
        for session in sessions.values { session.fail(L("Lost the process that runs the agents. Reconnecting…")) }
    }

    private func unavailable() {
        isUnavailable = true
        isLoaded = true
        for session in sessions.values { session.fail(L("Couldn't start the process that runs the agents.")) }
    }

    private func received(_ event: BoardEvent) {
        switch event {
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
        case .toolCall(let call, let name, let arguments, let caller):
            let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
            Task {
                let result = await browserTools?.call(name, arguments: parsed, caller: caller)
                    ?? .error("This board can't run “\(name)”.")
                link.send(.toolResult(call: call, result: WireToolResult(result)))
            }
        }
    }

    /// Sends a change to the core, now or once it is back.
    func send(_ request: BoardRequest) {
        guard !isUnavailable else { return }
        link.send(request)
    }

    /// Tells the core the board's other elements changed (a browser added, removed, renamed…).
    func elementsChanged() {
        guard link.isConnected else { return }
        send(.elements(elements()))
    }

    /// Ends every card's program as the app quits; a board that is killed or rebuilt instead
    /// leaves them running on the core, to attach to next launch.
    func quit() {
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
        hosted[id] = nil
        runnersToStart.remove(id)
        agents.removeAll { $0.id == id }
        connections.removeAll { $0.touches(id) }
    }

    // MARK: Connections

    /// The lines between cards of `worktree`; `elements` are its other cards (browsers…).
    func connections(in worktree: String, elements: Set<UUID> = []) -> [Connection] {
        let ids = Set(agents(in: worktree).map(\.id)).union(postIts(in: worktree).map(\.id)).union(elements)
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
        session.onChange = { [weak self] in self?.onSessionChange?(id) }
        sessions[record.id] = session
        if isUnavailable {
            session.fail(L("Couldn't start the process that runs the agents."))
        } else if let core {
            begin(record, in: session, on: core)
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

    /// Starts an agent that ended again.
    func restart(_ record: AgentRecord) {
        send(.restart(id: record.id, command: nil))
    }
}
