import AgentRuntime
import Foundation

/// An agent waiting on the developer, across every organization and worktree: one per card,
/// kept until the developer dismisses it or the agent is working again.
public struct AttentionRequest: Codable, Equatable, Identifiable, Sendable {
    public enum Reason: Codable, Equatable, Sendable {
        /// It ended its turn.
        case turnEnded
        /// It is waiting without saying on what.
        case waiting
        /// What it said.
        case said(String)
    }

    /// The card's id.
    public let id: UUID
    public var reason: Reason
    /// When it started waiting; a newer signal while it waits doesn't move it.
    public var since: Date
    /// What the developer is asked to decide on: the agent's last words, the question it asked,
    /// or the command it wants to run. Nil when its conversation can't be read.
    public var context: String?

    public init(id: UUID, reason: Reason, since: Date = Date(), context: String? = nil) {
        self.id = id
        self.reason = reason
        self.since = since
        self.context = context
    }
}

extension Orchestrator {
    /// Notifications that mean the agent waits on the developer. Others don't: idle at the
    /// prompt repeats the end of the turn a minute later, and some only inform (auth_success).
    private static let waitingNotifications: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// An agent's program sent desktop notifications: its hooks (see `AgentHook`) raise or clear
    /// its request. Anything else is ignored: the hooks carry every notification Claude Code
    /// sends, with its type, so its own OSC 9 (launched from iTerm2, say) would only repeat one
    /// unfiltered. Runners' are ignored too.
    public func sessionNotified(_ id: UUID, _ notifications: [String]) {
        guard let record = record(id), record.runner == nil else { return }
        for hook in notifications.compactMap(AgentHook.init(notification:)) {
            switch hook.hook_event_name {
            case "Stop":
                let context = hook.last_assistant_message.flatMap(TranscriptContext.trimmed)
                    ?? hook.transcript_path.flatMap { TranscriptContext.lastRequest(in: URL(fileURLWithPath: $0)) }
                requestAttention(id, .turnEnded, context: context)
            case "Notification" where hook.notification_type.map(Self.waitingNotifications.contains) ?? true:
                requestAttention(id, hook.message.map { .said($0) } ?? .waiting,
                                 context: hook.transcript_path.flatMap { TranscriptContext.lastRequest(in: URL(fileURLWithPath: $0)) })
            case "UserPromptSubmit":
                dismissAttention(id)
            default:
                break
            }
        }
    }

    /// Queues the agent, or updates why it waits while keeping its place.
    func requestAttention(_ id: UUID, _ reason: AttentionRequest.Reason, context: String? = nil) {
        guard record(id) != nil else { return }
        if let index = attention.firstIndex(where: { $0.id == id }) {
            let context = context ?? attention[index].context
            guard attention[index].reason != reason || attention[index].context != context else { return }
            attention[index].reason = reason
            attention[index].context = context
        } else {
            attention.append(AttentionRequest(id: id, reason: reason, context: context))
        }
        broadcast(.attention(attention))
    }

    func dismissAttention(_ id: UUID) {
        guard attention.contains(where: { $0.id == id }) else { return }
        attention.removeAll { $0.id == id }
        broadcast(.attention(attention))
    }
}
