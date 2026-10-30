import Foundation

/// A tool an element can call, as MCP describes it.
public struct ToolDefinition {
    public let name: String
    public let description: String
    /// JSON Schema of the arguments (an `object` schema).
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any] = ["type": "object", "properties": [String: Any]()]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum ToolContent {
    case text(String)
    /// Raw image bytes (sent base64-encoded), e.g. a screenshot.
    case image(Data, mimeType: String)
}

public struct ToolResult {
    public var content: [ToolContent]
    public var isError: Bool

    public init(_ content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolResult { ToolResult([.text(text)]) }
    public static func error(_ text: String) -> ToolResult { ToolResult([.text(text)], isError: true) }
}

/// A family of tools offered to board elements (messaging, a browser…). Keep the list stable for
/// a caller: clients read it once, so a tool that needs a line the caller doesn't have should
/// still be listed and explain that when called.
@MainActor
public protocol ToolProvider: AnyObject {
    func tools(for caller: UUID) -> [ToolDefinition]
    /// Runs `name`, one of the tools this provider listed for `caller`. May take its time: other
    /// requests keep being served meanwhile.
    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult
    /// What the caller should know about these tools, added to the server's instructions.
    func instructions(for caller: UUID) -> String?
    /// What the caller should have in its context without asking, given before `event` (a
    /// Claude Code hook: `SessionStart`, `UserPromptSubmit`, `PostToolUse`). Nil when nothing
    /// is new for it.
    func context(for caller: UUID, event: String) -> String?
}

public extension ToolProvider {
    func instructions(for caller: UUID) -> String? { nil }
    func context(for caller: UUID, event: String) -> String? { nil }
}

/// Every provider's tools behind one MCP server (JSON-RPC 2.0). Transport-free: `ToolServer`
/// carries the requests, this answers them.
@MainActor
public final class ToolCatalog {
    /// The MCP server name agents see; their tools are `mcp__<name>__<tool>`.
    public static let serverName = "board"
    private static let fallbackProtocolVersion = "2025-06-18"

    private var providers: [any ToolProvider] = []

    public init(_ providers: [any ToolProvider] = []) {
        self.providers = providers
    }

    public func add(_ provider: any ToolProvider) {
        providers.append(provider)
    }

    /// Every provider's context for `caller` before `event`, as a Claude Code hook's output
    /// (empty object when there is none).
    public func context(hook body: Data, caller: UUID) -> Data? {
        let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let event = input["hook_event_name"] as? String ?? ""
        let text = providers.compactMap { $0.context(for: caller, event: event) }.joined(separator: "\n\n")
        guard !text.isEmpty else { return Self.encode([:]) }
        return Self.encode(["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]])
    }

    /// Answers one JSON-RPC message from the element `caller`. Nil for notifications, which
    /// get no answer.
    public func respond(to body: Data, caller: UUID) async -> Data? {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = request["id"], !(id is NSNull) else { return nil }
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? Self.fallbackProtocolVersion,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": Self.serverName, "version": "1.0"],
                "instructions": providers.compactMap { $0.instructions(for: caller) }.joined(separator: "\n\n"),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": providers.flatMap { $0.tools(for: caller) }.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] as [String: Any]
            }]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let provider = providers.first { $0.tools(for: caller).contains { $0.name == name } }
            let outcome = await provider?.call(name, arguments: arguments, caller: caller) ?? .error("Unknown tool “\(name)”.")
            result = Self.encode(outcome)
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ result: ToolResult) -> [String: Any] {
        let content: [[String: Any]] = result.content.map {
            switch $0 {
            case .text(let text): ["type": "text", "text": text]
            case .image(let data, let mimeType): ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
            }
        }
        return ["content": content, "isError": result.isError]
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
