import Foundation

/// Messaging between connected elements: `list_peers` to see who is on the other end of the
/// caller's lines, `send_message` to write to one of them.
@MainActor
public final class MessagingTools: ToolProvider {
    private let bus: MessageBus

    public init(bus: MessageBus) {
        self.bus = bus
    }

    public func instructions(for caller: UUID) -> String? {
        let name = bus.element(caller)?.name ?? "an agent"
        return """
            You are \(name), one of several coding agents on the user's board. The user connects agents (and other \
            elements) by drawing lines between them; you can message the agents connected to you. Use list_peers to see \
            who they are and send_message to write to one. Messages from them arrive in your prompt starting with \
            “Message from <name>”. Reply with send_message when the sender needs an answer or the result of a task they \
            gave you; don't reply only to acknowledge or thank, so conversations end on their own.
            """
    }

    public func tools(for caller: UUID) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "list_peers",
                description: "Lists the elements connected to you on the board (agents and others). Only connected agents can receive your messages."),
            ToolDefinition(
                name: "send_message",
                description: "Sends a message to a connected agent. It arrives in their terminal as a prompt from you; their reply, if any, arrives in yours the same way.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Name of the connected agent, as list_peers shows it."],
                        "message": ["type": "string", "description": "What to tell them. Self-contained: they don't see your conversation."],
                    ],
                    "required": ["to", "message"],
                ]),
        ]
    }

    public func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        switch name {
        case "list_peers":
            return .text(peerList(for: caller))
        case "send_message":
            do {
                let message = try bus.send(arguments["message"] as? String ?? "", from: caller, to: arguments["to"] as? String ?? "")
                let name = bus.element(message.to)?.name ?? "them"
                return .text("Delivered to \(name). Their reply, if any, arrives in your terminal as a message.")
            } catch {
                return .error("\(error)")
            }
        default:
            return .error("Unknown tool “\(name)”.")
        }
    }

    private func peerList(for caller: UUID) -> String {
        let me = bus.element(caller)?.name ?? "an agent"
        let peers = bus.peers(of: caller)
        guard !peers.isEmpty else {
            return "You are \(me). Nothing is connected to you yet; the user connects elements by drawing lines between them on the board."
        }
        let lines = peers.map { peer in
            var notes = [peer.kind.rawValue]
            if let detail = peer.detail { notes.append(detail) }
            if let reason = (peer as? any MessageEndpoint)?.unavailableReason { notes.append("unavailable: \(reason)") }
            return "- \(peer.name) (\(notes.joined(separator: ", ")))"
        }
        return "You are \(me). Connected:\n" + lines.joined(separator: "\n")
    }
}
