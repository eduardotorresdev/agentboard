import Foundation
import Testing
@testable import AgentBoard

private func repository() throws -> URL {
    let repository = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentboard-draft-\(UUID().uuidString)/repo")
    try Git.createRepository(at: repository)
    return repository
}

@Test func theTypedNameBecomesABranchSlug() {
    #expect(WorktreeDraft.slug("Fix the Login redirect!") == "fix-the-login-redirect")
    #expect(WorktreeDraft.slug("  Ação rápida / v2 ") == "acao-rapida-v2")
    #expect(WorktreeDraft.slug("🙂") == "")
}

/// Regression: confirming a new name used to report that its folder already existed, because
/// the check ran again after creation and found the folder just made.
@MainActor @Test func creatingRunsOnceAndNeverFlagsItsOwnFolder() async throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    let draft = WorktreeDraft(repository: repo.path)
    draft.name = "Fix login"
    await draft.validate()
    #expect(draft.canSubmit)

    var calls = 0
    let add: (String) throws -> Void = { calls += 1; try Git.addWorktree(branch: $0, to: repo.path) }
    #expect(draft.create(using: add))
    #expect(!draft.create(using: add))
    await draft.validate()

    #expect(calls == 1)
    #expect(draft.problem == nil)
}

@MainActor @Test func aFolderThatAlreadyExistsIsReported() async throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: Git.worktreeLocation(for: "taken", in: repo.path), withIntermediateDirectories: true)
    let draft = WorktreeDraft(repository: repo.path)
    draft.name = "Taken"
    await draft.validate()

    // The message names the folder; checked that way so the test doesn't depend on the locale.
    let taken = (Git.worktreeLocation(for: "taken", in: repo.path).path as NSString).abbreviatingWithTildeInPath
    #expect(draft.problem?.contains(taken) == true)
    #expect(!draft.canSubmit)
}
