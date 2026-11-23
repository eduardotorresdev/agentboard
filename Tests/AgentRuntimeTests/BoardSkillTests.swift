import Foundation
import Testing
@testable import AgentRuntime

@Test func theSkillIsTheCoresTextAndThePluginCarriesIt() throws {
    let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../core/crates/runtime/src/board_skill.md")
    #expect(try String(contentsOf: core, encoding: .utf8) == BoardSkill.text)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-plugin-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try BoardSkill.write(to: root)
    #expect(try String(contentsOf: root.appendingPathComponent("skills/board/SKILL.md"), encoding: .utf8) == BoardSkill.text)
}
