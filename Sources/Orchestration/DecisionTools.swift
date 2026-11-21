import AgentRuntime
import Connections
import Foundation

/// The decision tools: the only way an agent asks the developer something on the board. It
/// opens a decision and carries on; the answer reaches it later as a prompt.
@MainActor
final class DecisionTools: ToolProvider {
    private unowned let store: Orchestrator
    /// Agents whose context already points at the guide.
    private var pointed: Set<UUID> = []

    init(store: Orchestrator) {
        self.store = store
    }

    /// The board skill's section on decisions, served by `decision_guide` to agents no skill reaches.
    static let guide: String = {
        guard let start = BoardSkill.text.range(of: "## Decisions") else { return "" }
        let rest = BoardSkill.text[start.lowerBound...]
        let end = rest.dropFirst(3).range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    private static let pointer = """
    To ask the user anything, open a decision with decision_open: a loose question in your terminal opens no balloon. \
    Read the guide first, once: decision_guide, or the Decisions section of the board skill.
    """

    func instructions(for caller: UUID) -> String? {
        store.record(caller)?.runner == nil ? Self.pointer : nil
    }

    /// Agents that were running before these tools existed never read the instructions again:
    /// they get the pointer here, once, and again when their session starts over.
    func context(for caller: UUID, event: String) -> String? {
        guard store.record(caller)?.runner == nil, event == "SessionStart" || !pointed.contains(caller) else { return nil }
        pointed.insert(caller)
        return Self.pointer
    }

    private static let which: [String: Any] = [
        "type": "string", "description": "The decision's id, as decision_open gave it. Needed only when you have several open.",
    ]

    func tools(for caller: UUID) -> [ToolDefinition] {
        guard store.record(caller)?.runner == nil else { return [] }
        let element = "by name or id (as list_peers shows it); it must be connected to you"
        return [
            ToolDefinition(
                name: "decision_guide",
                description: "How to ask the user: when to decide alone, the three families, evidence, the visual budget, verifying first. Read it once before your first decision_open.",
                inputSchema: ["type": "object", "properties": [String: Any](), "required": [String]()]),
            ToolDefinition(
                name: "decision_open",
                description: """
                Shows the user a decision as a balloon pointing at your card: cards of evidence, then one ask. The only way to ask the \
                user something. Returns at once: carry on with your own choice (provisional) unless it is `blocking`; the answer \
                arrives later as a message. Read decision_guide first. A malformed decision is refused with the reason.
                """,
                inputSchema: ["type": "object", "properties": [
                    "family": ["type": "string", "enum": DecisionDraft.families,
                               "description": "surface: what a screen shows. flow: how the experience is walked through. foundation: what the rest is built on or will follow."],
                    "framing": ["type": "string", "description": "One line: what the user is about to evaluate, e.g. `Validate the invite screen`."],
                    "intent": ["type": "string", "description": "One line: what the user should notice. Your own check; not shown."],
                    "cards": ["type": "array", "description": "1 to \(DecisionDraft.maxCards) cards, one idea each.", "items": [
                        "type": "object", "properties": [
                            "claim": ["type": "string", "description": "What the evidence shows, e.g. `The screen ended up like this`."],
                            "evidence": ["type": "object", "description": "An image on the board, \(element).", "properties": [
                                "type": ["type": "string", "enum": DecisionDraft.kinds],
                                "after": ["type": "string", "description": "The image to evaluate (put a screenshot on the board with image_create)."],
                                "before": ["type": "string", "description": "The image it replaces, shown behind a draggable divider."],
                            ] as [String: Any], "required": ["type"]] as [String: Any],
                            "reference": ["type": "string", "description": "What to compare against when there is no `before`: the justification or the alternative. Never “we already do it this way”."],
                            "pins": ["type": "array", "description": "Doubts at an exact place of the evidence, within this decision's scope.", "items": [
                                "type": "object", "properties": [
                                    "x": ["type": "number", "description": "0 to 1 from the left."],
                                    "y": ["type": "number", "description": "0 to 1 from the top."],
                                    "question": ["type": "string"],
                                ] as [String: Any], "required": ["x", "y", "question"]] as [String: Any]] as [String: Any],
                        ] as [String: Any], "required": ["claim", "evidence"]] as [String: Any]] as [String: Any],
                    "ask": ["type": "object", "description": "The one question. Without `variants` the user validates (OK); with them the user picks one. Redirect is always there.", "properties": [
                        "question": ["type": "string", "description": "E.g. `Can the screen stay like this?`"],
                        "variants": ["type": "array", "description": "\(DecisionDraft.variantCount.lowerBound) to \(DecisionDraft.variantCount.upperBound) alternatives, lettered A, B, C in order. Don't recommend one.", "items": [
                            "type": "object", "properties": [
                                "name": ["type": "string", "description": "At most \(DecisionDraft.maxLabelWords) words, e.g. `Dense list`."],
                                "detail": ["type": "string", "description": "One line: what choosing it means."],
                            ] as [String: Any], "required": ["name"]] as [String: Any]] as [String: Any],
                    ] as [String: Any], "required": ["question"]] as [String: Any],
                    "verified": ["type": "array", "items": ["type": "string"], "description": "What you checked before asking, one line each."],
                    "blocking": ["type": "boolean", "description": "True only when it can't be undone or you can't go on: you then wait for the answer."],
                    "final": ["type": "boolean", "description": "True for the decision that closes the worktree's work, showing how the feature ended up."],
                ] as [String: Any], "required": ["family", "framing", "intent", "cards", "ask", "verified"]]),
            ToolDefinition(
                name: "decision_echo",
                description: "Says back in one line what you understood from the user's answer (a redirect, a choice given back to you, or an answer typed in your terminal) and closes the decision. Don't wait for confirmation after it.",
                inputSchema: ["type": "object", "properties": [
                    "echo": ["type": "string", "description": "One line, e.g. `Went with B - Card grid: it keeps avatar and role in view.`"],
                    "decision": Self.which,
                ] as [String: Any], "required": ["echo"]]),
            ToolDefinition(
                name: "decision_withdraw",
                description: "Takes back a decision of yours that is no longer worth the user's answer (obsolete after a redirect, or about to be redone). The user is not told.",
                inputSchema: ["type": "object", "properties": ["decision": Self.which], "required": [String]()]),
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let agent = store.record(caller), agent.runner == nil else { return .error("Only agents on the board open decisions.") }
        switch name {
        case "decision_guide":
            return .text(Self.guide)
        case "decision_open":
            return open(arguments, by: agent)
        case "decision_echo":
            guard let echo = (arguments["echo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !echo.isEmpty else {
                return .error("Give `echo`: one line saying what you understood.")
            }
            switch mine(arguments["decision"], of: caller, echoing: true) {
            case .failure(let refusal): return .error(refusal.reason)
            case .success(let decision):
                store.closeDecision(decision.id, echo: echo)
                return .text("Shown to the user under “\(decision.framing)”, which is now closed. Carry on.")
            }
        case "decision_withdraw":
            switch mine(arguments["decision"], of: caller) {
            case .failure(let refusal): return .error(refusal.reason)
            case .success(let decision):
                store.withdrawDecisions { $0.id == decision.id }
                return .text("Withdrew “\(decision.framing)”.")
            }
        default:
            return .error("Unknown tool “\(name)”.")
        }
    }

    private func open(_ arguments: [String: Any], by agent: AgentRecord) -> ToolResult {
        // The next decision only comes after the echo of the last answer.
        if let waiting = store.decisions.first(where: { $0.agent == agent.id && $0.state == .awaitingEcho }) {
            return .error("The user answered “\(waiting.framing)” and waits for what you understood: call decision_echo first.")
        }
        let draft: DecisionDraft
        do { draft = try DecisionDraft(arguments) } catch let refused as DecisionDraft.Refused {
            return .error("\(refused.reason) (decision_guide has the rules.)")
        } catch { return .error("\(error)") }
        var cards: [Decision.Card] = []
        for (index, card) in draft.cards.enumerated() {
            let connected = store.bus.peers(of: agent.id, kind: .image)
            func find(_ name: String) -> Result<UUID, DecisionDraft.Refused> {
                if let found = findElement(name, among: connected) { return .success(found.id) }
                let names = connected.isEmpty ? "none" : connected.map(\.name).joined(separator: ", ")
                return .failure(.init(reason: "Card \(index + 1): no \(card.kind) named “\(name)” is connected to you. Connected: \(names). Put a screenshot on the board with image_create first."))
            }
            var before: UUID?
            if let name = card.before {
                switch find(name) {
                case .success(let id): before = id
                case .failure(let refusal): return .error(refusal.reason)
                }
            }
            switch find(card.target) {
            case .failure(let refusal): return .error(refusal.reason)
            case .success(let id):
                cards.append(Decision.Card(claim: card.claim, evidence: .image(before: before, after: id), reference: card.reference, pins: card.pins))
            }
        }
        let decision = store.open(Decision(agent: agent.id, worktree: agent.worktree, organization: agent.organization, family: draft.family,
                                           framing: draft.framing, cards: cards, ask: draft.ask, verified: draft.verified,
                                           blocking: draft.blocking, final: draft.final))
        if decision.blocking, !draft.blocking {
            return .text("Opened decision \(decision.id.uuidString). It blocks: this worktree already has \(Decision.provisionalLimit) provisional decisions unanswered. Stop here and wait; the answer arrives as a message.")
        }
        return .text(decision.blocking
            ? "Opened decision \(decision.id.uuidString). It blocks: stop here and wait; the answer arrives as a message."
            : "Opened decision \(decision.id.uuidString). Carry on with your own choice (provisional); the answer arrives as a message.")
    }

    /// The caller's decision `given` names. Without a name: the one whose answer waits for its
    /// echo when `echoing`, else its only one the user hasn't answered.
    private func mine(_ given: Any?, of caller: UUID, echoing: Bool = false) -> Result<Decision, DecisionDraft.Refused> {
        var mine = store.decisions.filter { $0.agent == caller }
        guard !mine.isEmpty else { return .failure(.init(reason: "You have no open decision.")) }
        if let text = (given as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            if let found = mine.first(where: { $0.id == UUID(uuidString: text) }) { return .success(found) }
            return .failure(.init(reason: "You have no decision \(text). Yours: \(Self.list(mine))."))
        }
        if echoing {
            let waiting = mine.filter { $0.state == .awaitingEcho }
            if waiting.count == 1 { return .success(waiting[0]) }
        } else {
            mine.removeAll { $0.answer != nil }
            guard !mine.isEmpty else { return .failure(.init(reason: "You have no unanswered decision to withdraw.")) }
        }
        guard mine.count == 1 else { return .failure(.init(reason: "You have several decisions open; say which with `decision`: \(Self.list(mine)).")) }
        return .success(mine[0])
    }

    private static func list(_ decisions: [Decision]) -> String {
        decisions.map { "\($0.id.uuidString) (“\($0.framing)”)" }.joined(separator: ", ")
    }
}
