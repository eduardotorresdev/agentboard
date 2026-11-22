import AgentRuntime
import Foundation

/// Something an agent shows the developer and asks about: a few cards of evidence that end in
/// one ask. Kept beside the attention queue, which stays as it is: a decision is opened by the
/// agent on purpose (see DecisionTools), not raised by its hooks.
public struct Decision: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Waiting for the developer's answer.
        case open
        /// Answered with something the agent must say back (a redirect, a choice given back).
        case awaitingEcho
        /// Over: boards see it once, with its echo, and it is gone.
        case closed
    }

    /// What a card shows, pointing at elements on the board.
    public enum Evidence: Codable, Equatable, Sendable {
        case image(before: UUID?, after: UUID)
        case browser(id: UUID)
        case video(id: UUID)
        /// An SVG the agent drew, checked by `SVGDiagram` (what passes is what gets drawn).
        case diagram(svg: String)
    }

    /// A doubt at an exact place of the evidence, `x` and `y` from 0 to 1 from its top left.
    public struct Pin: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var question: String

        public init(x: Double, y: Double, question: String) {
            self.x = x
            self.y = y
            self.question = question
        }
    }

    public struct Card: Codable, Equatable, Sendable {
        /// What the evidence shows, e.g. `The screen ended up like this`.
        public var claim: String
        public var evidence: Evidence
        /// What to compare it against, when the evidence carries no before.
        public var reference: String?
        public var pins: [Pin]

        public init(claim: String, evidence: Evidence, reference: String? = nil, pins: [Pin] = []) {
            self.claim = claim
            self.evidence = evidence
            self.reference = reference
            self.pins = pins
        }
    }

    public struct Variant: Codable, Equatable, Sendable {
        public var letter: String
        public var name: String
        public var detail: String?

        public init(letter: String, name: String, detail: String? = nil) {
            self.letter = letter
            self.name = name
            self.detail = detail
        }

        public var title: String { "\(letter) - \(name)" }
    }

    public enum Ask: Codable, Equatable, Sendable {
        case validation(question: String)
        case choice(question: String, variants: [Variant])

        public var question: String {
            switch self {
            case .validation(let question), .choice(let question, _): question
            }
        }

        public var variants: [Variant] {
            if case .choice(_, let variants) = self { return variants }
            return []
        }
    }

    public enum Answer: Codable, Equatable, Sendable {
        case ok
        case option(String)
        case useRecommended
        case redirect(String)
    }

    public let id: UUID
    /// The agent that asked.
    public var agent: UUID
    public var worktree: String
    public var organization: UUID?
    /// `surface`, `flow` or `foundation`; free text so a new family needs no new core.
    public var family: String
    /// One line: what the developer is about to evaluate.
    public var framing: String
    public var cards: [Card]
    public var ask: Ask
    public var verified: [String]
    /// The agent waits for the answer instead of carrying on with its own choice.
    public var blocking: Bool
    /// It closes the worktree's work, showing how the feature ended up.
    public var final: Bool
    public var state: State
    public var since: Date
    public var answer: Answer?
    /// What the agent understood from the answer, in one line.
    public var echo: String?

    public init(id: UUID = UUID(), agent: UUID, worktree: String, organization: UUID? = nil, family: String, framing: String,
                cards: [Card], ask: Ask, verified: [String], blocking: Bool = false, final: Bool = false, state: State = .open,
                since: Date = Date(), answer: Answer? = nil, echo: String? = nil) {
        self.id = id
        self.agent = agent
        self.worktree = worktree
        self.organization = organization
        self.family = family
        self.framing = framing
        self.cards = cards
        self.ask = ask
        self.verified = verified
        self.blocking = blocking
        self.final = final
        self.state = state
        self.since = since
        self.answer = answer
        self.echo = echo
    }

    /// Provisional decisions one worktree stacks before the next one blocks.
    public static let provisionalLimit = 3

    /// The answer in words, as the agent and the balloon say it.
    public func title(of answer: Answer) -> String {
        switch answer {
        case .ok: "OK"
        case .option(let letter): ask.variants.first { $0.letter == letter }?.title ?? letter
        case .useRecommended: "Use Recommended"
        case .redirect: "Redirect"
        }
    }
}

/// What `decision_open` was given, checked. Evidence still names its elements as the agent
/// wrote them; the tool finds them on the board.
struct DecisionDraft: Equatable {
    struct Refused: Error, Equatable {
        let reason: String
    }

    struct Card: Equatable {
        var claim: String
        /// One of `kinds`.
        var kind: String
        var before: String?
        /// The image to evaluate, or a diagram's SVG.
        var target: String
        var reference: String?
        var pins: [Decision.Pin]
    }

    var family: String
    var framing: String
    var cards: [Card]
    var ask: Decision.Ask
    var verified: [String]
    var blocking: Bool
    var final: Bool

    static let maxCards = 6
    static let maxLabelWords = 3
    static let variantCount = 2...4
    static let families = ["surface", "flow", "foundation"]
    // shortcut: only images and diagrams have a renderer in the balloon; add browser and video here when they get one.
    static let kinds = ["image", "diagram"]

    /// The draft in a `decision_open` call's arguments, or why it is refused.
    init(_ arguments: [String: Any]) throws {
        func text(_ value: Any?) -> String? {
            let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        func refuse(_ reason: String) -> Refused { Refused(reason: reason) }

        guard let family = text(arguments["family"]), Self.families.contains(family) else {
            throw refuse("Give `family`: surface (what a screen shows), flow (how the experience is walked through) or foundation (what the rest is built on).")
        }
        guard let framing = text(arguments["framing"]), !framing.contains("\n") else {
            throw refuse("Give `framing`: one line saying what the user is about to evaluate.")
        }
        guard text(arguments["intent"]) != nil else {
            throw refuse("Give `intent`: one line saying what the user should notice. It is your own check and is not shown.")
        }
        guard let cards = arguments["cards"] as? [[String: Any]], !cards.isEmpty else {
            throw refuse("Give `cards`: at least one, each with a claim and its evidence. A decision shows before it asks.")
        }
        guard cards.count <= Self.maxCards else {
            throw refuse("A decision takes at most \(Self.maxCards) cards; you gave \(cards.count). One card, one idea: cut, or split it into two decisions.")
        }
        self.cards = try cards.enumerated().map { index, card in
            let number = index + 1
            guard card["ask"] == nil, card["question"] == nil else {
                throw refuse("Card \(number) asks something. A decision has one ask, given once in `ask`; a doubt about a place on the evidence is a pin.")
            }
            guard let claim = text(card["claim"]) else {
                throw refuse("Card \(number) has no `claim`: say what the evidence shows, e.g. “The screen ended up like this”.")
            }
            guard let evidence = card["evidence"] as? [String: Any], let kind = text(evidence["type"]), Self.kinds.contains(kind) else {
                throw refuse("Card \(number) has no `evidence`: an object with `type` (\(Self.kinds.joined(separator: ", "))) and the board element it shows.")
            }
            let target: String
            let before: String?
            if kind == "diagram" {
                guard let svg = text(evidence["svg"]) else {
                    throw refuse("Card \(number): give the diagram's SVG in `svg`.")
                }
                do { _ = try SVGDiagram(svg) } catch let refused as SVGDiagram.Refused {
                    throw refuse("Card \(number): the diagram can't be drawn. \(refused.reason)")
                }
                target = svg
                before = nil
            } else {
                guard let after = text(evidence["after"]) else {
                    throw refuse("Card \(number): give the image to evaluate in `after` (and the one it replaces in `before`).")
                }
                target = after
                before = text(evidence["before"])
            }
            let reference = text(card["reference"])
            guard before != nil || reference != nil else {
                throw refuse("Card \(number) is evaluated in a vacuum: give `before`, or a `reference` line with the justification or the alternative. Precedent is not a justification.")
            }
            let pins = try (card["pins"] as? [[String: Any]] ?? []).map { pin in
                guard let x = pin["x"] as? Double, let y = pin["y"] as? Double, (0...1).contains(x), (0...1).contains(y),
                      let question = text(pin["question"]) else {
                    throw refuse("Card \(number): a pin takes `x` and `y` from 0 to 1 (from the evidence's top left) and its `question`.")
                }
                return Decision.Pin(x: x, y: y, question: question)
            }
            return Card(claim: claim, kind: kind, before: before, target: target, reference: reference, pins: pins)
        }
        guard !(arguments["ask"] is [Any]) else {
            throw refuse("One decision, one ask: `ask` is a single object. A second question is a second decision.")
        }
        guard let ask = arguments["ask"] as? [String: Any], let question = text(ask["question"]) else {
            throw refuse("Give `ask`: an object with the `question`, and `variants` when the user picks between alternatives.")
        }
        if let variants = ask["variants"] as? [[String: Any]] {
            guard Self.variantCount.contains(variants.count) else {
                throw refuse("A choice takes \(Self.variantCount.lowerBound) to \(Self.variantCount.upperBound) variants (three for something new); you gave \(variants.count). With one, ask for validation: leave `variants` out.")
            }
            self.ask = .choice(question: question, variants: try variants.enumerated().map { index, variant in
                guard let name = text(variant["name"]), name.split(separator: " ").count <= Self.maxLabelWords else {
                    throw refuse("Variant \(index + 1) needs a `name` of at most \(Self.maxLabelWords) words, e.g. “Dense list”; the rest goes in `detail`.")
                }
                return Decision.Variant(letter: String(UnicodeScalar(UInt8(65 + index))), name: name, detail: text(variant["detail"]))
            })
        } else {
            self.ask = .validation(question: question)
        }
        let verified = (arguments["verified"] as? [Any] ?? []).compactMap(text)
        guard !verified.isEmpty else {
            throw refuse("Give `verified`: what you checked before asking, one line each. Nothing reaches the user unverified; what can't be verified is its own decision saying what stops you.")
        }
        self.family = family
        self.framing = framing
        self.verified = verified
        blocking = arguments["blocking"] as? Bool ?? false
        final = arguments["final"] as? Bool ?? false
    }
}

extension Orchestrator {
    /// Shows a new decision to the boards. One past the worktree's provisional limit blocks.
    func open(_ decision: Decision) -> Decision {
        var decision = decision
        let stacked = decisions.filter { $0.state == .open && !$0.blocking && $0.worktree == decision.worktree && $0.organization == decision.organization }
        if stacked.count >= Decision.provisionalLimit { decision.blocking = true }
        decisions.append(decision)
        broadcast(.decisions(decisions))
        return decision
    }

    /// The developer's answer, from a board: the agent hears it as a prompt. The decision stays
    /// open, holding the answer, until that prompt reaches the agent's terminal.
    func answerDecision(_ id: UUID, _ answer: Decision.Answer) {
        guard let index = decisions.firstIndex(where: { $0.id == id && $0.state == .open && $0.answer == nil }) else { return }
        if case .option(let letter) = answer, !decisions[index].ask.variants.contains(where: { $0.letter == letter }) { return }
        decisions[index].answer = answer
        broadcast(.decisions(decisions))
        deliverAnswers(to: decisions[index].agent)
    }

    /// Queues the answers `agent` hasn't heard yet. While its program isn't running nothing is
    /// queued: this is called again when it is back.
    func deliverAnswers(to agent: UUID) {
        for decision in decisions where decision.agent == agent && decision.state == .open {
            guard let answer = decision.answer else { continue }
            let lead = "The user answered your decision “\(decision.framing)”"
            let text = switch answer {
            case .ok: "\(lead): OK. Carry on."
            case .option: "\(lead): \(decision.title(of: answer)). Make that one the real one and carry on."
            case .useRecommended:
                "\(lead): Use Recommended. The choice is yours: choose now, then call decision_echo with one line saying which you chose and why."
            case .redirect(let text):
                """
                \(lead) with a redirect:

                \(text)

                It applies to the work at hand only. Call decision_echo with one line saying what you understood, then act on it \
                without waiting for confirmation. Then review your other open decisions: decision_withdraw the ones this made \
                obsolete and redo the affected ones.
                """
            }
            tell(agent, text, answering: decision.id)
        }
    }

    /// The answer reached the agent's terminal: a redirect or a choice given back waits for the
    /// agent's echo; anything else closes the decision.
    func answerDelivered(_ id: UUID) {
        guard let index = decisions.firstIndex(where: { $0.id == id && $0.state == .open }) else { return }
        switch decisions[index].answer {
        case .useRecommended, .redirect:
            decisions[index].state = .awaitingEcho
            broadcast(.decisions(decisions))
        default:
            closeDecision(id)
        }
    }

    /// Boards see the decision closed once (with the agent's echo, if any), then it is gone.
    func closeDecision(_ id: UUID, echo: String? = nil) {
        guard let index = decisions.firstIndex(where: { $0.id == id }) else { return }
        decisions[index].state = .closed
        decisions[index].echo = echo
        broadcast(.decisions(decisions))
        decisions.remove(at: index)
    }

    /// Takes decisions away without a word to the developer: withdrawn, or their agent is gone.
    func withdrawDecisions(where matches: (Decision) -> Bool) {
        guard decisions.contains(where: matches) else { return }
        decisions.removeAll(where: matches)
        broadcast(.decisions(decisions))
    }
}
