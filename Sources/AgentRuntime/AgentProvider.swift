import Foundation

/// A coding agent the board can launch. Everything specific to one agent (its command, how it
/// starts or resumes a conversation, what it needs from the environment) lives behind this;
/// sessions, the terminal and the board only ever see a `LaunchSpec`.
public protocol AgentProvider: Sendable {
    /// Stable identifier stored with each card. Never change it once shipped.
    var id: String { get }
    /// Name on the card and in the Add Agent menu.
    var title: String { get }
    /// Command looked up in the user's PATH.
    var executable: String { get }
    /// Arguments that start the conversation bound to `session`, or resume it if it exists, with
    /// the board's tools available through `tools` when given.
    func arguments(session: UUID, tools: ToolServerLink?) -> [String]
    /// Adjusts the environment inherited from the app.
    func environment(_ base: [String: String]) -> [String: String]
}

/// Where an agent reaches the board's tools: an MCP server over HTTP, and the token that
/// identifies this agent to it.
public struct ToolServerLink: Sendable {
    public let name: String
    public let url: URL
    public let token: String

    public init(name: String, url: URL, token: String) {
        self.name = name
        self.url = url
        self.token = token
    }
}

/// The agents the app knows about. Adding one means adding a provider here.
public enum AgentCatalog {
    public static let all: [any AgentProvider] = [ClaudeCode()]

    public static func provider(id: String) -> (any AgentProvider)? {
        all.first { $0.id == id }
    }
}

/// Anthropic's Claude Code CLI.
public struct ClaudeCode: AgentProvider {
    public let id = "claude"
    public let title = "Claude"
    public let executable = "claude"

    public init() {}

    public func arguments(session: UUID, tools: ToolServerLink?) -> [String] {
        let id = session.uuidString.lowercased()
        var arguments: [String] = []
        if let tools, let config = Self.mcpConfig(tools) {
            // Both options take several values: each is ended by the next option.
            arguments += ["--mcp-config", config, "--allowedTools", "mcp__\(tools.name)"]
        }
        return arguments + (Self.conversationExists(id) ? ["--resume", id] : ["--session-id", id])
    }

    /// The board's server as an inline `--mcp-config`. Its tools are allowed up front: they only
    /// reach agents the user connected.
    private static func mcpConfig(_ tools: ToolServerLink) -> String? {
        let server: [String: Any] = ["type": "http", "url": tools.url.absoluteString,
                                     "headers": ["Authorization": "Bearer \(tools.token)"]]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [tools.name: server]])
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Drops markers inherited when the app itself was launched from Claude Code, so the child
    /// behaves like a top-level session (child sessions don't save transcripts, which would
    /// make them impossible to resume).
    public func environment(_ base: [String: String]) -> [String: String] {
        base.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
    }

    /// Claude Code writes each conversation to ~/.claude/projects/<escaped cwd>/<session>.jsonl
    /// only after the first message, so an agent that was never used must start fresh.
    private static func conversationExists(_ id: String) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let name = id + ".jsonl"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(name).path) }
    }
}
