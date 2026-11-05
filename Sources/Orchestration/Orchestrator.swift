import AgentRuntime
import Connections
import Foundation

/// The board's cards, the lines between elements and the agents' tools, kept by the core so
/// they work while no board runs: agents message each other, start runners and read their logs
/// with the board closed, rebuilt or crashed. Boards mirror the cards and lines and send the
/// user's changes (see `BoardRequest`); the tools only a board can run (browsers) are relayed to
/// one.
///
/// Runs on the main queue, as the `CoreServer`'s service.
@MainActor
public final class Orchestrator: CoreService {
    let server: CoreServer
    private let database: CardDatabase?
    private let providers: [any AgentProvider]
    private let dataFolder: URL
    private(set) var cards: [AgentRecord] = []
    /// The post-its (see PostItTools).
    private(set) var postIts: [PostItRecord] = []
    /// The agents waiting on the developer, oldest first (see Attention.swift).
    var attention: [AttentionRequest] = [] { didSet { releaseHeldMessages() } }
    /// Agents whose questions hook waits on the developer's answers (see Attention.swift).
    var pendingQuestions: [UUID: PendingQuestions] = [:] { didSet { releaseHeldMessages() } }
    /// Agent endpoints, so messages held while an agent waits on the developer go out once it's answered.
    private var agentEndpoints: [UUID: AgentEndpoint] = [:]
    let bus: MessageBus
    let catalog: ToolCatalog
    let toolServer: ToolServer
    /// The user's real PATH, resolved off the main thread at launch (the login shell can be slow).
    private var searchPath: String?
    /// Where agents reach the tool server; nil if it couldn't start (agents then launch without it).
    private var toolsURL: URL?
    private var toolsResolved = false
    /// Cards whose program waits for the PATH and the tool server.
    private var pendingLaunches: [UUID] = []
    /// The boards' other elements (browsers).
    private var elements: [UUID: ElementInfo] = [:]
    /// Boards that got their welcome, which then get every change.
    private var boards: Set<CoreBoard> = []
    private var toolCalls: [UUID: (board: CoreBoard, done: CheckedContinuation<ToolResult, Never>)] = [:]

    // Runners (see Orchestrator+Runners.swift).
    var runnerStats: [UUID: RunnerStats] = [:]
    var runnerSamples: [UUID: ProcessInspector.Sample] = [:]
    var runnerStarts: [UUID: Date] = [:]
    var runnerMonitor: Timer?
    var networkAddress: String?
    var reportedRunners = RunnerReport()

    /// `searchPath` skips asking the login shell for one (tests); `providers` are the agents
    /// cards can run; `inheriting` is what an older core handed over (see `handOffState`).
    public init(server: CoreServer, database url: URL? = nil, dataFolder: URL = DataFolder.url,
                providers: [any AgentProvider] = AgentCatalog.all, searchPath: String? = nil,
                inheriting: Data? = nil, descriptors: [Int32] = []) {
        self.server = server
        self.dataFolder = dataFolder
        self.providers = providers
        database = try? CardDatabase(url: url ?? dataFolder.appendingPathComponent("agentboard.sqlite"))
        var saved = (try? database?.agents()) ?? []
        // Cards saved before agents had names get one now.
        for index in saved.indices where saved[index].name.isEmpty {
            let base = providers.first { $0.id == saved[index].providerID }?.title ?? saved[index].providerID
            saved[index].name = AgentRecord.uniqueName(base, among: saved.filter { $0.worktree == saved[index].worktree })
            try? database?.saveAgent(saved[index])
        }
        let savedPostIts = (try? database?.postIts()) ?? []
        let ids = Set(saved.map(\.id)).union(savedPostIts.map(\.id)).union(database?.browserIDs() ?? [])
        let stored = ((try? database?.connections()) ?? []).filter { ids.contains($0.a) && ids.contains($0.b) }
        bus = MessageBus(graph: ConnectionGraph(stored))
        catalog = ToolCatalog([MessagingTools(bus: bus)])
        toolServer = ToolServer(catalog: catalog, secret: Self.toolSecret(in: dataFolder))
        if ProcessInfo.processInfo.environment["AGENTBOARD_CORE_VERBOSE"] == "1", let log = server.onLog {
            toolServer.onRequest = { log("tools: \($0)") }
        }
        cards = saved
        postIts = savedPostIts
        catalog.add(RunnerTools(store: self))
        catalog.add(PostItTools(store: self))
        toolServer.onQuestion = { [weak self] body, caller in await self?.ask(body, caller: caller) }
        toolServer.onAttention = { [weak self] body, caller in
            let notification = AgentHook.prefix + body.base64EncodedString()
            Task { @MainActor in self?.sessionNotified(caller, [notification]) }
        }
        catalog.add(BrowserRelay(store: self))
        catalog.add(ProjectRelay(store: self))
        bus.onGraphChange = { [weak self] graph in
            try? self?.database?.saveConnections(graph.connections)
            self?.broadcast(.connections(graph.connections))
        }
        bus.onMessage = { [weak self] message in self?.broadcast(.message(message)) }
        for record in cards { register(record) }
        for record in postIts { bus.register(PostItElement(id: record.id, store: self)) }
        let inherited = inheriting.flatMap { try? JSONDecoder().decode(Inherited.self, from: $0) }
        if let inherited {
            attention = (inherited.attention ?? []).filter { id in cards.contains { $0.id == id.id } }
            runnerStarts = inherited.runnerStarts.filter { server.session($0.key)?.processID != nil }
            if !runnerStarts.isEmpty { startMonitoring() }
        }
        // The older core's tool server: its socket, and the agents' connections to it.
        let tools = inherited.flatMap { inherited -> ToolServer.Release? in
            guard let listener = descriptors.first, descriptors.count == inherited.toolConnections.count + 1 else { return nil }
            let handed = Array(zip(descriptors.dropFirst(), inherited.toolConnections))
            let streams = Set(inherited.toolStreams ?? [])
            return ToolServer.Release(listener: listener, connections: handed.indices.filter { !streams.contains($0) }.map { handed[$0] },
                                      streams: streams.sorted().filter(handed.indices.contains).map { handed[$0].0 })
        }
        let portFile = dataFolder.appendingPathComponent("tools.port")
        let port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        toolServer.start(preferredPort: port, inheriting: tools) { [weak self] url in
            if let port = url?.port { try? String(port).write(to: portFile, atomically: true, encoding: .utf8) }
            self?.toolsURL = url
            self?.toolsResolved = true
            self?.launchPending()
        }
        if let searchPath {
            self.searchPath = searchPath
        } else {
            Task.detached(priority: .userInitiated) {
                let path = Self.loginShellPath()
                await MainActor.run {
                    self.searchPath = path
                    self.launchPending()
                }
            }
        }
    }

    /// The key the tool server derives agents' tokens from, created on first use. Kept on disk,
    /// readable by this user only, so tokens stay valid across launches.
    nonisolated private static func toolSecret(in folder: URL) -> Data? {
        let url = folder.appendingPathComponent("tools.key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        try? FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600]) else { return nil }
        return Data(bytes)
    }

    /// Where agents reach the tools, once the server listens; tests call it as an agent would.
    public var toolsEndpoint: URL? { toolsURL }

    /// The token `card` calls the tools with.
    public func toolToken(for card: UUID) -> String { toolServer.token(for: card) }

    func record(_ id: UUID) -> AgentRecord? { cards.first { $0.id == id } }

    func cards(in worktree: String) -> [AgentRecord] { cards.filter { $0.worktree == worktree } }

    /// The boards' other elements on `worktree` (browsers, file trees).
    func elementFrames(in worktree: String) -> [(id: UUID, frame: CGRect)] {
        elements.values.filter { $0.worktree == worktree }.map { ($0.id, $0.frame) }
    }

    func postIt(_ id: UUID) -> PostItRecord? { postIts.first { $0.id == id } }

    func session(_ id: UUID) -> AgentSession? { server.session(id) }

    private func register(_ record: AgentRecord) {
        if record.runner == nil {
            let endpoint = AgentEndpoint(id: record.id, store: self)
            agentEndpoints[record.id] = endpoint
            bus.register(endpoint)
        } else {
            bus.register(RunnerElement(id: record.id, store: self))
        }
        // Agents launched earlier call with the token they got then.
        _ = toolServer.token(for: record.id)
    }

    // MARK: Handing over to a newer core

    /// What the sessions don't carry: when each runner started, and what was read of the next
    /// request on each tool connection handed over. The agents' event streams go among the
    /// connections, at `toolStreams`: a core that predates them takes them for idle ones.
    private struct Inherited: Codable {
        var runnerStarts: [UUID: Date]
        var toolConnections: [Data]
        var toolStreams: [Int]?
        /// Nil from a core that predates the attention queue.
        var attention: [AttentionRequest]?
    }

    /// The tool server's socket and connections, until the newer core has them.
    private var releasedTools: ToolServer.Release?

    /// Lets the agents' tool calls being answered finish; the next ones wait for the newer core.
    public func prepareHandOff() async {
        await toolServer.drain()
    }

    public func handOffState() -> (state: Data?, descriptors: [Int32]) {
        releasedTools = toolServer.release()
        let connections = releasedTools?.connections ?? []
        let streams = releasedTools?.streams ?? []
        let state = try? JSONEncoder().encode(Inherited(runnerStarts: runnerStarts,
                                                        toolConnections: connections.map(\.pending) + streams.map { _ in Data() },
                                                        toolStreams: streams.indices.map { connections.count + $0 },
                                                        attention: attention))
        return (state, releasedTools.map { [$0.listener] + connections.map(\.fd) + streams } ?? [])
    }

    public func handedOff() {
        releasedTools = nil
        toolServer.stop()
        runnerMonitor?.invalidate()
        runnerMonitor = nil
    }

    public func handOffFailed() {
        guard let released = releasedTools else { return }
        releasedTools = nil
        toolServer.start(inheriting: released) { _ in }
    }

    // MARK: Boards

    public func boardConnected(_ board: CoreBoard) -> Data? {
        boards.insert(board)
        return BoardState(cards: cards, connections: bus.graph.connections, runners: reportedRunners, postIts: postIts,
                          attention: attention).encoded
    }

    public func boardDisconnected(_ board: CoreBoard) {
        boards.remove(board)
        for (call, pending) in toolCalls where pending.board == board {
            toolCalls[call] = nil
            pending.done.resume(returning: .error("The board closed before the browser answered. Try again once it is open."))
        }
    }

    public func received(_ payload: Data, from board: CoreBoard) {
        guard let request = BoardRequest(payload) else { return }
        switch request {
        case .addCard(let record):
            guard self.record(record.id) == nil else { return }
            insert(record, from: board)
        case .updateCard(let record):
            update(record.id, from: board) { $0 = record }
        case .removeCard(let id):
            remove(id, from: board)
        case .deliver(let from, let text):
            for peer in bus.peers(of: from) where peer is any MessageEndpoint {
                _ = try? bus.deliver(text, from: from, to: peer.id)
            }
        case .connect(let connection):
            bus.add(connection)
        case .disconnect(let id):
            bus.disconnect(id)
        case .elements(let list):
            let listed = Set(list.map(\.id))
            for id in elements.keys where !listed.contains(id) {
                elements[id] = nil
                bus.remove(element: id)
            }
            for info in list {
                if elements[info.id] == nil { bus.register(RemoteElement(id: info.id, store: self)) }
                elements[info.id] = info
            }
        case .open(let id, let cols, let rows, let start):
            guard let record = record(id) else { return }
            let fresh = server.session(id) == nil
            let session = server.openSession(id, cols: cols, rows: rows, for: board)
            guard fresh else { return }
            if start {
                launch(record.id)
            } else {
                session.markStopped()
            }
        case .restart(let id, let command):
            guard let record = record(id) else { return }
            if record.runner != nil {
                restartRunner(id, command: command)
            } else if let session = server.session(id), session.processID == nil {
                launch(id)
            }
        case .startRunner(let id):
            startRunner(id)
        case .stopRunner(let id):
            stopRunner(id)
        case .toolResult(let call, let result):
            toolCalls.removeValue(forKey: call)?.done.resume(returning: result.result)
        case .addPostIt(let record):
            guard postIt(record.id) == nil else { return }
            insertPostIt(record, from: board)
        case .updatePostIt(let record):
            updatePostIt(record.id, from: board) {
                $0.name = record.name
                $0.frame = record.frame
            }
        case .removePostIt(let id):
            removePostIt(id, from: board)
        case .writePostIt(let id, let text):
            updatePostIt(id, from: board) { $0.write(text, by: nil) }
        case .dismissAttention(let id):
            dismissAttention(id)
        case .answerQuestions(let id, let answers):
            answerQuestions(id, answers)
        }
    }

    func broadcast(_ event: BoardEvent, except sender: CoreBoard? = nil) {
        let data = event.encoded
        for board in boards where board != sender { board.send(data) }
    }

    /// Runs a tool only a board can (a browser's) on a connected one.
    func relay(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let board = boards.first else {
            return .error(name.hasPrefix("project_") ? "Projects live in the board, which isn't open right now. Ask the user to open it, then try again." : "Browsers run in the board, which isn't open right now. Ask the user to open it, then try again.")
        }
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        let call = UUID()
        return await withCheckedContinuation { done in
            toolCalls[call] = (board, done)
            board.send(BoardEvent.toolCall(call: call, name: name, arguments: data, caller: caller).encoded)
        }
    }

    // MARK: Cards

    /// Adds a card and saves it; boards other than `sender` hear of it.
    func insert(_ record: AgentRecord, from sender: CoreBoard? = nil) {
        cards.append(record)
        register(record)
        try? database?.saveAgent(record)
        broadcast(.cardAdded(record), except: sender)
    }

    /// Changes a card's record in place and saves it.
    func update(_ id: UUID, from sender: CoreBoard? = nil, _ change: (inout AgentRecord) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
        try? database?.saveAgent(cards[index])
        broadcast(.cardUpdated(cards[index]), except: sender)
    }

    func remove(_ id: UUID, from sender: CoreBoard? = nil) {
        guard let record = record(id) else { return }
        server.closeSession(id, grace: record.runner != nil ? 3 : nil)
        if record.runner != nil { forgetRunner(id) }
        bus.remove(element: id)
        agentEndpoints[id] = nil
        toolServer.revoke(id)
        cards.removeAll { $0.id == id }
        try? database?.deleteAgent(id: id)
        broadcast(.cardRemoved(id), except: sender)
        dismissAttention(id)
    }

    // MARK: Post-its

    /// Adds a post-it and saves it; boards other than `sender` hear of it.
    func insertPostIt(_ record: PostItRecord, from sender: CoreBoard? = nil) {
        postIts.append(record)
        bus.register(PostItElement(id: record.id, store: self))
        try? database?.savePostIt(record)
        broadcast(.postItAdded(record), except: sender)
    }

    /// Changes a post-it in place and saves it; boards other than `sender` hear of it (the
    /// sender already shows the change it sent).
    func updatePostIt(_ id: UUID, from sender: CoreBoard? = nil, _ change: (inout PostItRecord) -> Void) {
        guard let index = postIts.firstIndex(where: { $0.id == id }) else { return }
        let before = postIts[index]
        change(&postIts[index])
        guard postIts[index] != before else { return }
        try? database?.savePostIt(postIts[index])
        broadcast(.postItUpdated(postIts[index]), except: sender)
    }

    func removePostIt(_ id: UUID, from sender: CoreBoard? = nil) {
        guard postIt(id) != nil else { return }
        bus.remove(element: id)
        postIts.removeAll { $0.id == id }
        try? database?.deletePostIt(id: id)
        broadcast(.postItRemoved(id), except: sender)
    }

    // MARK: Launching

    private func launchPending() {
        guard searchPath != nil, toolsResolved else { return }
        let pending = pendingLaunches
        pendingLaunches.removeAll()
        pending.forEach(launch)
    }

    /// Starts the card's program in its session.
    func launch(_ id: UUID) {
        guard let record = record(id), let session = server.session(id) else { return }
        guard let searchPath, toolsResolved else {
            if !pendingLaunches.contains(id) { pendingLaunches.append(id) }
            return
        }
        if let runner = record.runner {
            return launchRunner(record, runner, in: session, searchPath: searchPath)
        }
        guard let provider = providers.first(where: { $0.id == record.providerID }) else {
            session.fail(L("Unknown agent “\(record.providerID)”."))
            return
        }
        guard FileManager.default.fileExists(atPath: record.worktree) else {
            session.fail(L("This worktree no longer exists on disk."))
            return
        }
        guard let executable = Self.resolve(provider.executable, in: searchPath) else {
            session.fail(L("Could not find “\(provider.executable)” in your PATH."))
            return
        }
        var environment = provider.environment(ProcessInfo.processInfo.environment)
        environment["PATH"] = searchPath
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // The core's own settings aren't the agent's business: an agent running a build of
        // the board (`./run`) must not reach this core, or its data folder.
        for key in environment.keys where key.hasPrefix("AGENTBOARD_") { environment[key] = nil }
        // Signed in as the card's organization; `/login` in the terminal signs that one in.
        environment["CLAUDE_CONFIG_DIR"] = OrganizationHome.prepare(record.organization)?.path
        let tools = toolsURL.map { ToolServerLink(name: ToolCatalog.serverName, url: $0, token: toolServer.token(for: record.id)) }
        session.start(LaunchSpec(executable: executable, arguments: provider.arguments(session: record.conversation ?? record.id, tools: tools),
                                 environment: environment, directory: record.worktree))
    }

    var launchSearchPath: String? { searchPath }

    private static func resolve(_ name: String, in searchPath: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// GUI apps get a minimal PATH; ask the user's interactive login shell for the real one
    /// so tools installed through shell config (like ~/.local/bin) are found.
    nonisolated public static func loginShellPath() -> String {
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

    fileprivate func element(_ id: UUID) -> ElementInfo? { elements[id] }

    /// Whether the agent is answering the developer's questions or a prompt in its terminal:
    /// a message typed in now would land in that answer.
    fileprivate func isAwaitingDeveloper(_ id: UUID) -> Bool {
        pendingQuestions[id] != nil || attention.contains { $0.id == id && $0.reason == .waiting }
    }

    private func releaseHeldMessages() {
        for endpoint in agentEndpoints.values { endpoint.deliverNext() }
    }
}

/// An agent as the message bus sees it: a message is typed into its terminal as a prompt.
@MainActor
final class AgentEndpoint: MessageEndpoint {
    let id: UUID
    private weak var store: Orchestrator?
    /// Prompts waiting their turn: each is pasted and submitted before the next, so two
    /// messages arriving together don't merge into one prompt.
    private var outbox: [String] = []
    private var delivering = false
    /// Between the paste and the Enter that submits it: sent together, the agent may read the
    /// Enter as part of the pasted text.
    private static let submitDelay = 0.25

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .agent }

    var unavailableReason: String? {
        switch store?.session(id)?.state {
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

    /// Held while the agent waits on the developer; the store calls again once that changes.
    func deliverNext() {
        guard !delivering, !outbox.isEmpty, let store, !store.isAwaitingDeveloper(id), let session = store.session(id) else { return }
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

/// A runner as the message bus sees it: reachable along lines, driven with the runner tools.
@MainActor
final class RunnerElement: BoardElement {
    let id: UUID
    private weak var store: Orchestrator?

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .runner }

    var detail: String? {
        guard let runner = store?.record(id)?.runner else { return nil }
        return runner.isShell ? "a terminal the user types into" : "runs `\(runner.command)`"
    }
}

/// A post-it as the message bus sees it: reachable along lines, read and written with the
/// post-it tools.
@MainActor
private final class PostItElement: BoardElement {
    let id: UUID
    private weak var store: Orchestrator?

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String { store?.postIt(id)?.name ?? "" }
    var kind: ElementKind { .postIt }

    var detail: String? {
        guard let record = store?.postIt(id) else { return nil }
        let lines = record.text.split(whereSeparator: \.isNewline).count
        return "shared markdown note, \(lines == 0 ? "empty" : "\(lines) line\(lines == 1 ? "" : "s")"); read with postit_read"
    }
}

/// An element the board told the core about (a browser).
@MainActor
private final class RemoteElement: BoardElement {
    let id: UUID
    private weak var store: Orchestrator?

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String { store?.element(id)?.name ?? "" }
    var kind: ElementKind { ElementKind(rawValue: store?.element(id)?.kind ?? "") }
    var detail: String? { store?.element(id)?.detail }
}
