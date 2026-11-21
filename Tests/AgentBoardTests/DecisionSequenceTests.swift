import Foundation
@testable import AgentBoard
@testable import Orchestration
import Testing

/// A store no core answers, with one agent and the decisions given.
@MainActor private func board(_ decisions: (UUID) -> [Decision]) -> (store: AgentStore, agent: UUID, sent: () -> [(UUID, Decision.Answer)]) {
    let store = AgentStore(connect: { .failure(.noCore) })
    let agent = UUID()
    store.received(.cardAdded(AgentRecord(id: agent, worktree: "/w", providerID: "claude", name: "Agent", frame: .zero)))
    store.received(.decisions(decisions(agent)))
    return (store, agent, {
        store.decisions.compactMap { decision in decision.answer.map { (decision.id, $0) } }
    })
}

private func decision(_ agent: UUID, _ framing: String, blocking: Bool = false) -> Decision {
    Decision(agent: agent, worktree: "/w", family: "surface", framing: framing, cards: [], ask: .validation(question: "OK?"),
             verified: [], blocking: blocking)
}

@MainActor @Test func anAgentsDecisionsReadAsOneRunOfQuestions() throws {
    let (store, agent, sent) = board { [decision($0, "First"), decision($0, "Second")] }
    var sequence = try #require(store.decisionSequence(of: agent))
    #expect(sequence.shown.framing == "First")
    #expect([sequence.position, sequence.total] == [1, 2] as [Int])

    // Not the last question: it is sent at once and the next one shows, with no undo window.
    store.answer(sequence.shown, .ok)
    #expect(store.pendingAnswers.isEmpty)
    #expect(sent().map(\.0) == [sequence.shown.id])
    sequence = try #require(store.decisionSequence(of: agent))
    #expect(sequence.shown.framing == "Second")
    #expect([sequence.position, sequence.total] == [2, 2] as [Int])
    #expect(sequence.isWaiting)

    // The core agrees (an OK closes the decision): still the second of two.
    store.received(.decisions([sequence.shown]))
    #expect((store.decisionSequence(of: agent).map { [$0.position, $0.total] } ?? []) == [2, 2] as [Int])
}

@MainActor @Test func onlyTheLastAnswerCanBeUndone() throws {
    let (store, agent, sent) = board { [decision($0, "First"), decision($0, "Second")] }
    store.answer(store.decisions[0], .ok)
    let last = store.decisions[1]

    // The last question: held for the undo window, the core hasn't heard it.
    store.answer(last, .redirect("Smaller"))
    #expect(store.pendingAnswers[agent]?.decision == last.id)
    #expect(store.pendingAnswers[agent]?.secondsLeft == DecisionMetrics.undoSeconds)
    #expect(sent().count == 1)
    #expect(store.decisionSequence(of: agent)?.shown.id == last.id)
    #expect(store.decisionSequence(of: agent)?.isWaiting == true)

    // Undo takes back that answer only: the question shows again, the first stays sent.
    store.undoAnswer(of: agent)
    #expect(store.pendingAnswers.isEmpty)
    #expect(sent().count == 1)
    #expect((store.decisionSequence(of: agent).map { [$0.position, $0.total] } ?? []) == [2, 2] as [Int])

    // Answered again and confirmed (the window closing, or the user leaving): sent.
    store.answer(last, .ok)
    store.confirmAnswer(of: agent)
    #expect(store.pendingAnswers.isEmpty)
    #expect(sent().count == 2)
    // An OK needs nothing more from the agent: the balloon has nothing left to show.
    #expect(store.decisionSequence(of: agent) == nil)
}

@MainActor @Test func aQuestionArrivingDuringTheUndoWindowConfirmsTheHeldAnswer() throws {
    let (store, agent, sent) = board { [decision($0, "First")] }
    let first = store.decisions[0]
    store.answer(first, .ok)
    #expect(sent().isEmpty)

    let second = decision(agent, "Second")
    store.received(.decisions([first, second]))
    #expect(store.pendingAnswers.isEmpty)
    #expect(sent().map(\.0) == [first.id])
    let sequence = try #require(store.decisionSequence(of: agent))
    #expect(sequence.shown.id == second.id)
    #expect([sequence.position, sequence.total] == [2, 2] as [Int])
}

@MainActor @Test func aHeldAnswerGoesWhenTheDecisionIsWithdrawn() {
    let (store, agent, _) = board { [decision($0, "First")] }
    store.answer(store.decisions[0], .ok)
    store.received(.decisions([]))
    #expect(store.pendingAnswers.isEmpty)
    #expect(store.decisionSequence(of: agent) == nil)
}

@MainActor @Test func aRedirectStaysShownUntilTheAgentEchoes() throws {
    let (store, agent, _) = board { [decision($0, "First")] }
    store.answer(store.decisions[0], .redirect("Smaller"))
    store.confirmAnswer(of: agent)
    let sequence = try #require(store.decisionSequence(of: agent))
    #expect(!sequence.isWaiting)
}

@MainActor @Test func decisionsWaitInTheQueueAroundTheAttentionItems() {
    let store = AgentStore(connect: { .failure(.noCore) })
    let ids = (0..<5).map { _ in UUID() }
    for id in ids { store.received(.cardAdded(AgentRecord(id: id, worktree: "/w", providerID: "claude", name: "Agent", frame: .zero))) }
    let (provisional, blocked, prompting, both, sent) = (ids[0], ids[1], ids[2], ids[3], ids[4])
    let answered = decision(sent, "Sent")
    store.received(.decisions([
        decision(provisional, "A"), decision(provisional, "B"), decision(blocked, "C", blocking: true), decision(both, "D"), answered,
    ]))
    // Its answer is on its way: nothing left for the user there.
    store.answer(answered, .redirect("Smaller"))
    store.confirmAnswer(of: sent)
    let attention = [
        AttentionRequest(id: prompting, reason: .turnEnded),
        // Ended its turn while its decision waits: the decision alone.
        AttentionRequest(id: both, reason: .turnEnded),
        // An agent no store has.
        AttentionRequest(id: UUID(), reason: .turnEnded),
    ]
    let queue = NeedsYouItem.queue(stores: [store], attention: attention)
    #expect(queue.map(\.id) == [
        NeedsYouItem.ID(agent: blocked, isDecision: true),
        NeedsYouItem.ID(agent: prompting, isDecision: false),
        // One card per agent, however many questions it has.
        NeedsYouItem.ID(agent: provisional, isDecision: true),
        NeedsYouItem.ID(agent: both, isDecision: true),
    ])
}

@Test func aPlaceNamesTheProjectFirst() {
    #expect(ProjectStore.Place(project: "Shop", worktree: "Checkout").title == "Shop - Checkout")
    #expect(ProjectStore.Place(project: nil, worktree: "scratch").title == "scratch")
}
