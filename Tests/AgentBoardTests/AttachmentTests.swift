import Testing
@testable import AgentBoard

@Test func droppedPathsAreTypedAsAShellTakesThem() {
    #expect(AgentStore.typed(["/tmp/My Shot (1).png", "/a/b.txt"]) == #"/tmp/My\ Shot\ \(1\).png /a/b.txt "#)
    #expect(AgentStore.typed([]) == "")
}
