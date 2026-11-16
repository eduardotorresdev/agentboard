import AgentRuntime
import CoreGraphics
import Foundation
import Orchestration
import Testing
@testable import AgentBoard

struct OrganizationMenuModelTests {
    let active = UUID(), other = UUID(), third = UUID()

    func card(_ organization: UUID?, runner: Bool = false) -> AgentRecord {
        AgentRecord(id: UUID(), worktree: "/w", providerID: "claude", name: "a", frame: .zero,
                    runner: runner ? RunnerSpec(command: "x", directory: "/w", owner: nil) : nil, organization: organization)
    }

    func status(_ state: AgentSession.State, exitCode: Int32? = nil) -> SessionStatus {
        SessionStatus(state: state, processID: nil, exitCode: exitCode)
    }

    /// The cards' own rule, as `AgentStore.cardStatus` applies it to agents.
    func aggregate(_ cards: [AgentRecord], statuses: [UUID: SessionStatus], waiting: Set<UUID>) -> [UUID: OrganizationAttention] {
        OrganizationAttention.byOrganization(cards: cards, status: { CardStatus.agent(statuses[$0.id], waiting: waiting.contains($0.id)) },
                                             active: active)
    }

    // MARK: Attention per organization

    @Test func countsWaitingAndCrashedAgentsPerOtherOrganization() {
        let waiting = card(other), crashed = card(other), running = card(other), elsewhere = card(third)
        let result = aggregate([waiting, crashed, running, elsewhere], statuses: [waiting.id: status(.running), crashed.id: status(.exited, exitCode: 1),
                       running.id: status(.running), elsewhere.id: status(.running)], waiting: [waiting.id, elsewhere.id])
        #expect(result[other] == OrganizationAttention(waiting: 1, crashed: 1))
        #expect(result[third] == OrganizationAttention(waiting: 1, crashed: 0))
        #expect(result[other]?.status == .waiting) // waiting outranks crashed, as on cards
    }

    @Test func theActiveOrganizationIsNeverFlagged() {
        let mine = card(active)
        let result = aggregate([mine], statuses: [mine.id: status(.failed("boom"))], waiting: [mine.id])
        #expect(result.isEmpty)
    }

    @Test func organizationsWithNothingPendingAndRunnersAreAbsent() {
        let quiet = card(other), stopped = card(other), runner = card(third, runner: true)
        let result = aggregate([quiet, stopped, runner], statuses: [quiet.id: status(.running), stopped.id: status(.exited, exitCode: 130), runner.id: status(.failed("boom"))], waiting: [])
        #expect(result.isEmpty)
    }

    @Test func cardsFromBeforeOrganizationsCountForTheDefaultOne() {
        let legacy = card(nil)
        let result = aggregate([legacy], statuses: [legacy.id: status(.failed("boom"))], waiting: [])
        #expect(result[OrganizationHome.defaultID]?.crashed == 1)
    }

    @Test func barShowsTheMostPressingStatus() {
        #expect(OrganizationAttention.barStatus([:]) == nil)
        #expect(OrganizationAttention.barStatus([other: .init(crashed: 2)]) == .crashed)
        #expect(OrganizationAttention.barStatus([other: .init(crashed: 2), third: .init(waiting: 1)]) == .waiting)
    }

    @Test func summaryReadsLikeTheCards() {
        #expect(OrganizationAttention().summary == nil)
        #expect(OrganizationAttention(waiting: 2).summary?.contains("2") == true)
        #expect(OrganizationAttention(waiting: 1, crashed: 1).summary?.contains(", ") == true)
    }

    // MARK: Keyboard

    @Test func startsOnTheActiveOrganizationAndSelectsAnotherOnlyOnReturn() {
        var navigation = OrganizationMenuNavigation(organizations: [active, other, third], active: active)
        #expect(navigation.highlightedItem == .organization(active))
        #expect(navigation.press(.down, active: active) == .none)
        #expect(navigation.press(.enter, active: active) == .select(other))
    }

    @Test func returnOnTheActiveOrganizationOnlyCloses() {
        var navigation = OrganizationMenuNavigation(organizations: [active, other], active: active)
        #expect(navigation.press(.enter, active: active) == .close)
        #expect(navigation.press(.escape, active: active) == .close)
    }

    @Test func arrowingOntoNewOrganizationDoesNotCreateIt() {
        var navigation = OrganizationMenuNavigation(organizations: [active, other], active: active)
        for _ in 0 ..< 5 { #expect(navigation.press(.down, active: active) == .none) } // stops at the end
        #expect(navigation.highlightedItem == .create)
        #expect(navigation.press(.up, active: active) == .none)
        #expect(navigation.press(.down, active: active) == .none)
        #expect(navigation.press(.escape, active: active) == .close)
        #expect(navigation.press(.enter, active: active) == .create) // only Return creates
    }

    @Test func arrowsStopAtTheTop() {
        var navigation = OrganizationMenuNavigation(organizations: [active, other], active: active)
        _ = navigation.press(.up, active: active)
        #expect(navigation.highlightedItem == .organization(active))
    }

    @Test func hoverMovesTheHighlight() {
        var navigation = OrganizationMenuNavigation(organizations: [active, other], active: active)
        navigation.highlight(.organization(other))
        #expect(navigation.press(.enter, active: active) == .select(other))
    }
}
