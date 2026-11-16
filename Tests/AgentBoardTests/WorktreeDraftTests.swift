import Foundation
import Testing
@testable import AgentBoard

/// A repository on `main` in a fresh temporary folder; never the user's own repositories.
private func repository() throws -> URL {
    let repository = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentboard-draft-\(UUID().uuidString)/repo")
    _ = isolatedGitConfig
    try Git.createRepository(at: repository)
    return repository
}

private func cleanUp(_ repo: URL) {
    try? FileManager.default.removeItem(at: repo.deletingLastPathComponent())
}

private func git(_ arguments: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.environment = Git.environment
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}

private func hook(_ name: String, in repo: URL, script: String) throws {
    let file = repo.appendingPathComponent(".git/hooks/\(name)")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n\(script)\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
}

private func branchExists(_ branch: String, in repo: URL) -> Bool {
    Git.worktreeStart(for: branch, in: repo.path) == .existingBranch
}

// MARK: Slugs and names

@Test func theTypedNameBecomesABranchSlug() {
    #expect(WorktreeDraft.slug("Fix the Login redirect!") == "fix-the-login-redirect")
    #expect(WorktreeDraft.slug("  Ação rápida / v2 ") == "acao-rapida-v2")
    #expect(WorktreeDraft.slug("Ærø søk") == "aero-sok")
    #expect(WorktreeDraft.slug("Исправить вход") == "ispravit-vhod")
    #expect(!WorktreeDraft.slug("日本語").isEmpty)
    #expect(WorktreeDraft.slug("🙂") == "")
}

@Test func aNameWithNothingToSlugStillGetsABranch() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let check = WorktreeDraft.inspect("🙂", in: repo.path)
    #expect(check.branch == "worktree")
    #expect(check.problem == nil)
}

@Test func aTakenSlugIsNumberedInsteadOfRefused() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    try FileManager.default.createDirectory(
        at: Git.worktreeLocation(for: "fix-login", in: repo.path), withIntermediateDirectories: true)
    git("-C", repo.path, "branch", "fix-login-2")

    let check = WorktreeDraft.inspect("Fix login", in: repo.path)
    #expect(check.branch == "fix-login-3")
    #expect(check.problem == nil)
}

@Test func anExistingBranchNameIsUsedAsIs() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    git("-C", repo.path, "branch", "feature/login")

    let check = WorktreeDraft.inspect("feature/login", in: repo.path)
    #expect(check.branch == "feature/login")
    #expect(check.start == .existingBranch)
    #expect(check.problem == nil)
}

@Test func aBranchOpenInAnotherWorktreeIsReported() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let check = WorktreeDraft.inspect("main", in: repo.path)
    #expect(check.branch == "main")
    #expect(check.problem != nil)
}

@Test func anExistingBranchWhoseFolderIsTakenIsReported() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    git("-C", repo.path, "branch", "taken")
    let location = Git.worktreeLocation(for: "taken", in: repo.path)
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)

    let check = WorktreeDraft.inspect("taken", in: repo.path)
    // Names the folder; checked that way so the test doesn't depend on the locale.
    #expect(check.problem?.contains(DisplayPath.short(location.path, base: repo.path)) == true)
}

@Test func projectNamesThatArentNewFoldersAreRefused() {
    for name in [".", "..", ".hidden", "a/b", "a:b"] {
        #expect(AddProjectDialog.nameProblem(name) != nil, "\(name)")
    }
    #expect(AddProjectDialog.nameProblem("my-project") == nil)
}

// MARK: The draft

@MainActor @Test func creatingRunsOnceAndNeverFlagsItsOwnFolder() async throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let draft = WorktreeDraft(repository: repo.path)
    var created: [Git.CreatedWorktree] = []
    draft.onCreated = { created.append($0) }
    draft.name = "Fix login"
    await draft.validate()

    await draft.submit()
    await draft.submit()
    await draft.validate()

    #expect(created.count == 1)
    #expect(created.first?.warning == nil)
    #expect(draft.problem == nil)
}

@MainActor @Test func submittingWhileTheNameIsCheckedCreatesOnceTheCheckPasses() async throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let draft = WorktreeDraft(repository: repo.path)
    var created = 0
    draft.onCreated = { _ in created += 1 }
    draft.name = "Quick"

    await draft.submit()
    #expect(created == 0)
    await draft.validate()

    #expect(created == 1)
}

@MainActor @Test func aCheckForAnOlderNameIsDropped() async throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let draft = WorktreeDraft(repository: repo.path)
    draft.name = "First"
    let stale = Task { await draft.validate() }
    draft.name = "Second"
    await stale.value
    #expect(draft.check?.name != "First")
    await draft.validate()
    #expect(draft.check?.name == "Second")
}

@MainActor @Test func returnDoesNotClearTheError() {
    let draft = WorktreeDraft(repository: "/nonexistent")
    draft.name = "main"
    draft.error = "git refused"
    draft.name = "main"
    #expect(draft.error == "git refused")
    draft.name = "main2"
    #expect(draft.error == nil)
}

// MARK: Partial failures

@Test func aFailingHookAfterCheckoutStillCountsAsCreated() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    try hook("post-checkout", in: repo, script: "echo 'git-lfs: command not found' >&2; exit 2")

    let created = try Git.createWorktree(branch: "with-hook", in: repo.path)

    #expect(created.warning?.contains("git-lfs") == true)
    #expect(Git.worktrees(at: repo.path)?.contains { $0.branch == "with-hook" } == true)
}

@Test func aFailedAttemptDoesntLeaveItsBranch() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    try hook("reference-transaction", in: repo, script: "[ \"$1\" = prepared ] && exit 1; exit 0")

    #expect(throws: GitError.self) { try Git.createWorktree(branch: "retry", in: repo.path) }
    #expect(!branchExists("retry", in: repo))
}

@Test func aFailedInitialCommitKeepsTheRepository() throws {
    _ = isolatedGitConfig
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-sign-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let repo = folder.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    // Signing that can't run, set only in this repository's own config.
    git("-C", repo.path, "init", "-b", "main")
    git("-C", repo.path, "config", "commit.gpgsign", "true")
    git("-C", repo.path, "config", "gpg.program", "false")

    #expect(throws: Git.InitialCommitFailed.self) { try Git.createRepository(at: repo) }
    #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path))
}

@Test func toolFoldersGoAfterTheUsersPath() {
    #expect(Git.searchPath("/Users/me/bin:/usr/bin") == "/Users/me/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin")
    #expect(Git.searchPath("/usr/local/bin:/usr/bin") == "/usr/local/bin:/usr/bin:/opt/homebrew/bin")
}

// MARK: Cleanup never touches what this attempt didn't make

private func sha(_ ref: String, in repo: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.environment = Git.environment
    process.arguments = ["-C", repo.path, "rev-parse", "--verify", "--quiet", ref]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// P1: a failed create used to prune, wiping another worktree whose folder was briefly away.
@Test func aFailedCreateDoesntPruneOtherWorktrees() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let kept = try Git.addWorktree(branch: "kept", to: repo.path)
    let away = kept + ".away"
    try FileManager.default.moveItem(atPath: kept, toPath: away)
    try hook("reference-transaction", in: repo, script: "[ \"$1\" = prepared ] && exit 1; exit 0")

    #expect(throws: GitError.self) { try Git.createWorktree(branch: "boom", in: repo.path) }

    #expect(Git.worktrees(at: repo.path)?.contains { $0.branch == "kept" } == true)
    try FileManager.default.moveItem(atPath: away, toPath: kept)
}

/// P2: a branch someone else made after the check survives the failed attempt.
@Test func aBranchMadeByAnotherProcessSurvives() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    git("-C", repo.path, "branch", "race")
    let before = sha("refs/heads/race", in: repo)

    // Staged as if the check had found no such branch.
    #expect(throws: GitError.self) { try Git.createWorktree(branch: "race", in: repo.path, start: .newBranch(from: "main")) }

    #expect(before != nil && sha("refs/heads/race", in: repo) == before)
}

/// P3: files someone put in the target folder after the check survive.
@Test func filesInTheTargetFolderSurvive() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let location = Git.worktreeLocation(for: "busy", in: repo.path)
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    let theirs = location.appendingPathComponent("theirs.txt")
    try "keep me".write(to: theirs, atomically: true, encoding: .utf8)

    #expect(throws: GitError.self) { try Git.createWorktree(branch: "busy", in: repo.path) }

    #expect(FileManager.default.fileExists(atPath: theirs.path))
}

/// P4: two creates of the same name at once: one wins, and its worktree is still there.
@Test func twoCreatesOfTheSameNameLeaveOneWorktree() async throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let path = repo.path
    async let first = Task.detached { try? Git.createWorktree(branch: "twin", in: path) }.value
    async let second = Task.detached { try? Git.createWorktree(branch: "twin", in: path) }.value
    let results = await [first, second].compactMap { $0 }

    #expect(results.count == 1)
    let location = Git.worktreeLocation(for: "twin", in: path)
    #expect(FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path))
    #expect(Git.worktrees(at: path)?.contains { $0.branch == "twin" } == true)
}

/// N1: a hook that writes a lot to stderr used to block git forever.
@Test func aChattyHookDoesntHangCreation() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    try hook("post-checkout", in: repo, script: "head -c 300000 /dev/zero | tr '\\0' x >&2; exit 0")

    let created = try Git.createWorktree(branch: "chatty", in: repo.path)
    #expect(created.warning == nil)
}

// MARK: Names and branches

@Test func aRemoteOnlyBranchIsTrackedEvenWithATagOfTheSameName() throws {
    let origin = try repository()
    defer { cleanUp(origin) }
    git("-C", origin.path, "branch", "feat")
    let clone = origin.deletingLastPathComponent().appendingPathComponent("clone")
    git("clone", "--quiet", origin.path, clone.path)
    git("-C", clone.path, "tag", "feat")

    #expect(Git.worktreeStart(for: "feat", in: clone.path) == .remoteBranch("origin/feat"))
    _ = try Git.createWorktree(branch: "feat", in: clone.path)
    #expect(Git.worktrees(at: clone.path)?.contains { $0.branch == "feat" } == true)
}

@Test func aNameDifferingOnlyInCaseNeverLandsOnTheSameBranch() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    let check = WorktreeDraft.inspect("MAIN", in: repo.path)
    #expect(check.branch.lowercased() != "main")
}

@Test func aSlugNeverClashesWithBranchFolders() throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    git("-C", repo.path, "branch", "fix-login/sub")
    #expect(WorktreeDraft.inspect("Fix login", in: repo.path).branch == "fix-login-2")
}

@Test func aRepositoryWithoutCommitsSaysSo() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-empty-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = isolatedGitConfig
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    git("-C", folder.path, "init", "-b", "main")
    #expect(WorktreeDraft.inspect("main", in: folder.path).problem != nil)
}

@Test func slugsStopAtAWholeWord() {
    let slug = WorktreeDraft.slug(String(repeating: "alpha ", count: 20))
    #expect(slug.count <= 60)
    #expect(slug.split(separator: "-").allSatisfy { $0 == "alpha" })
}

@Test func causeDropsGitsProgressLines() {
    #expect(WorktreeDraft.cause(of: "Preparing worktree (new branch 'x')\nfatal: boom") == "fatal: boom")
    #expect(!WorktreeDraft.cause(of: "Preparing worktree (new branch 'x')").contains("Preparing"))
}

@Test func anEmptyPathStillFindsTheSystemTools() {
    #expect(Git.searchPath("").hasPrefix("/usr/bin"))
}

/// N3: an Enter typed before "continues the existing branch" was shown doesn't confirm it.
@MainActor @Test func aQueuedEnterDoesntContinueAnExistingBranch() async throws {
    let repo = try repository()
    defer { cleanUp(repo) }
    git("-C", repo.path, "branch", "dev")
    let draft = WorktreeDraft(repository: repo.path)
    var created = 0
    draft.onCreated = { _ in created += 1 }
    draft.name = "dev"

    await draft.submit()
    await draft.validate()
    #expect(created == 0)
    #expect(draft.check?.continuesBranch == true)

    await draft.submit()
    #expect(created == 1)
}
