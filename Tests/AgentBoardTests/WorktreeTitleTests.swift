import AgentRuntime
import Testing
@testable import AgentBoard

@Test func titleFallsBackToTheFolderMadeReadable() {
    #expect(WorktreeTitle.resolve(user: nil, agent: nil, folder: "board-input_mentions") == "Board input mentions")
    #expect(WorktreeTitle.humanize("agentboard") == "Agentboard")
}

@Test func agentTitleBeatsTheFolder() {
    #expect(WorktreeTitle.resolve(user: nil, agent: "Fix login", folder: "wt-1") == "Fix login")
}

@Test func userTitleBeatsTheAgent() {
    #expect(WorktreeTitle.resolve(user: "Mine", agent: "Fix login", folder: "wt-1") == "Mine")
}

@Test func cleanKeepsOneShortLine() {
    #expect(WorktreeTitle.clean("  \n ") == nil)
    #expect(WorktreeTitle.clean(" a\nb ") == "a b")
    #expect(WorktreeTitle.clean(String(repeating: "x", count: 100))?.count == WorktreeTitle.maxLength)
}

@Test func runnerExitingWithAnErrorReadsAsCrashed() {
    let exited = { (code: Int32) in SessionStatus(state: .exited, processID: nil, exitCode: code) }
    #expect(CardStatus.runner(exited(1), running: false) == .crashed)
    #expect(CardStatus.runner(exited(0), running: false) == .stopped)
    #expect(CardStatus.runner(nil, running: true) == .running)
    #expect(CardStatus.agent(SessionStatus(state: .running, processID: 1, exitCode: nil), waiting: true) == .waiting)
    #expect([CardStatus.stopped, .crashed, .running].max() == .crashed)
}

@Test func aProjectKeepsItsTileColor() {
    #expect(ProjectTile.colorIndex(for: "storefront") == ProjectTile.colorIndex(for: "storefront"))
    #expect(Set(["storefront", "docs-site", "api-gateway", "agentboard"].map(ProjectTile.colorIndex(for:))).count > 1)
}
