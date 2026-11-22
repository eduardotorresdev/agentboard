import Foundation

// The two AgentRuntime types CoreProtocol.swift names, copied from AgentSession.swift (which
// needs AppKit). The JSON must stay what the Mac's synthesized Codable makes.
// shortcut: duplicated until AgentRuntime builds for iOS; then link it and delete this file.

public struct LaunchSpec: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

public final class AgentSession {
    public enum State: Equatable, Sendable, Codable {
        case starting
        case running
        case exited
        case failed(String)
        case stopped
    }
}
