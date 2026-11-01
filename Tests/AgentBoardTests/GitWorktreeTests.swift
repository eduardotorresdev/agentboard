import Foundation
import Testing
@testable import AgentBoard

/// A repository on `main` with one commit, in a fresh temporary folder.
private func repository() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentboard-git-\(UUID().uuidString)")
    let repository = folder.appendingPathComponent("repo")
    try Git.createRepository(at: repository)
    return repository
}

private func git(_ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
}

private func cleanUp(_ repository: URL) {
    try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
}

@Test func aNewBranchGetsAWorktreeBesideTheRepository() throws {
    let repo = try repository()
    defer { cleanUp(repo) }

    #expect(Git.worktreeStart(for: "feature/login", in: repo.path) == .newBranch(from: "main"))
    let path = try Git.addWorktree(branch: "feature/login", to: repo.path)

    #expect(path == repo.deletingLastPathComponent().appendingPathComponent("repo-worktrees/feature-login").path)
    let worktrees = try #require(Git.worktrees(at: repo.path))
    #expect(worktrees.map(\.branch) == ["main", "feature/login"])
}

@Test func anExistingBranchIsCheckedOutInsteadOfCreated() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    try git("-C", repo.path, "branch", "fix")

    #expect(Git.worktreeStart(for: "fix", in: repo.path) == .existingBranch)
    try Git.addWorktree(branch: "fix", to: repo.path)

    #expect(Git.worktrees(at: repo.path)?.last?.branch == "fix")
}

@Test func aBranchCheckedOutElsewhereIsRefused() throws {
    let repo = try repository()
    defer { cleanUp(repo) }

    #expect(throws: GitError.self) { try Git.addWorktree(branch: "main", to: repo.path) }
}

@Test func gitDecidesWhichBranchNamesAreValid() {
    #expect(Git.isValidBranchName("feature/login"))
    #expect(!Git.isValidBranchName(""))
    #expect(!Git.isValidBranchName("has space"))
    #expect(!Git.isValidBranchName("ends."))
}
