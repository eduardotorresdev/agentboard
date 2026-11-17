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
    let providers: [any AgentProvider]
    let dataFolder: URL
    private(set) var cards: [AgentRecord] = []
    /// The post-its (see PostItTools).
    private(set) var postIts: [PostItRecord] = []
    /// The images (see ImageTools).
    private(set) var images: [ImageRecord] = []
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
    var pendingLaunches: [UUID] = []
    /// Set when the saved board couldn't be read at launch: the stored lines are then never replaced.
    private var connectionsReadOnly = false
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
        do {
            database = try CardDatabase(url: url ?? dataFolder.appendingPathComponent("agentboard.sqlite"))
        } catch {
            // Running on without saving is better than not running, but never silently.
            database = nil
            FileHandle.standardError.write(Data("agentboard core: the cards database didn't open, nothing will be saved: \(error)\n".utf8))
        }
        // A read that fails must not look like an empty board: the lines are saved by replacing
        // them all, so they stay unwritten until the next launch reads everything.
        let stored = database
        var readFailed = false
        func read<T>(_ body: () throws -> T?, _ empty: T) -> T {
            do { return try body() ?? empty } catch {
                readFailed = true
                FileHandle.standardError.write(Data("agentboard core: couldn't read the cards database, lines won't be saved: \(error)\n".utf8))
                return empty
            }
        }
        var saved = read({ try stored?.agents() }, [])
        // Cards saved before agents had names get one now.
        for index in saved.indices where saved[index].name.isEmpty {
            let base = providers.first { $0.id == saved[index].providerID }?.title ?? saved[index].providerID
            saved[index].name = AgentRecord.uniqueName(base, among: saved.filter { $0.worktree == saved[index].worktree })
            try? database?.saveAgent(saved[index])
        }
        let savedPostIts = read({ try stored?.postIts() }, [])
        let savedImages = read({ try stored?.images() }, [])
        let ids = Set(saved.map(\.id)).union(savedPostIts.map(\.id)).union(savedImages.map(\.id))
            .union(read({ try stored?.browserIDs() }, []))
        let lines = read({ try stored?.connections() }, []).filter { ids.contains($0.a) && ids.contains($0.b) }
        connectionsReadOnly = readFailed
        bus = MessageBus(graph: ConnectionGraph(lines))
        catalog = ToolCatalog([MessagingTools(bus: bus)])
        toolServer = ToolServer(catalog: catalog, secret: Self.toolSecret(in: dataFolder))
        if ProcessInfo.processInfo.environment["AGENTBOARD_CORE_VERBOSE"] == "1", let log = server.onLog {
            toolServer.onRequest = { log("tools: \($0)") }
        }
        // Names reach agents' prompts and listings: cards saved by older builds are cleaned too.
        cards = saved.map { var card = $0; card.name = BoardName.named(card.name, else: card.runner == nil ? "Agent" : "Runner"); return card }
        postIts = savedPostIts.map { var note = $0; note.name = BoardName.named(note.name, else: "Post-it"); return note }
        images = savedImages.map { var image = $0; image.name = BoardName.named(image.name, else: "Image"); return image }
        catalog.add(RunnerTools(store: self))
        catalog.add(PostItTools(store: self))
        catalog.add(ImageTools(store: self))
        catalog.add(ImageTools(store: self, medium: .video))
        toolServer.onQuestion = { [weak self] body, caller in await self?.ask(body, caller: caller) }
        toolServer.onAttention = { [weak self] body, caller in
            let notification = AgentHook.prefix + body.base64EncodedString()
            Task { @MainActor in self?.sessionNotified(caller, [notification]) }
        }
        catalog.add(BrowserRelay(store: self))
        catalog.add(ProjectRelay(store: self))
        catalog.add(WorktreeTools(store: self))
        catalog.add(CardTools(store: self))
        bus.onGraphChange = { [weak self] graph in
            if self?.connectionsReadOnly == false { try? self?.database?.saveConnections(graph.connections) }
            self?.broadcast(.connections(graph.connections))
        }
        bus.onMessage = { [weak self] message in self?.broadcast(.message(message)) }
        for record in cards { register(record) }
        for record in postIts { bus.register(PostItElement(id: record.id, store: self)) }
        for record in images { bus.register(ImageElement(id: record.id, store: self)) }
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
        tidyMedia()
        // An agent whose program ended can't answer: it leaves Needs you.
        server.onSessionStatus = { [weak self] id, status in
            MainActor.assumeIsolated { self?.agentEndpoints[id]?.sessionChanged(status) }
            guard status.processID == nil, status.state != .starting else { return }
            MainActor.assumeIsolated { self?.dismissAttention(id) }
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

    func image(_ id: UUID) -> ImageRecord? { images.first { $0.id == id } }

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
                          attention: attention, images: images).encoded
    }

    public func input(_ bytes: [UInt8], to id: UUID) -> [UInt8] {
        agentEndpoints[id]?.userTyped(bytes) ?? bytes
    }

    public func boardDisconnected(_ board: CoreBoard) {
        boards.remove(board)
        for (call, pending) in toolCalls where pending.board == board {
            toolCalls[call] = nil
            pending.done.resume(returning: .error("The board closed before the browser answered. Try again once it is open."))
        }
    }

    public func received(_ payload: Data, from board: CoreBoard) {
        guard let request = BoardRequest(payload)?.withCleanNames else {
            server.onLog?("ignored a board request this core doesn't know (\(payload.count) bytes)")
            return
        }
        switch request {
        case .addCard(let record):
            guard self.record(record.id) == nil else { return }
            insert(record, from: board)
        case .updateCard(let record):
            // Names reach agents' listings and prompts: one line of visible text, or the old one.
            update(record.id, from: board) { let old = $0.name; $0 = record; $0.name = BoardName.clean(record.name) ?? old }
        case .removeCard(let id):
            remove(id, from: board)
        case .prompt(let id, let text):
            agentEndpoints[id]?.prompt(text)
        case .deliverHeld(let id):
            agentEndpoints[id]?.deliverHeld()
        case .deliver(let from, let text):
            for peer in bus.peers(of: from) where peer is any MessageEndpoint {
                _ = try? bus.deliver(text, from: from, to: peer.id)
            }
        case .connect(let connection):
            // Only within one board: a line across organizations would let an agent read the
            // other's post-its.
            guard MessageBus.sameBoard(bus.element(connection.a)?.board, bus.element(connection.b)?.board) else { return }
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
                $0.name = BoardName.clean(record.name) ?? $0.name
                $0.frame = record.frame
            }
        case .removePostIt(let id):
            removePostIt(id, from: board)
        case .writePostIt(let id, let text):
            updatePostIt(id, from: board) { $0.write(text, by: nil) }
        case .addImage(let record):
            // A plain file name inside the images folder, never a path out of it.
            guard image(record.id) == nil, !record.file.isEmpty, record.file != ".", record.file != "..",
                  (record.file as NSString).lastPathComponent == record.file,
                  FileManager.default.fileExists(atPath: ImageFiles.url(of: record.file, in: dataFolder).path) else { return }
            // A dropped file's name reaches agents: no control or bidi characters.
            var record = record
            record.name = BoardName.clean(record.name) ?? (record.isVideo ? "Video" : "Image")
            insertImage(record, from: board)
        case .updateImage(let record):
            updateImage(record.id, from: board) {
                $0.name = BoardName.clean(record.name) ?? $0.name
                $0.frame = record.frame
            }
        case .removeImage(let id):
            removeImage(id, from: board)
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
            return .error(name.hasPrefix("project_") || name.hasPrefix("worktree_") || name.hasPrefix("host_") ? "Projects live in the board, which isn't open right now. Ask the user to open it, then try again." : "Browsers run in the board, which isn't open right now. Ask the user to open it, then try again.")
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

    // MARK: Images

    /// Adds an image and saves it; boards other than `sender` hear of it.
    func insertImage(_ record: ImageRecord, from sender: CoreBoard? = nil) {
        images.append(record)
        bus.register(ImageElement(id: record.id, store: self))
        try? database?.saveImage(record)
        broadcast(.imageAdded(record), except: sender)
    }

    /// Changes an image in place and saves it; boards other than `sender` hear of it. A new
    /// `file` deletes the old one.
    func updateImage(_ id: UUID, from sender: CoreBoard? = nil, _ change: (inout ImageRecord) -> Void) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let before = images[index]
        change(&images[index])
        guard images[index] != before else { return }
        if images[index].file != before.file { ImageFiles.remove(before.file, in: dataFolder) }
        try? database?.saveImage(images[index])
        broadcast(.imageUpdated(images[index]), except: sender)
    }

    /// Forgets an image, its lines and its file.
    func removeImage(_ id: UUID, from sender: CoreBoard? = nil) {
        guard let record = image(id) else { return }
        bus.remove(element: id)
        images.removeAll { $0.id == id }
        try? database?.deleteImage(id: id)
        ImageFiles.remove(record.file, in: dataFolder)
        broadcast(.imageRemoved(id), except: sender)
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
        guard let executable = AgentCatalog.locate(provider.executable, in: searchPath) else {
            if let install = provider.installCommand {
                session.fail(L("\(provider.title) is not installed. Install it in a terminal with “\(install)”, then click this card."))
            } else {
                session.fail(L("Could not find “\(provider.executable)” in your PATH."))
            }
            return
        }
        var environment = provider.environment(ProcessInfo.processInfo.environment)
        // Found outside the PATH: its folder joins it, for scripts run through `env node` and the like.
        let folder = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = searchPath.split(separator: ":").contains(Substring(folder)) ? searchPath : searchPath + ":" + folder
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
        // A permission prompt counts whether or not it said anything: a message typed in now
        // could answer it.
        pendingQuestions[id] != nil || attention.contains { $0.id == id && $0.needsUser }
    }

    /// `recipient` stopped before `sender`'s message went in: the sender hears so.
    fileprivate func undelivered(from sender: UUID, to recipient: String) {
        agentEndpoints[sender]?.notice("Your message to \(BoardName.quoted(recipient)) wasn't delivered: it stopped before it could read it.")
    }

    private func releaseHeldMessages() {
        for endpoint in agentEndpoints.values { endpoint.deliverNext() }
    }
}

/// The board of an element of one organization's worktree; see `MessageBus.elements(onBoardOf:)`.
func boardKey(_ worktree: String, _ organization: UUID) -> String { worktree + "\u{0}" + organization.uuidString }

/// An agent as the message bus sees it: a message is typed into its terminal as a prompt.
@MainActor
final class AgentEndpoint: MessageEndpoint {
    let id: UUID
    private weak var store: Orchestrator?
    /// Prompts waiting their turn: each is pasted and submitted before the next, so two
    /// arriving together don't run into one line. Agents' messages waiting in a row go in as
    /// one prompt that names each sender.
    private var outbox: [Queued] = []
    private struct Queued {
        var text: String
        /// Typed in the card's composer: given back to the board, never dropped silently.
        let fromUser: Bool
        /// The agent that sent it, told when it can't be delivered.
        let sender: UUID?
        /// The sending agent's name, quoted; `text` is then what it said, without a header.
        var from: String? = nil

        /// The prompt for agents' messages delivered together, in the order they came.
        static func prompt(_ messages: [(name: String, text: String)]) -> String {
            if messages.count == 1, let only = messages.first {
                return "Message from \(only.name) (if it needs an answer, reply with send_message to \(only.name)):\n\n\(only.text)"
            }
            let said = messages.map { "Message from \($0.name):\n\n\($0.text)" }
            return "\(messages.count) messages arrived together (reply with send_message to each sender that needs an answer).\n\n\(said.joined(separator: "\n\n"))"
        }
    }
    private var delivering = false
    /// An agent's message just came: more may follow within `gather`, to go in with it.
    private var gathering = false
    /// How long an agent's message waits for others to go in with it.
    private static let gather = 0.5
    /// What the user types in the terminal meanwhile: held between a paste and its Enter, and
    /// whether the line holds their unsent text, which a paste would join.
    var line = TerminalLine()
    /// When the user last typed in the terminal.
    private var lastKey = Date.distantPast
    private var idleCheckScheduled = false
    /// Delivers even over the user's half-typed line, until the outbox empties (Deliver now).
    private var forced = false
    /// Between the paste and the Enter that submits it: sent together, the agent may read the
    /// Enter as part of the pasted text.
    private static let submitDelay = 0.25
    /// A line left untouched this long no longer holds messages back: a key the program took
    /// without Enter (a menu) must not keep them forever.
    static let idleLimit: TimeInterval = 30
    /// Messages one agent can have waiting; past it senders are told it can't take more.
    static let maxQueued = 20

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .agent }
    var board: String? { store?.record(id).map { boardKey($0.worktree, $0.organizationID) } }

    /// Why its program can't take a prompt, or nil.
    private var programReason: String? {
        switch store?.session(id)?.state {
        case .running: nil
        case .starting: "it is still starting"
        case .exited: "it exited"
        case .failed: "it failed to start"
        case .stopped: "it was stopped"
        case nil: "it hasn't started yet"
        }
    }

    var unavailableReason: String? {
        programReason ?? (outbox.count >= Self.maxQueued ? "it already has \(Self.maxQueued) messages waiting" : nil)
    }

    /// Why the last message given to it waits instead of going in, or nil when nothing waits.
    var queueNote: String? {
        guard !outbox.isEmpty else { return nil }
        if store?.isAwaitingDeveloper(id) == true { return "they are waiting on their user" }
        if line.hasDraft && !forced {
            return "their user is typing in their terminal; it goes in once they submit, or after \(Int(Self.idleLimit)) seconds without typing"
        }
        // Only the moment messages are gathered for: as good as delivered.
        if gathering, !delivering, outbox.allSatisfy({ $0.from != nil }) { return nil }
        return "it goes in after the messages before it"
    }

    /// What the user wrote in the card's composer, typed in as their own prompt. One it can't
    /// take goes back to the board, which puts it back in the composer.
    func prompt(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let reason = programReason ?? (store?.isAwaitingDeveloper(id) == true ? "it is waiting for your answer" : nil)
            ?? (outbox.count >= Self.maxQueued ? "it already has \(Self.maxQueued) messages waiting" : nil) {
            return giveBack(text, reason)
        }
        outbox.append(Queued(text: text, fromUser: true, sender: nil))
        deliverNext()
    }

    func receive(_ message: Message, from sender: any BoardElement) {
        let name = BoardName.quoted(sender.name)
        outbox.append(Queued(text: message.text, fromUser: false, sender: sender.id, from: name))
        // Agents answering at once (a broadcast's replies) reach it as one prompt, not a row of them.
        if !gathering {
            gathering = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.gather) { [weak self] in
                self?.gathering = false
                self?.deliverNext()
            }
        }
        reportHeld()
    }

    /// A note from the board itself (a message of theirs that couldn't be delivered).
    func notice(_ text: String) {
        guard programReason == nil else { return }
        outbox.append(Queued(text: text, fromUser: false, sender: nil))
        deliverNext()
    }

    private func giveBack(_ text: String, _ reason: String) {
        store?.broadcast(.promptReturned(id: id, text: text, reason: reason))
    }

    /// The user's keystrokes on their way to the terminal: what to pass on now. Keys answering
    /// the program's own question (a permission menu) don't write the line.
    func userTyped(_ bytes: [UInt8]) -> [UInt8] {
        let answering = store?.isAwaitingDeveloper(id) == true
        let passed = line.typed(bytes, delivering: delivering, writesLine: !answering)
        lastKey = Date()
        if line.hasDraft { scheduleIdleCheck() } else { DispatchQueue.main.async { [weak self] in self?.deliverNext() } }
        reportHeld()
        return passed
    }

    /// Delivers what waits even though the user has text on the terminal's line; that text is
    /// submitted with the first one.
    func deliverHeld() {
        forced = true
        deliverNext()
    }

    /// The program started, stopped or ended. A new program has a new, empty line; what waited
    /// for one that ended goes back (the composer's) or is reported to its sender, never typed
    /// into the next program out of context.
    func sessionChanged(_ status: SessionStatus) {
        line = TerminalLine()
        forced = false
        if status.processID == nil, status.state != .starting {
            let dropped = outbox
            outbox = []
            for item in dropped {
                if item.fromUser {
                    giveBack(item.text, "it stopped before it could read it")
                } else if let sender = item.sender {
                    store?.undelivered(from: sender, to: name)
                }
            }
        }
        reportHeld()
    }

    private func scheduleIdleCheck() {
        guard !idleCheckScheduled, !outbox.isEmpty else { return }
        idleCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLimit + 0.1) { [weak self] in
            self?.idleCheckScheduled = false
            self?.deliverNext()
        }
    }

    /// Held while the agent waits on the developer; the store calls again once that changes.
    func deliverNext() {
        defer { reportHeld() }
        if outbox.isEmpty { forced = false }
        let idle = Date().timeIntervalSince(lastKey) >= Self.idleLimit
        guard !delivering, !outbox.isEmpty, let store, !store.isAwaitingDeveloper(id), let session = store.session(id),
              programReason == nil, !(gathering && outbox[0].from != nil) else { return }
        guard forced || idle || !line.hasDraft else { return scheduleIdleCheck() }
        // Whatever was on the line goes in with this prompt.
        line = TerminalLine()
        delivering = true
        var next = outbox.removeFirst()
        if let name = next.from {
            var messages = [(name: name, text: next.text)]
            while let more = outbox.first, let name = more.from {
                messages.append((name, more.text))
                outbox.removeFirst()
            }
            next.text = Queued.prompt(messages)
        }
        let prompt = TerminalLine.pasteable(next.text, bracketed: session.withTerminal { $0.modes.contains(.bracketedPaste) })
        // A slash command is typed, not pasted, so the program runs it as if keyed in.
        session.send(next.fromUser && TerminalLine.isCommand(prompt) ? Array(prompt.utf8) : session.withTerminal { $0.encodePaste(prompt) })
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) { [weak self] in
            session.send([0x0D])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) {
                guard let self else { return }
                self.delivering = false
                // What the user typed meanwhile goes in now, after the Enter.
                let typed = self.line.releaseHeld()
                if !typed.isEmpty { session.send(typed) }
                self.deliverNext()
            }
        }
    }

    private var reportedHeld = 0

    /// Tells the boards how many messages wait on the user's terminal line.
    private func reportHeld() {
        let held = line.hasDraft && !forced && programReason == nil ? outbox.count : 0
        guard held != reportedHeld else { return }
        reportedHeld = held
        store?.broadcast(.held(id: id, count: held))
    }
}

/// The user's side of an agent's terminal line, as the core sees their keystrokes: what they
/// typed and haven't submitted, edited the way a shell or Claude Code's input would.
struct TerminalLine {
    private var pending = ""
    /// Lone Escapes in a row; two clear the input.
    private var escapes = 0
    private var held: [UInt8] = []

    /// Whether unsent text sits on the line: a paste now would join it.
    var hasDraft: Bool { pending.contains { !$0.isWhitespace } }

    private static let pasteStart: [UInt8] = Array("\u{1b}[200~".utf8)

    /// Records `bytes`; returns what passes now. While `delivering`, all of it waits. With
    /// `writesLine` false (the program asked something), keys answer it and leave the line be.
    mutating func typed(_ bytes: [UInt8], delivering: Bool, writesLine: Bool = true) -> [UInt8] {
        if writesLine { record(bytes) }
        guard delivering else { return bytes }
        held += bytes
        return []
    }

    private mutating func record(_ bytes: [UInt8]) {
        if bytes.starts(with: Self.pasteStart) {
            // A paste is text on the line, bracketed or not.
            escapes = 0
            pending += "\u{FFFC}"
            return
        }
        if bytes == [0x1B] {
            escapes += 1
            if escapes >= 2 { pending = ""; escapes = 0 }
            return
        }
        escapes = 0
        // Other escape sequences (arrows, focus and mouse reports) don't write on the line.
        guard bytes.first != 0x1B else { return }
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x0D:
                // A backslash before Enter continues the input on a new line.
                if pending.last == "\\" { pending.removeLast(); pending += "\n" } else { pending = "" }
            case 0x03, 0x15:
                pending = ""
            case 0x7F, 0x08:
                if !pending.isEmpty { pending.removeLast() }
            case 0x17:
                while pending.last?.isWhitespace == true { pending.removeLast() }
                while let last = pending.last, !last.isWhitespace { pending.removeLast() }
            case 0..<0x20:
                break
            default:
                pending.unicodeScalars.append(scalar)
            }
        }
    }

    mutating func releaseHeld() -> [UInt8] {
        defer { held = [] }
        return held
    }

    /// `text` safe to paste: no control characters but line breaks and tabs, and on one line
    /// when the program doesn't bracket pastes (each break would be an Enter).
    /// `/effort high`, `/compact`…: one line starting with a slash.
    static func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/") && !text.contains(where: \.isNewline)
    }

    static func pasteable(_ text: String, bracketed: Bool) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.properties.generalCategory == .control)
        }
        let clean = String(String.UnicodeScalarView(kept))
        return bracketed ? clean : clean.split(whereSeparator: \.isNewline).joined(separator: " ")
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
    var board: String? { store?.record(id).map { boardKey($0.worktree, $0.organizationID) } }

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
    var board: String? { store?.postIt(id).map { boardKey($0.worktree, $0.organizationID) } }

    var detail: String? {
        guard let record = store?.postIt(id) else { return nil }
        let lines = record.text.split(whereSeparator: \.isNewline).count
        return "shared markdown note, \(lines == 0 ? "empty" : "\(lines) line\(lines == 1 ? "" : "s")"); read with postit_read"
    }
}

/// An image as the message bus sees it: reachable along lines, seen with `image_read`.
@MainActor
private final class ImageElement: BoardElement {
    let id: UUID
    private weak var store: Orchestrator?

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String { store?.image(id)?.name ?? "" }
    var kind: ElementKind { store?.image(id)?.isVideo == true ? .video : .image }
    var board: String? { store?.image(id).map { boardKey($0.worktree, $0.organizationID) } }

    var detail: String? {
        guard let record = store?.image(id) else { return nil }
        let size = "\(Int(record.pixelSize.width))×\(Int(record.pixelSize.height))"
        return record.duration.map { "\(size), \(Int($0.rounded())) s; read with video_read" } ?? size
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
    var board: String? { store?.element(id).map { info in info.organization.map { boardKey(info.worktree, $0) } ?? info.worktree } }
}
