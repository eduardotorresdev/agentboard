import Darwin
import Foundation

/// What the core does beyond running sessions: the board's cards, the lines between them and
/// the agents' tools (see `Orchestrator`). Called on the server's queue, which must then be the
/// main queue.
public protocol CoreService: AnyObject {
    /// A board said hello; the answer is the state it gets with its welcome.
    @MainActor func boardConnected(_ board: CoreBoard) -> Data?
    @MainActor func received(_ payload: Data, from board: CoreBoard)
    @MainActor func boardDisconnected(_ board: CoreBoard)
    /// A newer core is taking over: finish what can't be handed over half done. The sessions
    /// and boards are served meanwhile.
    @MainActor func prepareHandOff() async
    /// What the newer core needs to carry on, given to it as `Inheritance.service`, with
    /// descriptors of its own (duplicates; the receiver gets them as `serviceDescriptors`).
    @MainActor func handOffState() -> (state: Data?, descriptors: [Int32])
    /// Everything was handed to a newer core: stop serving, without ending any program.
    @MainActor func handedOff()
    /// The newer core didn't take it: carry on as before `prepareHandOff`.
    @MainActor func handOffFailed()
}

extension CoreService {
    @MainActor public func prepareHandOff() async {}
    @MainActor public func handOffState() -> (state: Data?, descriptors: [Int32]) { (nil, []) }
    @MainActor public func handedOff() {}
    @MainActor public func handOffFailed() {}
}

/// The core: owns the agents' sessions and serves them to boards over a Unix socket. Programs
/// keep running while no board is connected; a board that connects later attaches to them.
public final class CoreServer: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private var listener: DispatchSourceRead?
    private var listenerFD: Int32 = -1
    private var handingOff = false
    private var sessions: [UUID: Hosted] = [:]
    /// Sessions being closed, kept until their program has exited.
    private var closing: [UUID: Hosted] = [:]
    private var clients: [ObjectIdentifier: CoreBoard] = [:]
    private var boardsAccepted = 0
    /// Logs each session a board attaches to as well (`AGENTBOARD_CORE_VERBOSE=1`).
    private let verbose = ProcessInfo.processInfo.environment["AGENTBOARD_CORE_VERBOSE"] == "1"
    private var idleChecks = 0
    /// How long the core lingers with no board connected and no program running.
    private let idleTimeout: Double

    /// Called on the server's queue when the core should exit: asked to, or idle for too long.
    public var onExit: (() -> Void)?
    /// Called on the server's queue once a newer core took everything over: exit without
    /// removing the socket, which is the new core's now.
    public var onHandedOff: (() -> Void)?
    /// Called with what's worth a line in the core's log.
    public var onLog: ((String) -> Void)?
    /// The protocol versions this core speaks (another build's, in tests).
    public var versions = CoreProtocol.versions
    /// The lock file that makes this the only core on the socket, handed to a newer core with
    /// the rest. None, and no handing over.
    public var lock: Int32 = -1
    /// Set before `start`. Its frames are handled in order with the sessions' requests, so the
    /// server then runs on the main queue (`queue: .main`).
    public weak var service: CoreService?

    public init(socketPath: String = CoreProtocol.socketPath, idleTimeout: Double = 60,
                queue: DispatchQueue = DispatchQueue(label: "agentboard.core", qos: .userInitiated)) {
        path = socketPath
        self.idleTimeout = idleTimeout
        self.queue = queue
    }

    /// Serves on the socket, or on `fd` when it was inherited already listening.
    public func start(listening fd: Int32? = nil) throws {
        let fd = try fd ?? UnixSocket.listen(at: path)
        listenerFD = fd
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in self?.acceptAll(fd) }
        listener.setCancelHandler { close(fd) }
        listener.resume()
        self.listener = listener
        scheduleIdleCheck()
    }

    public func stop() {
        onQueue {
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.socket.close() }
            clients.removeAll()
        }
    }

    private func onQueue(_ body: () -> Void) {
        if queue === DispatchQueue.main, Thread.isMainThread { body() } else { queue.sync(execute: body) }
    }

    /// Carries on the sessions an older core handed over. Call before `start`.
    public func adopt(_ sessions: [(id: UUID, handoff: AgentSession.Handoff)]) {
        onQueue {
            for (id, handoff) in sessions { self.sessions[id] = Hosted(id: id, session: AgentSession(adopting: handoff)) }
        }
    }

    // MARK: For the service (on `queue`)

    public var boards: [CoreBoard] { Array(clients.values) }

    public func session(_ id: UUID) -> AgentSession? { sessions[id]?.session }

    /// Session `id`, created at `cols`×`rows` when the core doesn't have it. `board`, when
    /// given, is attached to it (status, then snapshot, then output) unless it already is.
    @discardableResult
    public func openSession(_ id: UUID, cols: Int, rows: Int, for board: CoreBoard?) -> AgentSession {
        if let hosted = sessions[id] {
            if let board, !hosted.has(board) { attach(board, to: hosted) }
            return hosted.session
        }
        let hosted = Hosted(id: id, session: AgentSession(cols: cols, rows: rows))
        sessions[id] = hosted
        if let board { attach(board, to: hosted) }
        return hosted.session
    }

    /// Ends the program of session `id` (`grace` as in `AgentSession.terminate`, or SIGHUP
    /// when nil) and forgets the session.
    public func closeSession(_ id: UUID, grace: Double?) {
        guard let hosted = sessions.removeValue(forKey: id) else { return }
        hosted.removeAll()
        guard hosted.session.processID != nil else { return }
        closing[id] = hosted
        let forget: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.closing[id] = nil }
        }
        if let grace {
            hosted.session.terminate(grace: grace, then: forget)
        } else {
            hosted.onEnded = forget
            hosted.session.stop()
        }
    }

    // MARK: On `queue`

    private func acceptAll(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            boardsAccepted += 1
            let client = CoreBoard(socket: CoreSocket(fd: connection, queue: queue), number: boardsAccepted)
            let key = ObjectIdentifier(client)
            clients[key] = client
            client.socket.onFrame = { [weak self, weak client] kind, payload in
                guard let self, let client else { return }
                self.received(kind, payload, from: client)
            }
            client.socket.onClose = { [weak self] in self?.disconnected(key) }
            client.socket.start()
        }
    }

    private func disconnected(_ key: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: key) else { return }
        if client.version != nil { onLog?("board \(client.number) went away") }
        for hosted in sessions.values { hosted.remove(client) }
        if let service { MainActor.assumeIsolated { service.boardDisconnected(client) } }
    }

    private func received(_ kind: FrameKind, _ payload: ArraySlice<UInt8>, from client: CoreBoard) {
        switch kind {
        case .control:
            guard let request = try? JSONDecoder().decode(CoreRequest.self, from: Data(payload)) else { return }
            handle(request, from: client)
        case .data:
            guard let id = UUID(bytes: payload) else { return }
            sessions[id]?.session.send(Array(payload.dropFirst(16)))
        case .service:
            guard let service else { return }
            MainActor.assumeIsolated { service.received(Data(payload), from: client) }
        case .snapshot:
            break
        }
    }

    private func handle(_ request: CoreRequest, from client: CoreBoard) {
        switch request {
        case .hello(let version, let oldest):
            guard let agreed = versions.agreed(with: .init(version: version, oldest: oldest ?? version)) else {
                // It hangs up on seeing the version; closing here could drop the welcome unsent.
                return client.socket.send(CoreEvent.welcome(version: versions.version, oldest: versions.oldest, sessions: [:], service: nil))
            }
            client.version = agreed
            onLog?("board \(client.number) connected, protocol \(agreed)")
            let state = service.flatMap { service in MainActor.assumeIsolated { service.boardConnected(client) } }
            client.socket.send(CoreEvent.welcome(version: agreed, oldest: versions.oldest, sessions: sessions.mapValues(\.session.status),
                                                 service: state))
        case .start(let id, let spec, let cols, let rows):
            let hosted: Hosted
            if let existing = sessions[id] {
                hosted = existing
                if !hosted.has(client) { attach(client, to: hosted) }
            } else {
                hosted = Hosted(id: id, session: AgentSession(cols: cols, rows: rows))
                sessions[id] = hosted
                hosted.add(client)
            }
            hosted.session.resize(cols: cols, rows: rows)
            hosted.session.start(spec)
        case .attach(let id):
            guard let hosted = sessions[id] else {
                return client.socket.send(CoreEvent.status(id: id, status: SessionStatus(state: .stopped, processID: nil, exitCode: nil)))
            }
            attach(client, to: hosted)
        case .resize(let id, let cols, let rows):
            sessions[id]?.session.resize(cols: cols, rows: rows)
        case .observe(let id, let observed):
            sessions[id]?.observe(observed, by: client)
        case .terminate(let id, let grace):
            guard let hosted = sessions[id] else { return }
            // An exit already reported changes no status; send one anyway so the board's wait ends.
            hosted.session.terminate(grace: grace) { [weak hosted] in hosted?.broadcastStatus() }
        case .stop(let id):
            sessions[id]?.session.stop()
        case .annotate(let id, let text, let freshLine):
            sessions[id]?.session.annotate(text, freshLine: freshLine)
        case .close(let id, let grace):
            closeSession(id, grace: grace)
        case .shutdown:
            shutDown()
        case .takeOver:
            handOff(to: client)
        }
    }

    /// Gives every session, the lock and the listening socket to the newer core on `client`
    /// (see `CoreHandoff`), then exits; carries on as before if that fails. Once the service is
    /// ready, blocks the queue throughout, so no board request falls in between.
    private func handOff(to client: CoreBoard) {
        guard lock >= 0, listener != nil, !handingOff, let connection = client.socket.detach() else {
            onLog?("refused to hand over: lock \(lock), listening \(listener != nil), handing over already \(handingOff)")
            return client.socket.close()
        }
        clients[ObjectIdentifier(client)] = nil
        handingOff = true
        var accepted = CoreHandoff.accepted
        guard write(connection, &accepted, 1) == 1 else {
            handingOff = false
            close(connection)
            return
        }
        guard let service else { return transfer(on: connection) }
        Task { @MainActor in
            await service.prepareHandOff()
            self.transfer(on: connection)
        }
    }

    private func transfer(on connection: Int32) {
        defer {
            close(connection)
            handingOff = false
        }
        let listening = dup(listenerFD)
        guard listening >= 0 else { return }
        listener?.cancel()
        listener = nil
        // Being closed: the old core would have ended them anyway.
        for hosted in closing.values {
            if let pid = hosted.session.processID { kill(-pid, SIGKILL) }
        }
        let ordered = Array(sessions)
        let handoffs = ordered.map { $0.value.session.handOff() }
        let state: (state: Data?, descriptors: [Int32]) = service.map { service in MainActor.assumeIsolated { service.handOffState() } } ?? (nil, [])
        let manifest = HandoffManifest(
            processID: getpid(),
            sessions: zip(ordered, handoffs).compactMap { entry, handoff in
                handoff.map {
                    .init(id: entry.key, running: $0.master >= 0, processID: $0.processID, status: $0.status, snapshot: Data($0.snapshot),
                          input: Data($0.input))
                }
            },
            service: state.state, serviceDescriptors: state.descriptors.count)
        let masters = handoffs.compactMap { $0?.master }.filter { $0 >= 0 }
        let sent = CoreHandoff.send(manifest, fds: [lock, listening] + masters + state.descriptors, on: connection) { [weak self] in
            self?.onLog?("handing over: \($0)")
        }
        onLog?(sent ? "handed \(manifest.sessions.count) sessions over" : "the newer core didn't take the handoff; carrying on")
        if sent {
            // Duplicates: the new core has its own now, and here they'd only keep it all open.
            ([listening] + masters + state.descriptors).forEach { _ = close($0) }
            if let service { MainActor.assumeIsolated { service.handedOff() } }
            clients.values.forEach { $0.socket.close() }
            clients.removeAll()
            onExit = nil
            onHandedOff?()
            return
        }
        // The new core didn't take it: carry on here, with what it would have had.
        if let service { MainActor.assumeIsolated { service.handOffFailed() } }
        for (entry, handoff) in zip(ordered, handoffs) {
            guard let handoff else { continue }
            let hosted = Hosted(id: entry.key, session: AgentSession(adopting: handoff))
            entry.value.subscribers.forEach(hosted.add)
            sessions[entry.key] = hosted
        }
        try? start(listening: listening)
    }

    /// Sends `client` the session's status and then its screen, and from then on its output.
    /// The snapshot is taken with the terminal locked and the client subscribed in the same
    /// step, so no output falls between them or arrives twice.
    private func attach(_ client: CoreBoard, to hosted: Hosted) {
        if verbose { onLog?("board \(client.number) attached to \(hosted.id)") }
        client.socket.send(CoreEvent.status(id: hosted.id, status: hosted.session.status))
        hosted.session.withTerminal { terminal in
            client.socket.send(.snapshot, id: hosted.id, terminal.snapshot())
            hosted.add(client)
        }
    }

    private func shutDown() {
        let running = (Array(sessions.values) + Array(closing.values)).filter { $0.session.processID != nil }
        // Held until they exit: a session released earlier would never reap its program.
        for hosted in sessions.values { closing[hosted.id] = hosted }
        sessions.removeAll()
        guard !running.isEmpty else { return exit() }
        var remaining = running.count
        for hosted in running {
            hosted.removeAll()
            hosted.session.terminate(grace: 2) { [weak self] in
                self?.queue.async {
                    remaining -= 1
                    if remaining == 0 { self?.exit() }
                }
            }
        }
        // Whatever ignores even SIGKILL's aftermath must not keep the core alive.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in self?.exit() }
    }

    private func exit() {
        guard let onExit else { return }
        self.onExit = nil
        listener?.cancel()
        listener = nil
        onExit()
    }

    /// Exits after `idleTimeout` with no board connected and nothing running. Programs that
    /// ended are then lost, which is what a relaunch without a core would do anyway.
    private func scheduleIdleCheck() {
        let interval = max(0.05, idleTimeout / 4)
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.listener != nil else { return }
            let idle = self.clients.isEmpty && self.closing.isEmpty && self.sessions.values.allSatisfy { $0.session.processID == nil }
            self.idleChecks = idle ? self.idleChecks + 1 : 0
            if self.idleChecks >= 4 { return self.exit() }
            self.scheduleIdleCheck()
        }
    }
}

/// A board connected to the core.
public final class CoreBoard: Hashable, @unchecked Sendable {
    let socket: CoreSocket
    /// The protocol version agreed on with it, once it said hello.
    public internal(set) var version: Int?
    /// In the order the core accepted boards, for its log.
    let number: Int
    init(socket: CoreSocket, number: Int) {
        self.socket = socket
        self.number = number
    }

    /// Sends the board a frame for its side of the service.
    public func send(_ payload: Data) { socket.send(.service, Array(payload)) }

    public static func == (a: CoreBoard, b: CoreBoard) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A session on the core and the boards mirroring it. Output is fanned out from the session's
/// queue, so the subscriber list has its own lock.
private final class Hosted {
    let id: UUID
    let session: AgentSession
    private let lock = NSLock()
    private var subscribersByID: [ObjectIdentifier: CoreBoard] = [:]
    private var observers: Set<ObjectIdentifier> = []
    /// Called once the program has ended (set by `close`).
    var onEnded: (() -> Void)?

    init(id: UUID, session: AgentSession) {
        self.id = id
        self.session = session
        session.onOutput = { [weak self] bytes in self?.broadcast(bytes) }
        session.onStatus = { [weak self] status in
            guard let self else { return }
            self.send(CoreEvent.status(id: id, status: status))
            if status.processID == nil, status.state != .starting, let ended = self.lock.withLock({ self.onEnded }) {
                self.lock.withLock { self.onEnded = nil }
                ended()
            }
        }
    }

    var subscribers: [CoreBoard] { lock.withLock { Array(subscribersByID.values) } }

    func has(_ client: CoreBoard) -> Bool { lock.withLock { subscribersByID[ObjectIdentifier(client)] != nil } }

    func add(_ client: CoreBoard) { lock.withLock { subscribersByID[ObjectIdentifier(client)] = client } }

    func remove(_ client: CoreBoard) {
        let key = ObjectIdentifier(client)
        let observed = lock.withLock { () -> Bool in
            subscribersByID[key] = nil
            observers.remove(key)
            return !observers.isEmpty
        }
        session.isObserved = observed
    }

    func removeAll() {
        lock.withLock {
            subscribersByID.removeAll()
            observers.removeAll()
        }
        session.isObserved = false
    }

    /// Output is read sooner while any board shows the session.
    func observe(_ observed: Bool, by client: CoreBoard) {
        let key = ObjectIdentifier(client)
        let any = lock.withLock { () -> Bool in
            if observed { observers.insert(key) } else { observers.remove(key) }
            return !observers.isEmpty
        }
        session.isObserved = any
    }

    func broadcastStatus() { send(CoreEvent.status(id: id, status: session.status)) }

    private func broadcast(_ bytes: UnsafeRawBufferPointer) {
        for client in lock.withLock({ Array(subscribersByID.values) }) { client.socket.send(.data, id: id, bytes) }
    }

    private func send(_ event: CoreEvent) {
        for client in lock.withLock({ Array(subscribersByID.values) }) { client.socket.send(event) }
    }
}
