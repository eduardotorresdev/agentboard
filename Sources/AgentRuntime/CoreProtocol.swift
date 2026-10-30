import Foundation

// What the board and the core say to each other over the core's Unix socket.
//
// The core is a separate process that owns the agents' PTYs, so they keep running while the
// board quits, crashes or is rebuilt. The board mirrors each session's terminal: on attaching it
// gets a snapshot, then the same output the core's terminal parses, in the same order.
//
// Frames: a 4-byte big-endian length, then a kind byte, then the payload.
// - `control`: a JSON `CoreRequest` (board → core) or `CoreEvent` (core → board).
// - `data`: a 16-byte session id, then bytes: program output (core → board) or keyboard input
//   (board → core).
// - `snapshot`: a 16-byte session id, then `Terminal.snapshot()` bytes (core → board).
// - `service`: bytes for the core's service (the board's cards, lines and tools; see
//   `CoreService`), both ways. The sessions layer doesn't read them.

public enum CoreProtocol {
    /// What a build speaks: `version`, and every one back to `oldest`. A board and a core use
    /// the newest version both speak (the core picks it, in its welcome); with none in common
    /// they don't talk, and the board says what to do.
    public struct Versions: Sendable, Equatable {
        public var version: Int
        public var oldest: Int

        public init(version: Int, oldest: Int) {
            self.version = version
            self.oldest = oldest
        }

        /// The newest version both speak, if any.
        public func agreed(with other: Versions) -> Int? {
            let version = min(self.version, other.version)
            return version >= max(oldest, other.oldest) ? version : nil
        }
    }

    /// Bumped whenever a message changes. Older peers must keep working one version back, so a
    /// change only adds: optional fields, and requests or events an older peer can ignore
    /// (unknown ones are dropped). Anything else raises `oldest` past the versions it breaks.
    /// 3: `takeOver`, and both sides say the oldest version they speak.
    /// 4: the attention queue (`BoardEvent.attention`, `BoardRequest.dismissAttention`).
    public static let version = 4
    public static let oldest = 2
    public static let versions = Versions(version: version, oldest: oldest)

    /// `AGENTBOARD_CORE_SOCKET`, or `core.sock` in the data folder. A data folder too deep for
    /// a socket path (104 bytes) gets one in this user's temporary folder, named after it.
    public static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["AGENTBOARD_CORE_SOCKET"], !path.isEmpty { return path }
        let folder = DataFolder.url.path
        let path = (folder as NSString).appendingPathComponent("core.sock")
        guard path.utf8.count >= 104 else { return path }
        // FNV-1a: stable across launches, unlike `hashValue`.
        let hash = folder.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("agentboard-\(String(hash, radix: 16)).sock")
    }

    /// Frames larger than this are refused: a corrupt length must not allocate gigabytes.
    static let maximumFrame = 256 * 1024 * 1024
}

enum FrameKind: UInt8 {
    case control = 1
    case data = 2
    case snapshot = 3
    case service = 4
}

/// What a session is doing, as the core reports it.
public struct SessionStatus: Codable, Equatable, Sendable {
    public var state: AgentSession.State
    public var processID: Int32?
    public var exitCode: Int32?

    public init(state: AgentSession.State, processID: Int32?, exitCode: Int32?) {
        self.state = state
        self.processID = processID
        self.exitCode = exitCode
    }
}

enum CoreRequest: Codable {
    /// `oldest`: since 3; a board that doesn't say speaks only `version`.
    case hello(version: Int, oldest: Int?)
    /// Starts (or restarts) the program of session `id`, creating the session if needed; the
    /// sender is attached to it.
    case start(id: UUID, spec: LaunchSpec, cols: Int, rows: Int)
    /// Subscribes to a session the core already has: a status and a snapshot come back.
    case attach(id: UUID)
    case resize(id: UUID, cols: Int, rows: Int)
    /// Whether a board shows the session; the core reads output sooner while any does.
    case observe(id: UUID, observed: Bool)
    /// SIGTERM to the program's group, SIGKILL after `grace` seconds.
    case terminate(id: UUID, grace: Double)
    /// SIGHUP, as when a terminal window closes.
    case stop(id: UUID)
    /// Writes `text` into the session's terminal as if the program printed it (on a fresh
    /// line when `freshLine`), for every board that mirrors it.
    case annotate(id: UUID, text: String, freshLine: Bool)
    /// Ends the program (`grace` as in `terminate`, or SIGHUP when nil) and forgets the session.
    case close(id: UUID, grace: Double?)
    /// Ends every program and exits.
    case shutdown
    /// From a newer core: hand it every session without ending them (see `CoreHandoff`). The
    /// connection leaves frames for the handoff.
    case takeOver
}

enum CoreEvent: Codable {
    /// The answer to `hello`: every session the core has, running or not, and the service's
    /// state for this board.
    /// `version` is the one agreed on, or the core's own when there is none (nothing else
    /// follows then, and the board hangs up). `oldest`: since 3.
    case welcome(version: Int, oldest: Int?, sessions: [UUID: SessionStatus], service: Data?)
    case status(id: UUID, status: SessionStatus)
}

extension LaunchSpec: Codable {
    enum CodingKeys: String, CodingKey { case executable, arguments, environment, directory }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(executable: try container.decode(String.self, forKey: .executable),
                  arguments: try container.decode([String].self, forKey: .arguments),
                  environment: try container.decode([String: String].self, forKey: .environment),
                  directory: try container.decode(String.self, forKey: .directory))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executable, forKey: .executable)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(directory, forKey: .directory)
    }
}

extension UUID {
    var bytes: [UInt8] { withUnsafeBytes(of: uuid) { Array($0) } }

    init?(bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes.prefix(16)) }
        self.init(uuid: value)
    }
}
