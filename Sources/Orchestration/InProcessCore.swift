import AgentRuntime
import Darwin
import Foundation

/// A core inside the board's own process, for when the real one can't run (its binary is
/// missing, `AGENTBOARD_LOCAL=1`, bench builds): the board talks to it the same way, but its
/// programs end with the board.
@MainActor
public final class InProcessCore {
    public let socketPath: String
    private let server: CoreServer
    private let orchestrator: Orchestrator

    public init(database: URL? = nil) throws {
        socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("agentboard-local-\(getpid()).sock")
        server = CoreServer(socketPath: socketPath, idleTimeout: .greatestFiniteMagnitude, queue: .main)
        orchestrator = Orchestrator(server: server, database: database)
        server.service = orchestrator
        try server.start()
    }

    deinit {
        server.stop()
        unlink(socketPath)
    }
}
