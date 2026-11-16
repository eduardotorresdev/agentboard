@testable import AgentRuntime
import Connections
import Darwin
import Foundation
@testable import Orchestration
import Testing
@testable import AgentBoard

/// Another host that only records what it is asked to run. Every program succeeds printing
/// nothing, except the ones `answers` names by a piece of their command line.
private final class FakeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var ran: [String] = []
    private let answers: [(String, Int32, String)]

    init(_ answers: [(String, Int32, String)] = []) { self.answers = answers }

    var commands: [String] { lock.withLock { ran } }

    var git: GitHost {
        GitHost(name: "builder", home: "/home/dev") { [self] executable, arguments in
            let line = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
            lock.withLock { ran.append(line) }
            let answer = answers.first { line.contains($0.0) }
            let status = answer?.1 ?? 0, text = Data((answer?.2 ?? "").utf8)
            return (status, status == 0 ? text : Data(), status == 0 ? Data() : text)
        }
    }
}

/// A repository on `main` with an `origin` (which nothing fetches from), in a fresh temporary folder.
private func repository(origin: String = "https://example.invalid/team/repo.git") throws -> URL {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-hosts-\(UUID().uuidString)/repo")
    _ = isolatedGitConfig
    try Git.createRepository(at: repository)
    git("-C", repository.path, "remote", "add", "origin", origin)
    return repository
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

private func waitUntil(_ seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

private let clone = "/home/dev/agentboard/projects/repo"

// MARK: The commands a host is sent

@Test func theFirstWorktreeOnAHostClonesTheProjectThere() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    let host = FakeHost([("test -e", 1, ""), ("rev-parse", 0, "abc123\n")])

    let created = try Git.createWorktree(branch: "topic", in: repo.path, on: host.git)

    #expect(created.path == clone + "-worktrees/topic")
    // First, whose clone the project's folder there is (see `GitHost.clone(of:)`).
    #expect(host.commands.first?.hasSuffix("sh \(clone) \(clone)-\(Git.shortHash(of: "example.invalid/team/repo"))") == true)
    #expect(Array(host.commands.dropFirst()) == [
        "sh -c test -e \"$1\" sh \(clone)/.git",
        "sh -c mkdir -p \"$1\" sh /home/dev/agentboard/projects",
        "git clone -- https://example.invalid/team/repo.git \(clone)",
        "git -C \(clone) for-each-ref --format=%(refname) refs/heads/topic",
        "git -C \(clone) for-each-ref --format=%(refname) refs/remotes/*/topic",
        "git -C \(clone) symbolic-ref --quiet --short HEAD",
        "sh -c mkdir -p \"$1\" sh \(clone)-worktrees",
        "git -C \(clone) worktree list --porcelain",
        // Where it would start here (main), as origin has it there.
        "git -C \(clone) rev-parse --verify --quiet refs/remotes/origin/main^{commit}",
        "git -C \(clone) update-ref refs/heads/topic abc123 ",
        "git -C \(clone) worktree add -- \(clone)-worktrees/topic topic",
    ])
    // Nothing was made on this Mac.
    #expect(Git.worktrees(at: repo.path)?.count == 1)
}

@Test func laterWorktreesFetchAndContinueWhatOriginHas() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    let host = FakeHost([("refs/remotes/*/topic", 0, "refs/remotes/origin/topic\n"), ("rev-parse", 0, "def456\n")])

    try Git.createWorktree(branch: "topic", in: repo.path, on: host.git)

    #expect(host.commands.contains("git -C \(clone) fetch origin"))
    #expect(!host.commands.contains { $0.hasPrefix("git clone") })
    #expect(host.commands.contains("git -C \(clone) rev-parse --verify refs/remotes/origin/topic^{commit}"))
    #expect(host.commands.contains("git -C \(clone) update-ref refs/heads/topic def456 "))
    #expect(host.commands.last == "git -C \(clone) worktree add -- \(clone)-worktrees/topic topic")
}

@Test func aHostThatCantCloneSaysWhyInGitsWords() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    let host = FakeHost([("test -e", 1, ""), ("git clone", 128, "fatal: could not read Username for 'https://example.invalid': No such device or address")])
    #expect { try Git.createWorktree(branch: "topic", in: repo.path, on: host.git) } throws: { error in
        error.localizedDescription.contains("could not read Username")
    }
    #expect(!host.commands.contains { $0.contains("worktree add") })
}

@Test func aProjectWithoutAnOriginCantHaveWorktreesOnAHost() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    git("-C", repo.path, "remote", "remove", "origin")
    let host = FakeHost()
    #expect(throws: GitError.self) { try Git.createWorktree(branch: "topic", in: repo.path, on: host.git) }
    #expect(host.commands.isEmpty)
}

@Test func aBranchOnlyThisMacHasMustBePushedFirst() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    git("-C", repo.path, "branch", "local-only")
    let host = FakeHost()
    #expect { try Git.createWorktree(branch: "local-only", in: repo.path, on: host.git) } throws: { error in
        error.localizedDescription.contains("local-only")
    }
    #expect(!host.commands.contains { $0.contains("update-ref") || $0.contains("worktree add") })
}

@Test func listingAndRemovingRunInTheHostsClone() throws {
    let listing = "worktree \(clone)\nHEAD abc\nbranch refs/heads/main\n\nworktree \(clone)-worktrees/topic\nHEAD def\nbranch refs/heads/topic\n"
    let host = FakeHost([("worktree list", 0, listing), ("status --porcelain", 0, " M a.txt\n"), ("rev-list", 0, "2\n")])
    try Git.$host.withValue(host.git) {
        #expect(Git.worktrees(at: clone) == [Worktree(path: clone, branch: "main"), Worktree(path: clone + "-worktrees/topic", branch: "topic")])
        let work = Git.pendingWork(at: clone + "-worktrees/topic")
        #expect(work.changedFiles == 1 && work.unpushedCommits == 2)
        try Git.removeWorktree(at: clone + "-worktrees/topic", from: clone, force: true)
    }
    #expect(host.commands == [
        "git -C \(clone) worktree list --porcelain",
        "git -C \(clone)-worktrees/topic status --porcelain",
        "git -C \(clone)-worktrees/topic rev-list --count HEAD --not --remotes",
        "git -C \(clone) worktree remove --force -- \(clone)-worktrees/topic",
    ])
}

@Test func aHostThatCantBeReachedSaysSo() {
    let gone = GitHost(name: "builder", home: "/home/dev") { _, _ in nil }
    Git.$host.withValue(gone) {
        #expect(Git.worktrees(at: clone) == nil)
        #expect { try Git.removeWorktree(at: clone + "-worktrees/topic", from: clone, force: false) } throws: { error in
            error.localizedDescription.contains("builder")
        }
    }
}

// MARK: The dialog's check, with a host picked

@Test func theCheckPutsTheWorktreeBesideTheHostsClone() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    // Nothing of that name on the host yet.
    let host = FakeHost([("test -e", 1, "")])
    let check = WorktreeDraft.inspect("Fix the login", in: repo.path, on: host.git)
    #expect(check.problem == nil)
    #expect(check.branch == "fix-the-login")
    #expect(check.location.path == clone + "-worktrees/fix-the-login")
    // Where it starts is decided here, as for a worktree on this Mac.
    #expect(check.start == .newBranch(from: "main"))
    // Without a host the same name goes beside the repository, as before.
    #expect(WorktreeDraft.inspect("Fix the login", in: repo.path).location == Git.worktreeLocation(for: "fix-the-login", in: repo.path))
}

@Test func theCheckNumbersPastWhatTheHostAlreadyHas() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    // The host's clone has a branch with the first name and a folder with the second.
    let host = FakeHost([("for-each-ref --format=%(refname) refs/heads/", 0, "refs/heads/main\nrefs/heads/fix-login\n"),
                         ("\(clone)-worktrees/fix-login-2", 0, ""), ("test -e", 1, "")])
    let check = WorktreeDraft.inspect("Fix login", in: repo.path, on: host.git)
    #expect(check.problem == nil)
    #expect(check.branch == "fix-login-3")
}

@Test func aBranchOpenOnTheHostIsAProblemThereOnly() throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    git("-C", repo.path, "branch", "topic")
    let listing = "worktree \(clone)\nbranch refs/heads/main\n\nworktree \(clone)-worktrees/topic\nbranch refs/heads/topic\n"
    let host = FakeHost([("worktree list", 0, listing), ("test -e", 1, "")])
    let check = WorktreeDraft.inspect("topic", in: repo.path, on: host.git)
    #expect(check.problem?.contains("topic") == true)
    #expect(check.fullPath == clone + "-worktrees/topic")
    // On this Mac it isn't open anywhere.
    #expect(WorktreeDraft.inspect("topic", in: repo.path).problem == nil)
}

@MainActor @Test func theDraftChecksAndCreatesOnThePickedHost() async throws {
    let repo = try repository()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    let host = FakeHost([("test -e", 1, ""), ("rev-parse", 0, "abc123\n")])
    let draft = WorktreeDraft(repository: repo.path)
    draft.name = "Fix login"
    await draft.validate()
    #expect(draft.check?.location.path.hasPrefix(repo.deletingLastPathComponent().path) == true)

    // Picking a host drops the check made for this Mac.
    draft.host = host.git
    #expect(draft.check == nil)
    await draft.validate()
    #expect(draft.check?.location.path == clone + "-worktrees/fix-login")
    var created: Git.CreatedWorktree?
    draft.onCreated = { created = $0 }
    await draft.submit()
    #expect(created?.path == clone + "-worktrees/fix-login")
    #expect(host.commands.last == "git -C \(clone) worktree add -- \(clone)-worktrees/fix-login fix-login")
    #expect(Git.worktrees(at: repo.path)?.count == 1)
}

// MARK: What is known of each host's clones

@Test func theDatabaseKeepsWhatEachHostsCloneHolds() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("abhosts-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let host = UUID(), other = UUID()
    let listed = [Worktree(path: clone, branch: "main", host: host), Worktree(path: clone + "-worktrees/topic", branch: nil, host: host)]
    do {
        let database = try Database(url: url)
        try database.setHostWorktrees(listed, host: host, project: "/projects/repo")
        try database.setHostWorktrees([Worktree(path: clone, branch: "main", host: other)], host: other, project: "/projects/repo")
    }
    let database = try Database(url: url)
    #expect(try database.hostWorktrees() == [host: ["/projects/repo": listed], other: ["/projects/repo": [Worktree(path: clone, branch: "main", host: other)]]])
    // Listed again with less; an empty list forgets the clone.
    try database.setHostWorktrees([listed[0]], host: host, project: "/projects/repo")
    try database.setHostWorktrees([], host: other, project: "/projects/repo")
    #expect(try database.hostWorktrees() == [host: ["/projects/repo": [listed[0]]]])
}

@Test func worktreesOfTheSamePathOnTwoHostsAreToldApart() {
    let host = UUID()
    #expect(Worktree(path: "/w", branch: "a").id == "/w")
    #expect(Worktree(path: "/w", branch: "a", host: host).id != Worktree(path: "/w", branch: "a").id)
    #expect(Worktree(path: "/w", branch: "a", host: host) != Worktree(path: "/w", branch: "a"))
}

// MARK: A host's store, against a second core

/// A core in this process on a socket of its own, standing in for another host's.
@MainActor
private func core(at path: String, folder: URL) throws -> (CoreServer, Orchestrator) {
    let server = CoreServer(socketPath: path, queue: .main)
    server.lock = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [], searchPath: "/usr/bin:/bin")
    server.service = orchestrator
    try server.start(listening: nil)
    return (server, orchestrator)
}

/// What the end-to-end tests share: a project with a real `origin`, signed in to an account
/// with one host online, whose core is a second core in this process reached over a descriptor
/// (`CoreClient.open(on:)`), as the relay's channel is. The host's home is a temporary folder.
@MainActor
struct Rig {
    let folder: URL
    let repo: URL
    let home: URL
    let host = UUID(uuidString: "0B6F0D6E-5F0A-4A55-9A37-0D5B8F1C2E11")!
    let socket: String
    let server: CoreServer
    let orchestrator: Orchestrator
    let projects: ProjectStore
    let hosts: HostStores
    let project: Project

    init() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-rig-\(UUID().uuidString.prefix(8))")
        let origin = folder.appendingPathComponent("origin.git"), home = folder.appendingPathComponent("home")
        self.home = home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = isolatedGitConfig
        repo = folder.appendingPathComponent("repo")
        try Git.createRepository(at: repo)
        git("init", "--bare", "-b", "main", origin.path)
        git("-C", repo.path, "remote", "add", "origin", origin.path)
        git("-C", repo.path, "push", "-u", "origin", "main")

        socket = NSTemporaryDirectory() + "abhost-\(UUID().uuidString.prefix(8)).sock"
        (server, orchestrator) = try core(at: socket, folder: folder.appendingPathComponent("host-data"))

        let stub = StubServer.make { call in call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}") }
        let file = folder.appendingPathComponent("account.json")
        try Data(#"{"token":"secret","account":{"login":"octo"}}"#.utf8).write(to: file)
        let account = AccountStore(server: stub.server, session: stub.session, file: file)
        let local = AgentStore(database: folder.appendingPathComponent("cards.sqlite"), connect: { .failure(.noCore) })
        let socket = socket
        hosts = HostStores(local: local, account: account) { _ in
            { (try? UnixSocket.connect(to: socket)).map { CoreClient.open(on: $0) } ?? .failure(.noCore) }
        }
        // Not the home of whoever runs the tests.
        hosts.homes[host] = home.path
        projects = ProjectStore(databaseURL: folder.appendingPathComponent("board.sqlite"))
        projects.hosts = hosts
        let hosts = hosts, projects = projects
        hosts.prepare = { $0.projectTools = ProjectTools(projects: projects, agents: $0, hosts: hosts) }
        hosts.prepare?(local)
        // The core standing in for the host's reports no stats: host_list doesn't wait long for them.
        ProjectTools.statsPatience = 0.2
        project = try #require(projects.addProject(at: repo))
        try await waitUntil { account.hosts.count == 2 }
    }

    func cleanUp() {
        server.stop()
        unlink(socket)
        unlink(socket + ".lock")
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor @Test func aHostsStoreMirrorsItsCoreAndNeverShutsItDown() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let store = rig.hosts.store(for: rig.host)
    #expect(store.host?.name == "builder")
    #expect(rig.hosts[rig.host] === store && rig.hosts[nil] === rig.hosts.local)
    try await waitUntil { store.isLoaded }
    #expect(rig.hosts.connected.contains { $0 === store })

    // A card added through the host's store is the host's core's, in the organization shown.
    let worktree = rig.home.appendingPathComponent("work").path
    let record = store.addRunner(command: "true", name: "probe", directory: rig.home.path, to: worktree, at: .zero)
    try await waitUntil { rig.orchestrator.cards.contains { $0.id == record.id } }
    #expect(rig.hosts.local.record(record.id) == nil)
    #expect(rig.hosts.store(of: record.id) === store)

    // A program run there, as git is.
    let client = try #require(store.core)
    let ran = try #require(await client.run("/bin/sh", ["-c", "printf %s hello"]))
    #expect(ran.status == 0 && String(decoding: ran.output, as: UTF8.self) == "hello")

    // Quitting the board hangs up; the host's core and its cards stay.
    store.quit()
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.orchestrator.cards.contains { $0.id == record.id })
    let socket = rig.socket
    let again = await Task.detached { CoreClient.connect(socketPath: socket) }.value
    #expect(again != nil)
    again?.disconnect()
}

@MainActor @Test func aHostThatDoesntAnswerSaysSoAndIsNeverReplacedByACoreHere() async throws {
    let account = AccountStore(server: URL(string: "https://nowhere.test")!, session: StubServer.make { _ in (404, "{}") }.session, file: accountFile())
    let local = AgentStore(database: FileManager.default.temporaryDirectory.appendingPathComponent("abcards-\(UUID().uuidString).sqlite"),
                           connect: { .failure(.noCore) })
    let hosts = HostStores(local: local, account: account) { _ in { .failure(.noCore) } }
    let store = hosts.store(for: UUID())
    // The notice and the cards' state change together (`show`); it comes after the link's patience, later on a busy machine.
    try await waitUntil(60) { store.notice != nil }
    try #require(store.notice != nil, "the store says its host can't be reached")
    #expect(!store.isLoaded, "no core in this process stood in for the host's")
    #expect(!hosts.connected.contains { $0 === store })
    // A card shown meanwhile says the same.
    let record = AgentRecord(id: UUID(), worktree: "/w", providerID: "claude", name: "Agent", frame: .zero, organization: store.organizationID)
    #expect(store.session(for: record, cols: 80, rows: 24).state == .failed(store.notice ?? ""))
    // Signing out drops the hosts' stores.
    await account.signOut()
}

@MainActor @Test func worktreesAreCreatedListedAndRemovedOnAHostThroughItsCore() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let clone = rig.home.appendingPathComponent("agentboard/projects/repo").path
    let caller = AgentRecord(id: UUID(), worktree: rig.repo.path, providerID: "claude", name: "Agent", frame: .zero,
                             organization: rig.projects.organizationID)
    rig.hosts.local.insert(caller)
    let tools = ProjectTools(projects: rig.projects, agents: rig.hosts.local, hosts: rig.hosts)

    // The tool, by host name: clones from origin on the host and adds the worktree there.
    let result = await tools.call("worktree_create", arguments: ["branch": "topic", "host": "builder"], caller: caller.id)
    #expect(!result.isError, "\(result)")
    #expect(FileManager.default.fileExists(atPath: clone + "/.git"))
    let path = URL(fileURLWithPath: clone + "-worktrees/topic").resolvingSymlinksInPath().path
    #expect(FileManager.default.fileExists(atPath: path + "/.git"))
    #expect(Git.worktrees(at: rig.repo.path)?.count == 1, "nothing was added on this Mac")

    // It lists under the project, after this Mac's, without the host's clone itself; and the
    // database remembers it for the next launch.
    let listed = try #require(rig.projects.worktrees[rig.project.id])
    #expect(listed.count == 2)
    let remote = try #require(listed.last)
    #expect(remote.host == rig.host && remote.branch == "topic")
    #expect(URL(fileURLWithPath: remote.path).resolvingSymlinksInPath().path == path)
    #expect(!rig.projects.isMain(remote, in: rig.project))
    #expect(try Database(url: rig.folder.appendingPathComponent("board.sqlite")).hostWorktrees()[rig.host]?[rig.repo.path]?.count == 2)

    // A second one fetches first: a branch pushed since is continued, not started again.
    git("-C", rig.repo.path, "branch", "pushed")
    git("-C", rig.repo.path, "push", "origin", "pushed")
    let second = await tools.call("worktree_create", arguments: ["branch": "pushed", "host": rig.host.uuidString.lowercased()], caller: caller.id)
    #expect(!second.isError, "\(second)")
    #expect(rig.projects.worktrees[rig.project.id]?.count == 3)

    // An agent on the host finds its project from its worktree, and its own host is the default.
    let there = rig.hosts.store(for: rig.host)
    let agent = AgentRecord(id: UUID(), worktree: remote.path, providerID: "claude", name: "Agent", frame: .zero,
                            organization: rig.projects.organizationID)
    there.insert(agent)
    let third = await ProjectTools(projects: rig.projects, agents: there, hosts: rig.hosts)
        .call("worktree_create", arguments: ["branch": "from-the-host"], caller: agent.id)
    #expect(!third.isError, "\(third)")
    #expect(rig.projects.worktrees[rig.project.id]?.filter { $0.host == rig.host }.count == 3)
    // This Mac's core stands in for the host's and reports no stats: host_list then shows none.
    let hostList = await there.projectTools?.call("host_list", arguments: [:], caller: agent.id)
    #expect(hostList?.isError == false)

    // The title goes by the host's path.
    #expect(rig.projects.setAgentTitle("On the host", path: remote.path) == .applied)

    // Removing runs on the host too.
    rig.projects.removeWorktree(remote, from: rig.project, force: false)
    try await waitUntil { rig.projects.worktrees[rig.project.id]?.contains(remote) == false }
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(rig.projects.errorMessage == nil)
}

// MARK: The tools

@MainActor @Test func theHostToolsSayWhoIsThereAndRefuseWhatIsnt() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let caller = AgentRecord(id: UUID(), worktree: rig.repo.path, providerID: "claude", name: "Agent", frame: .zero,
                             organization: rig.projects.organizationID)
    rig.hosts.local.insert(caller)
    let tools = ProjectTools(projects: rig.projects, agents: rig.hosts.local, hosts: rig.hosts)
    func text(_ result: ToolResult) -> String {
        result.content.map { if case .text(let text) = $0 { text } else { "" } }.joined()
    }

    let list = text(await tools.call("host_list", arguments: [:], caller: caller.id))
    #expect(list.contains("This Mac") && list.contains("the host you run on"))
    #expect(list.contains("builder") && list.contains("0b6f0d6e-5f0a-4a55-9a37-0d5b8f1c2e11") && list.contains("online"))
    // An online host this board wasn't connected to is connected to for its stats, and the list says when it has none.
    #expect(rig.hosts[rig.host] != nil && list.contains("stats: not connected"))
    #expect(list.contains("laptop") && list.contains("offline"))

    #expect(await tools.call("worktree_create", arguments: [:], caller: caller.id).isError)
    #expect(await tools.call("worktree_create", arguments: ["branch": "x"], caller: UUID()).isError)
    #expect(text(await tools.call("worktree_create", arguments: ["branch": "x", "host": "nobody"], caller: caller.id)).contains("nobody"))
    #expect(text(await tools.call("worktree_create", arguments: ["branch": "x", "host": "laptop"], caller: caller.id)).contains("offline"))
    #expect(await tools.call("worktree_create", arguments: ["branch": "x", "project": "missing"], caller: caller.id).isError)
    #expect(Git.worktrees(at: rig.repo.path)?.count == 1)

    // Without a host it is made on the caller's own: here, this Mac.
    let local = await tools.call("worktree_create", arguments: ["branch": "here", "project": "repo"], caller: caller.id)
    #expect(!local.isError, "\(local)")
    #expect(rig.projects.worktrees[rig.project.id]?.map(\.branch) == ["main", "here"])
    #expect(rig.projects.worktrees[rig.project.id]?.allSatisfy { $0.host == nil } == true)

    // Signed out, there is only this Mac, and the tool says so.
    await rig.hosts.account.signOut()
    let alone = text(await tools.call("host_list", arguments: [:], caller: caller.id))
    #expect(alone.contains("This Mac") && alone.contains("isn't signed in") && !alone.contains("builder"))
    #expect(await tools.call("worktree_create", arguments: ["branch": "y", "host": "builder"], caller: caller.id).isError)
}
