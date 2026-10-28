import AgentRuntime
import Connections
import Foundation
import Observation

/// A persisted terminal card: an agent, or a runner (a command the board keeps running, such as
/// a dev server). Which worktree it belongs to and where it sits on the canvas.
struct AgentRecord: Identifiable, Hashable {
    let id: UUID
    let worktree: String
    /// `AgentProvider.id` of the agent this card runs; `AgentStore.runnerProviderID` for runners.
    let providerID: String
    /// How the card is titled and how connected agents address it; unique in its worktree.
    var name: String
    var frame: CGRect
    /// What the card runs when it is a runner; nil for agents.
    var runner: RunnerSpec? = nil

    var provider: (any AgentProvider)? { AgentCatalog.provider(id: providerID) }
}

/// Owns every agent card, its live session, and the lines between cards. Sessions keep running
/// while the user looks at other worktrees (parsing output, never drawing); they start the
/// first time their worktree's canvas is shown.
///
/// Connected agents message each other through the board's tool server: each agent is launched
/// with it as an MCP server, and a message reaches its recipient typed into their terminal.
@MainActor
@Observable
final class AgentStore {
    private(set) var agents: [AgentRecord] = []
    /// Lines between agents, in the order they were drawn.
    private(set) var connections: [Connection] = []
    @ObservationIgnored private(set) var sessions: [UUID: AgentSession] = [:]
    /// Called with the card's id when an observed session changes, so the board redraws it.
    @ObservationIgnored var onSessionChange: ((UUID) -> Void)?
    /// Called after a message travels along a line, so the board can show it.
    @ObservationIgnored var onMessage: ((Message) -> Void)?

    @ObservationIgnored private let database: Database?
    @ObservationIgnored let bus: MessageBus
    /// Tools agents get over the tool server; other element families add their providers here.
    @ObservationIgnored let catalog: ToolCatalog
    @ObservationIgnored private let toolServer: ToolServer
    /// The user's real PATH, resolved off the main thread at launch (the login shell can be slow).
    @ObservationIgnored private var searchPath: String?
    /// Where agents reach the tool server; nil if it couldn't start (agents then launch without it).
    @ObservationIgnored private var toolsURL: URL?
    @ObservationIgnored private var toolsResolved = false
    @ObservationIgnored private var pendingLaunches: [(AgentRecord, AgentSession)] = []

    // Runners (see AgentStore+Runners.swift).
    /// What each running runner costs and serves, refreshed every few seconds while any runs.
    @ObservationIgnored var runnerStats: [UUID: RunnerStats] = [:]
    @ObservationIgnored var runnerSamples: [UUID: ProcessInspector.Sample] = [:]
    /// When each runner last started.
    @ObservationIgnored var runnerStarts: [UUID: Date] = [:]
    /// Runners to launch when their session is created; the others come back stopped.
    @ObservationIgnored var runnersToStart: Set<UUID> = []
    @ObservationIgnored var runnerMonitor: Timer?
    /// This Mac's address on the local network, for runner ports other devices can reach.
    @ObservationIgnored var networkAddress: String?
    /// Called when runner stats or states change, so the board redraws their cards.
    @ObservationIgnored var onRunnersChange: (() -> Void)?

    /// `elements`: ids of the board's other elements (browsers…), so lines to them survive loading.
    init(database: Database?, elements: Set<UUID> = []) {
        self.database = database
        var saved = (try? database?.agents()) ?? []
        // Cards saved before agents had names get one now.
        for index in saved.indices where saved[index].name.isEmpty {
            let base = saved[index].provider?.title ?? saved[index].providerID
            saved[index].name = Self.uniqueName(base, among: saved.filter { $0.worktree == saved[index].worktree })
            try? database?.saveAgent(saved[index])
        }
        let ids = Set(saved.map(\.id)).union(elements)
        let stored = ((try? database?.connections()) ?? []).filter { ids.contains($0.a) && ids.contains($0.b) }
        bus = MessageBus(graph: ConnectionGraph(stored))
        catalog = ToolCatalog([MessagingTools(bus: bus)])
        toolServer = ToolServer(catalog: catalog)
        agents = saved
        connections = stored
        catalog.add(RunnerTools(store: self))
        bus.onGraphChange = { [weak self] graph in
            self?.connections = graph.connections
            try? self?.database?.saveConnections(graph.connections)
        }
        bus.onMessage = { [weak self] message in self?.onMessage?(message) }
        for record in agents {
            bus.register(record.runner == nil ? AgentEndpoint(id: record.id, store: self) : RunnerElement(id: record.id, store: self))
        }
        toolServer.start { [weak self] url in
            self?.toolsURL = url
            self?.toolsResolved = true
            self?.launchPending()
        }
        Task.detached(priority: .userInitiated) {
            let path = Self.loginShellPath()
            await MainActor.run {
                self.searchPath = path
                self.launchPending()
            }
        }
    }

    private func launchPending() {
        guard searchPath != nil, toolsResolved else { return }
        let pending = pendingLaunches
        pendingLaunches.removeAll()
        for (record, session) in pending where sessions[record.id] === session {
            launch(record, in: session)
        }
    }

    func agents(in worktree: String) -> [AgentRecord] {
        agents.filter { $0.worktree == worktree }
    }

    func record(_ id: UUID) -> AgentRecord? {
        agents.first { $0.id == id }
    }

    @discardableResult
    func add(_ provider: any AgentProvider, to worktree: String, at origin: CGPoint) -> AgentRecord {
        let record = AgentRecord(id: UUID(), worktree: worktree, providerID: provider.id,
                                 name: Self.uniqueName(provider.title, among: agents(in: worktree)),
                                 frame: CGRect(origin: origin, size: CGSize(width: 640, height: 420)))
        agents.append(record)
        bus.register(AgentEndpoint(id: record.id, store: self))
        try? database?.saveAgent(record)
        return record
    }

    /// Adds a card built elsewhere (a runner) and saves it.
    func insert(_ record: AgentRecord) {
        agents.append(record)
        try? database?.saveAgent(record)
    }

    /// Changes a card's record in place and saves it.
    func update(_ id: UUID, _ change: (inout AgentRecord) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        change(&agents[index])
        try? database?.saveAgent(agents[index])
    }

    func remove(_ id: UUID) {
        if record(id)?.runner != nil {
            sessions.removeValue(forKey: id)?.terminate()
            forgetRunner(id)
        } else {
            sessions.removeValue(forKey: id)?.stop()
        }
        bus.remove(element: id)
        toolServer.revoke(id)
        agents.removeAll { $0.id == id }
        try? database?.deleteAgent(id: id)
    }

    /// `base`, or `base 2`, `base 3`… whichever no card in `others` is called.
    static func uniqueName(_ base: String, among others: [AgentRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Connections

    /// The lines between cards of `worktree`; `elements` are its other cards (browsers…).
    func connections(in worktree: String, elements: Set<UUID> = []) -> [Connection] {
        let ids = Set(agents(in: worktree).map(\.id)).union(elements)
        return connections.filter { ids.contains($0.a) && ids.contains($0.b) }
    }

    @discardableResult
    func connect(_ a: UUID, _ b: UUID, sides: (Side?, Side?) = (nil, nil)) -> Connection? { bus.connect(a, b, sides: sides) }

    func disconnect(_ id: UUID) { bus.disconnect(id) }

    /// Moves the card to the top of the stack.
    func raise(_ id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }), index != agents.count - 1 else { return }
        agents.append(agents.remove(at: index))
    }

    func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].frame = frame
        if persist { try? database?.saveAgent(agents[index]) }
    }

    /// The live session for `record`, launching it on first use.
    func session(for record: AgentRecord, cols: Int, rows: Int) -> AgentSession {
        if let session = sessions[record.id] { return session }
        let session = AgentSession(cols: cols, rows: rows)
        let id = record.id
        session.onChange = { [weak self] in self?.onSessionChange?(id) }
        sessions[record.id] = session
        if record.runner != nil, !runnersToStart.contains(record.id) {
            // Runners come back stopped after a relaunch: starting them is the developer's call.
            session.markStopped()
        } else {
            runnersToStart.remove(record.id)
            launch(record, in: session)
        }
        return session
    }

    func restart(_ record: AgentRecord) {
        guard let session = sessions[record.id] else { return }
        launch(record, in: session)
    }

    func launch(_ record: AgentRecord, in session: AgentSession) {
        guard let searchPath, toolsResolved else {
            pendingLaunches.append((record, session))
            return
        }
        if let runner = record.runner {
            return launchRunner(record, runner, in: session, searchPath: searchPath)
        }
        guard let provider = record.provider else {
            session.fail(L("Unknown agent “\(record.providerID)”."))
            return
        }
        guard FileManager.default.fileExists(atPath: record.worktree) else {
            session.fail(L("This worktree no longer exists on disk."))
            return
        }
        guard let executable = resolve(provider.executable, in: searchPath) else {
            session.fail(L("Could not find “\(provider.executable)” in your PATH."))
            return
        }
        var environment = provider.environment(ProcessInfo.processInfo.environment)
        environment["PATH"] = searchPath
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let tools = toolsURL.map { ToolServerLink(name: ToolCatalog.serverName, url: $0, token: toolServer.token(for: record.id)) }
        session.start(LaunchSpec(executable: executable, arguments: provider.arguments(session: record.id, tools: tools),
                                 environment: environment, directory: record.worktree))
    }

    private func resolve(_ name: String, in searchPath: String) -> String? {
        searchPath.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// GUI apps get a minimal PATH; ask the user's interactive login shell for the real one
    /// so tools installed through shell config (like ~/.local/bin) are found.
    nonisolated static func loginShellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n%s' \"$PATH\""]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        guard (try? process.run()) != nil else { return fallback }
        // Shell config can block (prompts, tmux auto-attach); never wait more than a few seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
        return path?.isEmpty == false ? path! : fallback
    }
}

/// An agent as the message bus sees it: a message is typed into its terminal as a prompt.
@MainActor
private final class AgentEndpoint: MessageEndpoint {
    let id: UUID
    private weak var store: AgentStore?
    /// Prompts waiting their turn: each is pasted and submitted before the next, so two
    /// messages arriving together don't merge into one prompt.
    private var outbox: [String] = []
    private var delivering = false
    /// Between the paste and the Enter that submits it: sent together, the agent may read the
    /// Enter as part of the pasted text.
    private static let submitDelay = 0.25

    init(id: UUID, store: AgentStore) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .agent }

    var unavailableReason: String? {
        switch store?.sessions[id]?.state {
        case .running: nil
        case .starting: "it is still starting"
        case .exited: "it exited"
        case .failed: "it failed to start"
        case .stopped: "it was stopped"
        case nil: "it hasn't started yet"
        }
    }

    func receive(_ message: Message, from sender: any BoardElement) {
        outbox.append("Message from \(sender.name) (if it needs an answer, reply with send_message to “\(sender.name)”):\n\n\(message.text)")
        deliverNext()
    }

    private func deliverNext() {
        guard !delivering, !outbox.isEmpty, let session = store?.sessions[id] else { return }
        delivering = true
        let prompt = outbox.removeFirst()
        session.send(session.withTerminal { $0.encodePaste(prompt) })
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) { [weak self] in
            session.send([0x0D])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) {
                self?.delivering = false
                self?.deliverNext()
            }
        }
    }
}
