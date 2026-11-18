import AgentRuntime
import Foundation
import Orchestration
import Testing
@testable import AgentBoard

// MARK: Fallback

@Test func fallbackKeepsEveryWordAndDot() {
    #expect(WorktreeTitle.fallback(folder: "release-1.2", isMain: false) == "Release 1.2")
    #expect(WorktreeTitle.fallback(folder: "hotfix-2.1.3", isMain: false) == "Hotfix 2.1.3")
    #expect(WorktreeTitle.fallback(folder: "docs-site", isMain: false) == "Docs site")
    #expect(WorktreeTitle.fallback(folder: "feat-x", isMain: false) == "Feat x")
    #expect(WorktreeTitle.fallback(folder: "board-input_mentions", isMain: false) == "Board input mentions")
    #expect(WorktreeTitle.fallback(folder: "storefront", isMain: true) == WorktreeTitle.mainLabel)
}

@Test func userTitleBeatsTheAgentWhichBeatsTheFallback() {
    #expect(WorktreeTitle.resolve(user: "Mine", agent: "Fix login", folder: "wt-1", isMain: false) == "Mine")
    #expect(WorktreeTitle.resolve(user: nil, agent: "Fix login", folder: "wt-1", isMain: false) == "Fix login")
    #expect(WorktreeTitle.resolve(user: nil, agent: nil, folder: "wt-1", isMain: false) == "Wt 1")
}

// MARK: Sanitizing

@Test func cleanStripsControlFormatAndBidiCharacters() {
    #expect(WorktreeTitle.clean("\u{202E}abc\tdef\u{0}\u{1B}") == "abc def")
    #expect(WorktreeTitle.clean(" a\nb ") == "a b")
    #expect(WorktreeTitle.clean("so\u{00AD}ft") == "soft")
}

@Test func cleanRejectsTitlesWithNothingVisible() {
    for blank in ["", "  \n ", "\u{2060}", "\u{FEFF}", "\u{200E}", "\u{200D}", "\u{00AD}", "\u{2800}", "\u{3164}", "\u{0301}\u{0301}"] {
        #expect(WorktreeTitle.clean(blank) == nil, "\(blank.unicodeScalars.map { String($0.value, radix: 16) })")
    }
}

@Test func cleanCapsCharactersAndBytes() throws {
    let long = try #require(WorktreeTitle.clean(String(repeating: "x", count: 100)))
    #expect(long.count == WorktreeTitle.maxLength)
    let wide = try #require(WorktreeTitle.clean(String(repeating: "漢", count: 100)))
    #expect(wide.utf8.count <= WorktreeTitle.maxBytes)
    #expect(wide.count == min(WorktreeTitle.maxLength, WorktreeTitle.maxBytes / 3))
}

@Test func cleanDropsAGiantCharacterButKeepsTheRest() {
    let giant = "e" + String(repeating: "\u{0301}", count: 5000)
    #expect(WorktreeTitle.clean(giant + " fix login") == "fix login")
    #expect(WorktreeTitle.clean("fix " + giant + "login") == "fix login")
}

@Test func cleanKeepsJoinedEmojiAndScripts() {
    for text in ["👨‍👩‍👧‍👦 family", "👩🏽‍💻 dev", "🏳️‍🌈 pride", "🏴󠁧󠁢󠁳󠁣󠁴󠁿 scotland", "می‌خواهم", "ශ්‍රී ලංකා", "\u{0600}123"] {
        #expect(WorktreeTitle.clean(text) == text, "\(text)")
    }
}

@Test func cleanRejectsPlaceholderCharacters() {
    for blank in ["\u{FFFC}", "\u{1D159}", "\u{E000}", "\u{0378}", "\u{FFFF}"] {
        #expect(WorktreeTitle.clean(blank) == nil, "\(blank.unicodeScalars.map { String($0.value, radix: 16) })")
    }
}

@Test func titlesCantPassForTheMainCheckout() {
    #expect(WorktreeTitle.isReserved("Main checkout"))
    #expect(WorktreeTitle.isReserved("MAIN  checkout!"))
    #expect(WorktreeTitle.isReserved("\u{041C}ain checkout"))  // Cyrillic Em
    #expect(WorktreeTitle.isReserved(WorktreeTitle.mainLabel))
    #expect(!WorktreeTitle.isReserved("Main checkout fixes"))
}

// MARK: Renaming

@Test func leavingTheFieldUntouchedDoesntLockAStaleTitle() {
    #expect(WorktreeTitle.renameAction(draft: "A", opened: "A", openedIsFallback: false, confirmed: false) == .none)
    #expect(WorktreeTitle.renameAction(draft: "B", opened: "A", openedIsFallback: false, confirmed: false) == .set("B"))
}

@Test func confirmingPinsAnUnchangedAgentTitleButNotAFallback() {
    #expect(WorktreeTitle.renameAction(draft: "A", opened: "A", openedIsFallback: false, confirmed: true) == .set("A"))
    #expect(WorktreeTitle.renameAction(draft: "A", opened: "A", openedIsFallback: true, confirmed: true) == .none)
    #expect(WorktreeTitle.renameAction(draft: " ", opened: "A", openedIsFallback: false, confirmed: true) == .set(""))
}

// MARK: The store and the tool

@MainActor
private func storeWithWorktree() throws -> (ProjectStore, Project, Worktree) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abtitles-\(UUID().uuidString)")
    let repository = folder.appendingPathComponent("repo")
    _ = isolatedGitConfig
    try Git.createRepository(at: repository)
    let store = ProjectStore(databaseURL: folder.appendingPathComponent("db.sqlite"))
    let project = try #require(store.addProject(at: repository))
    let worktree = try #require(try store.addWorktree(branch: "eduardo/fix-login", to: project))
    return (store, project, worktree)
}

@MainActor @Test func theLatestTitleWinsWhetherTheUserOrAnAgentGaveIt() throws {
    let (store, _, worktree) = try storeWithWorktree()
    #expect(store.displayName(of: worktree) == "Eduardo fix login")
    #expect(store.setAgentTitle("Login bug", path: worktree.path) == .applied)
    #expect(store.displayName(of: worktree) == "Login bug")
    store.rename(worktree, to: "Mine")
    #expect(store.displayName(of: worktree) == "Mine")
    #expect(store.setAgentTitle("Other", path: worktree.path) == .applied)
    #expect(store.displayName(of: worktree) == "Other")
    #expect(!store.isNamedByUser(worktree))
}

@MainActor @Test func theInitialTitleIsRefinedByAgents() throws {
    let (store, _, worktree) = try storeWithWorktree()
    #expect(store.setInitialTitle("Typed at creation", path: worktree.path) == .applied)
    #expect(store.setInitialTitle("X", path: "/nowhere") == .unknownWorktree)
    #expect(store.displayName(of: worktree) == "Typed at creation")
    #expect(store.setAgentTitle("Refined", path: worktree.path) == .applied)
    #expect(store.displayName(of: worktree) == "Refined")
}

@MainActor @Test func titlesForUnknownPathsAreRefused() throws {
    let (store, _, _) = try storeWithWorktree()
    #expect(store.setAgentTitle("X", path: "/nowhere") == .unknownWorktree)
}

@MainActor @Test func aWorktreeMadeAgainDoesntInheritOldTitles() throws {
    let (store, project, worktree) = try storeWithWorktree()
    store.rename(worktree, to: "Mine")
    store.removeWorktree(worktree, from: project, force: true)
    let again = try #require(try store.addWorktree(branch: "eduardo/fix-login", to: project))
    #expect(store.displayName(of: again) == "Eduardo fix login")
}

@MainActor @Test func titlesAreWrittenOffTheMainThreadAndKept() throws {
    let (store, _, worktree) = try storeWithWorktree()
    #expect(store.setAgentTitle("Login bug", path: worktree.path) == .applied)
    store.rename(worktree, to: "Mine")
    // Shown before the write lands; on disk once the writer is done.
    #expect(store.displayName(of: worktree) == "Mine")
    store.finishTitleWrites()
    #expect(try store.database?.worktreeTitles()[worktree.path] == "Login bug")
    #expect(try store.database?.aliases()[worktree.path] == "Mine")
}

@MainActor @Test func aMissingPathKeepsItsNamesOnReload() throws {
    let (store, project, worktree) = try storeWithWorktree()
    #expect(store.setAgentTitle("Login bug", path: worktree.path) == .applied)
    store.rename(worktree, to: "Mine")
    store.finishTitleWrites()
    // Gone from disk (removed outside the app, or an unmounted volume): never a reason to forget.
    try Git.removeWorktree(at: worktree.path, from: project.path, force: true)
    store.reload()
    #expect(store.aliases[worktree.path] == "Mine")
    #expect(store.agentTitles[worktree.path] == "Login bug")
    #expect(try store.database?.aliases()[worktree.path] == "Mine")
    #expect(try store.database?.worktreeTitles()[worktree.path] == "Login bug")
}

@MainActor @Test func titlesReachWorktreesOfAnotherOrganization() throws {
    let (store, _, _) = try storeWithWorktree()
    let other = UUID()
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent("abtitles-other-\(UUID().uuidString)")
    _ = isolatedGitConfig
    try Git.createRepository(at: repository)
    // Straight to the database: no organization is created, nothing touches the keychain.
    store.addProject(at: repository, to: other)
    let path = try #require(Git.worktrees(at: repository.path)?.first?.path)
    #expect(store.setAgentTitle("Elsewhere", path: path) == .unknownWorktree)
    #expect(store.setAgentTitle("Elsewhere", path: path, in: other) == .applied)
    #expect(store.displayName(ofPath: path) == "Elsewhere")
}

@MainActor @Test func agentsCantTitleAWorktreeLikeTheMainCheckout() throws {
    let (store, _, worktree) = try storeWithWorktree()
    #expect(store.setAgentTitle("Main checkout", path: worktree.path) == .invalid)
    #expect(store.setAgentTitle("\u{2060}", path: worktree.path) == .invalid)
}

@MainActor @Test func theToolTitlesTheCallersWorktreeOverTheUsersTitle() async throws {
    let (store, _, worktree) = try storeWithWorktree()
    let agents = AgentStore(database: FileManager.default.temporaryDirectory.appendingPathComponent("abcards-\(UUID().uuidString).sqlite"),
                            connect: { .failure(.noCore) })
    let tools = ProjectTools(projects: store, agents: agents)
    let caller = AgentRecord(id: UUID(), worktree: worktree.path, providerID: "claude", name: "Claude",
                             frame: .zero, organization: store.organizationID)
    agents.insert(caller)
    #expect(await tools.call("worktree_set_title", arguments: ["title": "X"], caller: UUID()).isError)
    #expect(await tools.call("worktree_set_title", arguments: ["title": "\u{2060}"], caller: caller.id).isError)
    #expect(!(await tools.call("worktree_set_title", arguments: ["title": "Login bug"], caller: caller.id).isError))
    #expect(store.displayName(of: worktree) == "Login bug")
    store.rename(worktree, to: "Mine")
    let retitled = await tools.call("worktree_set_title", arguments: ["title": "Other"], caller: caller.id)
    #expect(!retitled.isError)
    #expect(store.displayName(of: worktree) == "Other")
}

// MARK: States

@Test func statesComeFromTheSessionStatus() {
    let exited = { (code: Int32) in SessionStatus(state: .exited, processID: nil, exitCode: code) }
    let running = SessionStatus(state: .running, processID: 1, exitCode: nil)
    // The runner report only says a runner has run: a known status wins over it.
    #expect(CardStatus.runner(exited(1), running: true) == .crashed)
    #expect(CardStatus.runner(exited(0), running: true) == .stopped)
    #expect(CardStatus.runner(exited(137), running: true) == .crashed)
    #expect(CardStatus.runner(exited(143), running: true) == .stopped)
    #expect(CardStatus.runner(SessionStatus(state: .stopped, processID: nil, exitCode: nil), running: true) == .stopped)
    #expect(CardStatus.runner(nil, running: true) == .running)
    #expect(CardStatus.agent(exited(1), waiting: false) == .crashed)
    // A crash beats waiting.
    #expect(CardStatus.agent(exited(1), waiting: true) == .crashed)
    #expect(CardStatus.agent(running, waiting: true) == .waiting)
    #expect([CardStatus.stopped, .crashed, .running].max() == .crashed)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// Runners through the board's store and a core: a runner's sidebar state follows how it ended.
@MainActor @Test func runnerStatesFollowTheirPrograms() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abrunners-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let agents = AgentStore(database: folder.appendingPathComponent("cards.sqlite"), connect: { .failure(.noCore) })
    try await waitUntil { agents.core != nil }
    func state(_ id: UUID) -> CardStatus { CardStatus.runner(agents.statuses[id], running: agents.runningRunners.contains(id)) }
    func run(_ command: String) -> UUID {
        let record = agents.addRunner(command: command, name: nil, directory: folder.path, to: folder.path, at: .zero)
        _ = agents.session(for: record, cols: 40, rows: 6)
        return record.id
    }
    let failing = run("sleep 0.3; exit 1")
    let finishing = run("sleep 0.3; exit 0")
    let stopped = run("sleep 30")
    // Stopped at once, before the core may have launched it: the stop must still hold.
    agents.stopRunner(stopped)
    try await waitUntil { state(failing) == .crashed && state(finishing) == .stopped && state(stopped) == .stopped }
    #expect(state(failing) == .crashed)
    #expect(state(finishing) == .stopped)
    #expect(state(stopped) == .stopped, "\(String(describing: agents.statuses[stopped]))")
}

@Test func aProjectsTileColorIsFixedByItsName() {
    // djb2 over the name's scalars, modulo the palette: the same on every launch and machine.
    #expect(ProjectTile.colorIndex(for: "storefront") == 3)
    #expect(ProjectTile.colorIndex(for: "docs-site") == 0)
    #expect(ProjectTile.colorIndex(for: "api-gateway") == 2)
}

// MARK: The user's own board

@MainActor @Test func theUsersBoardIsTitledByThemAndAgentsStartInItOrInAWorktree() async throws {
    let (store, _, worktree) = try storeWithWorktree()
    let board = store.board
    #expect(MyBoard.isBoard(board.path) && !MyBoard.isBoard(worktree.path))
    #expect(!MyBoard.isBoard((board.path as NSString).deletingLastPathComponent + "/claude/board"))
    #expect(FileManager.default.fileExists(atPath: board.path))
    #expect(store.displayName(of: board) == MyBoard.defaultTitle)
    store.rename(board, to: "Life")
    #expect(store.displayName(of: board) == "Life")

    let agents = AgentStore(database: FileManager.default.temporaryDirectory.appendingPathComponent("abcards-\(UUID().uuidString).sqlite"),
                            connect: { .failure(.noCore) })
    let tools = ProjectTools(projects: store, agents: agents)
    let caller = AgentRecord(id: UUID(), worktree: board.path, providerID: "claude", name: "Claude",
                             frame: .zero, organization: store.organizationID)
    agents.insert(caller)
    // What `agent_start` asks before starting an agent somewhere else.
    #expect(!(await tools.call("worktree_resolve", arguments: ["path": worktree.path], caller: caller.id).isError))
    #expect(!(await tools.call("worktree_resolve", arguments: ["path": board.path], caller: caller.id).isError))
    #expect(await tools.call("worktree_resolve", arguments: ["path": NSTemporaryDirectory()], caller: caller.id).isError)
    // Only the user titles their board.
    #expect(!(await tools.call("worktree_set_title", arguments: ["title": "Other"], caller: caller.id).isError))
    store.rename(board, to: "")
    #expect(store.displayName(of: board) == MyBoard.defaultTitle)
}
