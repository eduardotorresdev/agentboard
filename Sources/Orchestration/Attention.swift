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
    /// Questions the agent asked (AskUserQuestion) that wait on the board's answers; nil when
    /// it waits in its terminal.
    public var questions: [AgentQuestion]?
    /// The orchestrators coordinating the agent, when it waits on what only the developer can
    /// give (a permission prompt); nil for an agent no orchestrator coordinates.
    public var orchestrators: [String]?

    public init(id: UUID, reason: Reason, since: Date = Date(), context: String? = nil, questions: [AgentQuestion]? = nil,
                orchestrators: [String]? = nil) {
        self.id = id
        self.reason = reason
        self.since = since
        self.context = context
        self.questions = questions
        self.orchestrators = orchestrators
    }
}

/// One question an agent asks with AskUserQuestion: options to pick one of, or several of, and
/// always room for an answer of the developer's own.
public struct AgentQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        /// What picking it means.
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    /// A short tag for it, e.g. `Layout`.
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions of an AskUserQuestion call's input.
    static func parse(_ input: [String: Any]) -> [AgentQuestion] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { question in
            guard let text = question["question"] as? String, !text.isEmpty else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map { Option(label: $0, description: option["description"] as? String) }
            }
            return AgentQuestion(question: text, header: question["header"] as? String, options: options,
                                 multiSelect: question["multiSelect"] as? Bool ?? false)
        }
    }
}

/// An agent's questions hook, waiting: what it asked, and how to let it go on.
struct PendingQuestions {
    /// The AskUserQuestion call's input, given back with the answers added.
    let input: [String: Any]
    let resume: CheckedContinuation<Data, Never>
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
    func requestAttention(_ id: UUID, _ reason: AttentionRequest.Reason, context: String? = nil, questions: [AgentQuestion]? = nil) {
        guard let record = record(id) else { return }
        let orchestrators = orchestrators(of: record)
        if !orchestrators.isEmpty, reason == .turnEnded, questions == nil {
            // A finished turn goes to its orchestrators, which decide whether it needs the developer.
            let report = context.map { "I finished my turn. My last words:\n\n\($0)" } ?? "I finished my turn."
            for orchestrator in orchestrators { _ = try? bus.deliver(report, from: id, to: orchestrator.id) }
            return dismissAttention(id)
        }
        let via = orchestrators.isEmpty ? nil : orchestrators.map(\.name)
        if let index = attention.firstIndex(where: { $0.id == id }) {
            let context = context ?? attention[index].context
            let questions = pendingQuestions[id] != nil ? questions ?? attention[index].questions : nil
            guard attention[index].reason != reason || attention[index].context != context
                    || attention[index].questions != questions || attention[index].orchestrators != via else { return }
            attention[index].reason = reason
            attention[index].context = context
            attention[index].questions = questions
            attention[index].orchestrators = via
        } else {
            attention.append(AttentionRequest(id: id, reason: reason, context: context, questions: questions, orchestrators: via))
        }
        broadcast(.attention(attention))
    }

    /// The orchestrators connected to an agent that isn't one itself: an orchestrator answers
    /// to the developer, so two connected ones never pass turns back and forth.
    func orchestrators(of record: AgentRecord) -> [AgentRecord] {
        guard !record.isOrchestrator else { return [] }
        return bus.peers(of: record.id).compactMap { self.record($0.id) }.filter(\.isOrchestrator)
    }

    // MARK: Questions

    /// The agent's questions hook posted what it is about to ask: queue it with the questions and
    /// wait for the developer. The hook's output: the call allowed with the answers in its input,
    /// or nothing (`{}`), which leaves the questions to the agent's terminal.
    func ask(_ body: Data, caller: UUID) async -> Data {
        let hook = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let input = hook["tool_input"] as? [String: Any] ?? [:]
        let questions = AgentQuestion.parse(input)
        guard record(caller) != nil, !questions.isEmpty else { return Self.noAnswer }
        // A hook still waiting is from a call that's over.
        pendingQuestions.removeValue(forKey: caller)?.resume.resume(returning: Self.noAnswer)
        let context = (hook["transcript_path"] as? String).flatMap { TranscriptContext.lastText(in: URL(fileURLWithPath: $0)) }
        return await withCheckedContinuation { continuation in
            pendingQuestions[caller] = PendingQuestions(input: input, resume: continuation)
            requestAttention(caller, .waiting, context: context, questions: questions)
        }
    }

    /// The developer's answers, keyed by question text; nil sends the agent to ask in its terminal.
    func answerQuestions(_ id: UUID, _ answers: [String: String]?) {
        guard let pending = pendingQuestions.removeValue(forKey: id) else { return }
        guard let answers else {
            pending.resume.resume(returning: Self.noAnswer)
            // It now waits in its terminal: the card shows it.
            if let index = attention.firstIndex(where: { $0.id == id }) {
                attention[index].questions = nil
                broadcast(.attention(attention))
            }
            return
        }
        var input = pending.input
        input["answers"] = answers
        let output: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input,
        ]]
        pending.resume.resume(returning: (try? JSONSerialization.data(withJSONObject: output)) ?? Self.noAnswer)
        dismissAttention(id)
    }

    private static let noAnswer = Data("{}".utf8)

    func dismissAttention(_ id: UUID) {
        // Questions dismissed unanswered go back to the agent's terminal.
        pendingQuestions.removeValue(forKey: id)?.resume.resume(returning: Self.noAnswer)
        guard attention.contains(where: { $0.id == id }) else { return }
        attention.removeAll { $0.id == id }
        broadcast(.attention(attention))
    }
}
