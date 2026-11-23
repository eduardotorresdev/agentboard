import AgentRuntime
import Connections
import Foundation
import Testing
@testable import Orchestration

/// A well-formed `decision_open` call; `change` breaks it.
private func arguments(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var arguments: [String: Any] = [
        "family": "surface", "framing": "Validate the invite screen", "intent": "The new send button",
        "cards": [["claim": "The screen ended up like this", "evidence": ["type": "image", "after": "After", "before": "Before"]]],
        "ask": ["question": "Can the screen stay like this?"],
        "verified": ["Built and opened the screen"],
    ]
    change(&arguments)
    return arguments
}

private let card: [String: Any] = ["claim": "The list", "evidence": ["type": "image", "after": "After"], "reference": "Against a table: denser, but no avatars."]

private func refusal(_ change: (inout [String: Any]) -> Void) -> String {
    do { _ = try DecisionDraft(arguments(change)) } catch let refused as DecisionDraft.Refused { return refused.reason } catch {}
    return ""
}

@Test func aWellFormedDecisionIsTaken() throws {
    let draft = try DecisionDraft(arguments())
    #expect(draft.ask == .validation(question: "Can the screen stay like this?"))
    #expect(draft.cards == [.init(claim: "The screen ended up like this", kind: "image", before: "Before", target: "After", reference: nil, pins: [])])
    #expect(!draft.blocking && !draft.final)

    let choice = try DecisionDraft(arguments {
        $0["cards"] = [card]
        $0["ask"] = ["question": "Which one?", "variants": [["name": "Dense list", "detail": "More rows"], ["name": "Card grid"]]]
        $0["blocking"] = true
    })
    #expect(choice.ask.variants.map(\.title) == ["A - Dense list", "B - Card grid"])
    #expect(choice.blocking)
}

@Test func malformedDecisionsAreRefusedWithTheReason() {
    #expect(refusal { $0["ask"] = [["question": "One?"], ["question": "Two?"]] }.contains("One decision, one ask"))
    #expect(refusal { $0["cards"] = [card.merging(["ask": "Is it fine?"]) { $1 }] }.contains("Card 1 asks something"))
    #expect(refusal { $0["cards"] = Array(repeating: card, count: 7) }.contains("at most 6 cards; you gave 7"))
    #expect(refusal { $0["cards"] = [[String: Any]]() }.contains("Give `cards`"))
    #expect(refusal { $0["cards"] = [card.merging(["reference": " "]) { $1 }] }.contains("evaluated in a vacuum"))
    #expect(refusal { $0["cards"] = [["claim": "A page", "evidence": ["type": "browser"], "reference": "New"]] }.contains("Card 1 has no `evidence`: an object with `type` (image, diagram)"))
    #expect(refusal { $0["family"] = "layout" }.contains("Give `family`"))
    #expect(refusal { $0["cards"] = [card.merging(["pins": [["x": 1.5, "y": 0.2, "question": "Here?"]]]) { $1 }] }.contains("a pin takes"))
    #expect(refusal { $0["ask"] = ["question": "Which?", "variants": [["name": "Only one"]]] }.contains("2 to 4 variants"))
    #expect(refusal { $0["ask"] = ["question": "Which?", "variants": [["name": "A very long name"], ["name": "Short"]]] }.contains("at most 3 words"))
    #expect(refusal { $0["verified"] = [String]() }.contains("Give `verified`"))
    #expect(refusal { $0["intent"] = nil }.contains("Give `intent`"))
    #expect(refusal { $0["family"] = nil }.contains("Give `family`"))
    #expect(refusal { $0["framing"] = "Two\nlines" }.contains("Give `framing`"))
}

private let guideDiagram = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../core/fixtures/diagrams/guide.svg"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

/// A diagram is checked by the renderer's own parser: the guide's example passes, and what the
/// renderer can't draw is refused with its reason.
@Test func aDiagramIsCheckedByWhatDrawsIt() throws {
    let diagram: [String: Any] = ["claim": "The answer goes to the core", "evidence": ["type": "diagram", "svg": guideDiagram], "reference": "Before, the Mac answered alone."]
    let draft = try DecisionDraft(arguments { $0["cards"] = [diagram] })
    #expect(draft.cards.first?.kind == "diagram" && draft.cards.first?.target == guideDiagram)
    #expect(refusal { $0["cards"] = [["claim": "x", "evidence": ["type": "diagram"], "reference": "r"]] }.contains("give the diagram's SVG in `svg`"))
    #expect(refusal { $0["cards"] = [["claim": "x", "evidence": ["type": "diagram", "svg": "<svg viewBox='0 0 9 9'><image/></svg>"], "reference": "r"]] }
        .contains("Card 1: the diagram can't be drawn. `<image>` isn't drawn"))
    #expect(refusal { $0["cards"] = [["claim": "x", "evidence": ["type": "diagram", "svg": guideDiagram]]] }.contains("evaluated in a vacuum"))
}

/// The guide shows one complete diagram, and it is the fixture that passes above.
@MainActor @Test func theGuidesDiagramIsTheFixture() {
    #expect(!guideDiagram.isEmpty && DecisionTools.guide.contains(guideDiagram.trimmingCharacters(in: .newlines)))
}

@Test @MainActor func theGuideIsTheSkillsSection() {
    #expect(DecisionTools.guide.hasPrefix("## Decisions\n"))
    #expect(DecisionTools.guide.contains("opens no balloon"))
    #expect(!DecisionTools.guide.dropFirst(3).contains("\n## "))
}

@Suite(.serialized)
struct DecisionTests {
    /// A started agent with a before and an after image connected to it, and a board listening.
    @MainActor private func setUp() async throws -> (core: Core, agent: AgentRecord, board: CoreClient, inbox: Inbox) {
        let core = try Core()
        let a = agent("Ada", in: core.folder)
        let link = try await board(core)
        let inbox = Inbox()
        link.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        link.send(.addCard(a))
        link.send(.open(id: a.id, cols: 200, rows: 24, start: true))
        try await waitUntil { core.screen(a.id).contains("ready") }
        try picture(40, 20).write(to: core.folder.appendingPathComponent("shot.png"))
        for name in ["Before", "After"] {
            let created = try await call("image_create", ["path": "shot.png", "name": name], as: a.id, on: core)
            #expect(!created.isError, "\(created.text)")
        }
        return (core, a, link, inbox)
    }

    /// The decisions boards last heard of.
    private func heard(_ inbox: Inbox) -> [Decision] {
        inbox.events.reversed().lazy.compactMap { if case .decisions(let list) = $0 { list } else { nil } }.first ?? []
    }

    private func id(in text: String) throws -> UUID {
        try #require(text.split(separator: " ").lazy.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .punctuationCharacters)) }.first)
    }

    /// Open, answer OK: the agent hears it, boards see it closed, nothing is left; needs_user never raised.
    @Test @MainActor func aValidationIsOpenedAnsweredAndClosed() async throws {
        let (core, a, link, inbox) = try await setUp()
        defer { core.stop() }
        let refused = try await call("decision_open", arguments { $0["verified"] = nil }, as: a.id, on: core)
        #expect(refused.isError && refused.text.contains("Give `verified`") && core.orchestrator.decisions.isEmpty)
        let missing = try await call("decision_open", arguments { $0["cards"] = [["claim": "x", "evidence": ["type": "image", "after": "Nope"], "reference": "r"]] }, as: a.id, on: core)
        #expect(missing.isError && missing.text.contains("Connected: Before, After"), "\(missing.text)")

        let opened = try await call("decision_open", arguments(), as: a.id, on: core)
        #expect(!opened.isError && opened.text.contains("provisional"), "\(opened.text)")
        let decision = try #require(core.orchestrator.decisions.first)
        #expect(try id(in: opened.text) == decision.id)
        #expect(decision.state == .open && !decision.blocking && decision.agent == a.id && decision.worktree == a.worktree)
        let images = core.orchestrator.images
        #expect(decision.cards.map(\.evidence) == [.image(before: images.first { $0.name == "Before" }?.id, after: try #require(images.first { $0.name == "After" }).id)])
        #expect(core.orchestrator.attention.isEmpty)
        try await waitUntil { self.heard(inbox).map(\.id) == [decision.id] }

        // A board that connects later finds it.
        let late = try await board(core)
        #expect(BoardState(late.serviceState ?? Data())?.decisions?.map(\.id) == [decision.id])
        late.disconnect()

        link.send(.answerDecision(id: decision.id, answer: .ok))
        try await waitUntil { core.orchestrator.decisions.isEmpty }
        try await waitUntil { core.screen(a.id).contains("OK. Carry on.") }

        // A diagram needs nothing on the board: its SVG is the evidence.
        let drawn = try await call("decision_open", arguments {
            $0["cards"] = [["claim": "The answer goes to the core", "evidence": ["type": "diagram", "svg": guideDiagram], "reference": "Before, the Mac answered alone."]]
        }, as: a.id, on: core)
        #expect(!drawn.isError, "\(drawn.text)")
        #expect(core.orchestrator.decisions.first?.cards.map(\.evidence) == [.diagram(svg: guideDiagram)])
        link.send(.answerDecision(id: try #require(core.orchestrator.decisions.first).id, answer: .ok))
        try await waitUntil { core.orchestrator.decisions.isEmpty }
        try await waitUntil { inbox.events.contains { if case .decisions(let list) = $0 { list.first?.state == .closed && list.first?.answer == .ok } else { false } } }
        #expect(inbox.events.contains { if case .decisions(let list) = $0 { list.first?.state == .closed && list.first?.answer == .ok } else { false } })
        #expect(core.orchestrator.attention.isEmpty)
        link.disconnect()
    }

    /// A redirect waits for the agent's echo, and the next decision only comes after it.
    @Test @MainActor func aRedirectIsEchoedBeforeTheNextDecision() async throws {
        let (core, a, link, inbox) = try await setUp()
        defer { core.stop() }
        let choice = arguments { $0["ask"] = ["question": "Which one?", "variants": [["name": "Dense list"], ["name": "Card grid"]]] }
        _ = try await call("decision_open", choice, as: a.id, on: core)
        let decision = try #require(core.orchestrator.decisions.first)

        // An answer naming no variant of this ask changes nothing.
        link.send(.answerDecision(id: decision.id, answer: .option("Z")))
        link.send(.answerDecision(id: decision.id, answer: .redirect("About B - Card grid: keep the avatars")))
        try await waitUntil { core.orchestrator.decisions.first?.state == .awaitingEcho }
        #expect(core.orchestrator.decisions.first?.answer == .redirect("About B - Card grid: keep the avatars"))
        try await waitUntil { core.screen(a.id).contains("keep the avatars") }
        // Answered once: a second answer is ignored.
        link.send(.answerDecision(id: decision.id, answer: .ok))

        // Withdrawing without naming one never takes the answered decision.
        let kept = try await call("decision_withdraw", as: a.id, on: core)
        #expect(kept.isError && core.orchestrator.decisions.map(\.id) == [decision.id], "\(kept.text)")
        let early = try await call("decision_open", arguments(), as: a.id, on: core)
        #expect(early.isError && early.text.contains("decision_echo first"), "\(early.text)")
        #expect(try await call("decision_echo", as: a.id, on: core).isError)
        let echoed = try await call("decision_echo", ["echo": "Keeping the avatars in the grid."], as: a.id, on: core)
        #expect(!echoed.isError, "\(echoed.text)")
        #expect(core.orchestrator.decisions.isEmpty)
        try await waitUntil { inbox.events.contains { if case .decisions(let list) = $0 { list.first?.echo == "Keeping the avatars in the grid." && list.first?.state == .closed } else { false } } }
        #expect(inbox.events.contains { if case .decisions(let list) = $0 { list.first?.echo == "Keeping the avatars in the grid." && list.first?.state == .closed } else { false } })

        // Use Recommended gives the choice back and waits for the echo too; a letter closes at once.
        _ = try await call("decision_open", choice, as: a.id, on: core)
        link.send(.answerDecision(id: try #require(core.orchestrator.decisions.first).id, answer: .useRecommended))
        try await waitUntil { core.orchestrator.decisions.first?.state == .awaitingEcho }
        _ = try await call("decision_echo", ["echo": "Went with A - Dense list."], as: a.id, on: core)
        _ = try await call("decision_open", choice, as: a.id, on: core)
        link.send(.answerDecision(id: try #require(core.orchestrator.decisions.first).id, answer: .option("B")))
        try await waitUntil { core.orchestrator.decisions.isEmpty }
        try await waitUntil { core.screen(a.id).contains("B - Card grid. Make that one") }
        #expect(core.screen(a.id).contains("B - Card grid. Make that one"))
        link.disconnect()
    }

    /// An answer given while the agent's program isn't running is kept, and reaches it when it is back.
    @Test @MainActor func anAnswerWaitsForAnAgentThatIsNotRunning() async throws {
        let (core, a, link, _) = try await setUp()
        defer { core.stop() }
        _ = try await call("decision_open", arguments(), as: a.id, on: core)
        let decision = try #require(core.orchestrator.decisions.first)
        // End of input: the agent's program exits.
        core.orchestrator.session(a.id)?.send([0x04])
        try await waitUntil { core.orchestrator.session(a.id)?.state == .exited }

        link.send(.answerDecision(id: decision.id, answer: .ok))
        try await waitUntil { core.orchestrator.decisions.first?.answer == .ok }
        try await Task.sleep(for: .milliseconds(200))
        #expect(core.orchestrator.decisions.map(\.state) == [.open])

        link.send(.restart(id: a.id, command: nil))
        try await waitUntil { core.orchestrator.decisions.isEmpty }
        try await waitUntil { core.screen(a.id).contains("OK. Carry on.") }
        #expect(core.screen(a.id).contains("OK. Carry on."))
        link.disconnect()
    }

    /// Three provisional decisions may be open in a worktree, the fourth blocks; the agent withdraws its own, and
    /// closing its card takes the rest.
    @Test @MainActor func provisionalDecisionsStackUpToALimitAndAreWithdrawn() async throws {
        let (core, a, link, inbox) = try await setUp()
        defer { core.stop() }
        let first = try await call("decision_open", arguments(), as: a.id, on: core)
        let second = try await call("decision_open", arguments { $0["framing"] = "Validate the empty state" }, as: a.id, on: core)
        let third = try await call("decision_open", arguments { $0["framing"] = "Validate the error state" }, as: a.id, on: core)
        let fourth = try await call("decision_open", arguments { $0["framing"] = "Validate the loading state" }, as: a.id, on: core)
        #expect(![first, second, third].contains { $0.text.contains("blocks") })
        #expect(fourth.text.contains("It blocks: this worktree already has 3 provisional"), "\(fourth.text)")
        #expect(core.orchestrator.decisions.map(\.blocking) == [false, false, false, true])
        _ = try await call("decision_withdraw", ["decision": try id(in: fourth.text).uuidString], as: a.id, on: core)

        let unnamed = try await call("decision_withdraw", as: a.id, on: core)
        #expect(unnamed.isError && unnamed.text.contains("say which"), "\(unnamed.text)")
        let withdrawn = try await call("decision_withdraw", ["decision": try id(in: second.text).uuidString], as: a.id, on: core)
        #expect(!withdrawn.isError, "\(withdrawn.text)")
        #expect(core.orchestrator.decisions.map(\.framing) == ["Validate the invite screen", "Validate the error state"])
        try await waitUntil { self.heard(inbox).count == 2 }

        link.send(.removeCard(a.id))
        try await waitUntil { core.orchestrator.decisions.isEmpty }
        try await waitUntil { self.heard(inbox).isEmpty }
        #expect(heard(inbox).isEmpty)
        link.disconnect()
    }
}

/// The drafts both cores check (`core/fixtures/decisions/drafts.json`): each is taken as the
/// fixture says, or refused for the same reason, here and in the Rust core.
@Test func theSharedDraftsAreTakenOrRefusedAlike() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../core/fixtures/decisions/drafts.json"))
    let fixture = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let base = try #require(fixture["base"] as? [String: Any])
    let cases = try #require(fixture["cases"] as? [[String: Any]])
    #expect(cases.count > 20)
    for item in cases {
        let name = item["name"] as? String ?? ""
        var arguments = base
        for (key, value) in item["set"] as? [String: Any] ?? [:] { arguments[key] = value is NSNull ? nil : value }
        do {
            let draft = try DecisionDraft(arguments)
            let taken: [String: Any] = [
                "family": draft.family, "framing": draft.framing, "question": draft.ask.question, "variants": draft.ask.variants.map(\.title),
                "verified": draft.verified, "blocking": draft.blocking, "final": draft.final,
                "cards": draft.cards.map { card -> [String: Any] in
                    ["claim": card.claim, "kind": card.kind, "before": card.before ?? NSNull(), "target": card.target,
                     "reference": card.reference ?? NSNull(), "pins": card.pins.map { [$0.x, $0.y, $0.question] as [Any] }]
                },
            ]
            #expect(item["refused"] is NSNull, "\(name) was taken")
            #expect(NSDictionary(dictionary: taken).isEqual(to: item["taken"] as? [String: Any] ?? [:]), "\(name)")
        } catch let refused as DecisionDraft.Refused {
            #expect(refused.reason == item["refused"] as? String, "\(name)")
        }
    }
}
