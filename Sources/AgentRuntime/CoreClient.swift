import Darwin
import Foundation

/// The board's connection to the core: sends requests, and hands each session's output,
/// snapshots and status to the `AgentSession` that mirrors it.
public final class CoreClient: @unchecked Sendable {
    private let socket: CoreSocket
    private let queue = DispatchQueue(label: "agentboard.core-client", qos: .userInitiated)
    private let lock = NSLock()
    private var mirrors: [UUID: Weak] = [:]
    private var _known: [UUID: SessionStatus] = [:]
    private let welcomed = DispatchSemaphore(value: 0)
    private var welcome: CoreProtocol.Versions?
    private var _connected = true
    private var _service: Data?
    private var serviceHandler: ((Data) -> Void)?
    /// Service frames that came before anyone listened for them.
    private var serviceBacklog: [Data] = []

    /// Called on the main queue if the core goes away.
    public var onDisconnect: (() -> Void)?

    /// Whether `session` mirrors one of this core's.
    public func mirrors(_ session: AgentSession, id: UUID) -> Bool { lock.withLock { mirrors[id]?.session === session } }

    private struct Weak { weak var session: AgentSession? }

    private init(fd: Int32) {
        socket = CoreSocket(fd: fd, queue: queue)
        socket.onFrame = { [weak self] kind, payload in self?.received(kind, payload) }
        socket.onClose = { [weak self] in self?.lost() }
    }

    /// Why `open` gave no connection.
    public enum Failure: Error, Equatable {
        /// No core answered, and none could be launched.
        case noCore
        /// The core speaks no version this build does: `core` is what it speaks.
        case incompatible(core: CoreProtocol.Versions)
    }

    /// The protocol version agreed on with the core.
    public var version: Int { lock.withLock { welcome?.version ?? 0 } }

    /// `open`, without saying why it failed.
    public static func connect(socketPath: String = CoreProtocol.socketPath, launching executable: URL? = nil,
                               environment: [String: String] = [:], timeout: Double = 3) -> CoreClient? {
        try? open(socketPath: socketPath, launching: executable, environment: environment, timeout: timeout).get()
    }

    /// Connects to the core at `socketPath`, launching `executable` first when none answers,
    /// with `environment` added to this process's. Blocks until the core said hello back (or
    /// `timeout` passed): call it off the main thread. `versions` are the protocol versions
    /// this side speaks (another build's, in tests).
    public static func open(socketPath: String = CoreProtocol.socketPath, launching executable: URL? = nil,
                            environment: [String: String] = [:], timeout: Double = 3,
                            versions: CoreProtocol.Versions = CoreProtocol.versions) -> Result<CoreClient, Failure> {
        let deadline = Date().addingTimeInterval(timeout)
        var fd = try? UnixSocket.connect(to: socketPath)
        if fd == nil, let executable {
            guard launch(executable, socketPath: socketPath, environment: environment) else { return .failure(.noCore) }
            while fd == nil, Date() < deadline {
                usleep(20_000)
                fd = try? UnixSocket.connect(to: socketPath)
            }
        }
        guard let fd else { return .failure(.noCore) }
        let client = CoreClient(fd: fd)
        client.socket.start()
        client.socket.send(CoreRequest.hello(version: versions.version, oldest: versions.oldest))
        guard client.welcomed.wait(timeout: .now() + max(0.1, deadline.timeIntervalSinceNow)) == .success,
              let welcome = client.lock.withLock({ client.welcome }) else {
            client.socket.close()
            return .failure(.noCore)
        }
        // The core picked the version; one this side doesn't speak means there was none.
        guard (versions.oldest...versions.version).contains(welcome.version) else {
            client.socket.close()
            return .failure(.incompatible(core: welcome))
        }
        return .success(client)
    }

    /// Starts the core in its own session (setsid), so it outlives the board and isn't hit by
    /// signals sent to the board's process group (Ctrl+C in the terminal that launched it).
    private static func launch(_ executable: URL, socketPath: String, environment extra: [String: String]) -> Bool {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The data folder's log for the board's own core; next to the socket for any other.
        let logFolder = extra["AGENTBOARD_HOME"] ?? (socketPath == CoreProtocol.socketPath ? DataFolder.url.path : folder)
        try? FileManager.default.createDirectory(atPath: logFolder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let log = (logFolder as NSString).appendingPathComponent("core.log")
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing of the board's (PTYs, sockets) leaks into the core: only the three below.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        environment["AGENTBOARD_CORE_SOCKET"] = socketPath
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0 else { return false }
        // Reaped once it exits, so it doesn't linger as a zombie while this process runs.
        let child = pid
        Thread.detachNewThread { _ = waitpid(child, nil, 0) }
        return true
    }

    /// Sessions the core had when this board connected, by id.
    public var known: [UUID: SessionStatus] { lock.withLock { _known } }

    public var isConnected: Bool { lock.withLock { _connected } }

    /// The core service's state for this board, as it came with the welcome.
    public var serviceState: Data? { lock.withLock { _service } }

    /// Takes the core service's frames from now on, on the client's queue, starting with any
    /// that arrived since the welcome.
    public func onService(_ handler: @escaping (Data) -> Void) {
        let backlog = lock.withLock { () -> [Data] in
            serviceHandler = handler
            defer { serviceBacklog.removeAll() }
            return serviceBacklog
        }
        backlog.forEach(handler)
    }

    /// Sends the core service a frame.
    public func send(service payload: Data) {
        socket.send(.service, Array(payload))
    }

    /// Ends every program on the core and stops it. Returns once the request is on its way,
    /// so it can be sent while the board quits.
    public func shutdown() {
        request(.shutdown)
        queue.sync {}
    }

    /// Ends the program of a session no board mirrors and forgets it (see `AgentSession.close`).
    public func close(_ id: UUID, grace: Double?) {
        request(.close(id: id, grace: grace))
        unregister(id)
    }

    /// Leaves the core; its programs keep running.
    public func disconnect() {
        socket.close()
    }

    func register(_ session: AgentSession, id: UUID) {
        lock.withLock { mirrors[id] = Weak(session: session) }
    }

    /// Stops mirroring session `id` here; the core keeps it.
    public func unregister(_ id: UUID) {
        lock.withLock {
            mirrors[id] = nil
            _known[id] = nil
        }
    }

    func request(_ request: CoreRequest) {
        socket.send(request)
    }

    func input(_ bytes: [UInt8], to id: UUID) {
        socket.send(.data, id: id, bytes)
    }

    // MARK: On `queue`

    private func mirror(_ id: UUID) -> AgentSession? { lock.withLock { mirrors[id]?.session } }

    private func received(_ kind: FrameKind, _ payload: ArraySlice<UInt8>) {
        switch kind {
        case .control:
            guard let event = try? JSONDecoder().decode(CoreEvent.self, from: Data(payload)) else { return }
            switch event {
            case .welcome(let version, let oldest, let sessions, let service):
                lock.withLock {
                    welcome = CoreProtocol.Versions(version: version, oldest: oldest ?? version)
                    _known = sessions
                    _service = service
                }
                welcomed.signal()
            case .status(let id, let status):
                lock.withLock { if _known[id] != nil { _known[id] = status } }
                mirror(id)?.coreStatus(status)
            }
        case .data:
            guard let id = UUID(bytes: payload), let session = mirror(id) else { return }
            payload.dropFirst(16).withUnsafeBytes { session.coreReceived($0) }
        case .snapshot:
            guard let id = UUID(bytes: payload), let session = mirror(id) else { return }
            session.coreSnapshot(Array(payload.dropFirst(16)))
        case .service:
            let data = Data(payload)
            let handler = lock.withLock { () -> ((Data) -> Void)? in
                if serviceHandler == nil { serviceBacklog.append(data) }
                return serviceHandler
            }
            handler?(data)
        }
    }

    /// The sessions mirrored here keep what they last showed: whoever reconnects decides what
    /// becomes of them.
    private func lost() {
        lock.withLock { _connected = false }
        welcomed.signal()
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
    }
}
