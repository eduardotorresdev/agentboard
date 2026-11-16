@testable import AgentRuntime
import Connections
import Darwin
import Foundation
@testable import Orchestration
import Testing
@testable import AgentBoard

// What a worktree on another host can do from this Mac: its files, pictures, pages, runners'
// folders, pull, and this Mac's skills and MCP servers. The host is the second core of `Rig`,
// or this machine with another home where a program would write to `$HOME`.

private func waitUntil(_ seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

@discardableResult
private func git(_ arguments: String...) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.environment = Git.environment
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func temporaryFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.resolvingSymlinksInPath()
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A host that is this machine with `home` as its home: what the board would run there runs
/// here, so nothing touches the home of whoever runs the tests.
private func machine(home: URL) -> HostFiles {
    HostFiles { executable, arguments, input in
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let output = Pipe(), errors = Pipe(), typed = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = typed
            guard (try? process.run()) != nil else { return nil }
            Thread.detachNewThread {
                if let input { try? typed.fileHandleForWriting.write(contentsOf: input) }
                try? typed.fileHandleForWriting.close()
            }
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            let failed = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CoreClient.Ran(status: process.terminationStatus, output: printed, error: failed)
        }.value
    }
}

// MARK: Files

@MainActor @Test func aHostsFilesAreListedAndReadThroughItsCore() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let root = rig.home.appendingPathComponent("work")
    try write("let a = 1\nlet b = 2\n", to: root.appendingPathComponent("Sources/main.swift"))
    try write("secret", to: root.appendingPathComponent(".env"))
    try write("x", to: root.appendingPathComponent("a file.txt"))
    try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("blob.bin"))
    try Data(repeating: 0x61, count: 5000).write(to: root.appendingPathComponent("big.txt"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("Sources"))
    git("init", "-b", "main", root.path)

    let store = rig.hosts.store(for: rig.host)
    let files = try #require(store.files)
    #expect(rig.hosts.local.files == nil, "this Mac's disk is read as before")

    // One program per folder: names, hidden ones too, and which are folders (links followed).
    let listed = try #require(await files.list(root.path)).sorted { $0.name < $1.name }
    #expect(listed.map(\.name) == [".env", ".git", "Sources", "a file.txt", "big.txt", "blob.bin", "linked"])
    #expect(listed.filter(\.isFolder).map(\.name) == [".git", "Sources", "linked"])
    #expect(await files.list(root.appendingPathComponent("missing").path) == nil)

    // Bytes as they are, and no more than asked for plus the one that says there is more.
    #expect(await files.read(root.appendingPathComponent("blob.bin").path, limit: 100) == Data([0x89, 0x50, 0x00, 0x01]))
    #expect(await files.read(root.appendingPathComponent("big.txt").path, limit: 100)?.count == 101)
    #expect(await files.read(root.appendingPathComponent("missing").path, limit: 100) == nil)
    #expect(await files.isFolder(root.appendingPathComponent("Sources").path))
    #expect(await !files.isFolder(root.appendingPathComponent("a file.txt").path))

    // The card's model over the same seam: folders first, a file's lines, git's status, search.
    let model = FileBrowserModel(root: root.path, files: files)
    try await waitUntil { !model.rows.isEmpty && !model.status.isEmpty }
    #expect(model.rows.map(\.entry.name) == ["linked", "Sources", ".env", "a file.txt", "big.txt", "blob.bin"])
    #expect(model.status["Sources/main.swift"] == "U" && model.status["Sources"] == "U")
    model.toggle("Sources")
    try await waitUntil { model.rows.contains { $0.entry.path == "Sources/main.swift" } }
    #expect(model.rows.first { $0.entry.path == "Sources/main.swift" }?.depth == 1)
    model.open("Sources/main.swift")
    try await waitUntil { model.content != nil }
    #expect(model.content == .lines(["let a = 1", "let b = 2"]))
    model.open("blob.bin")
    try await waitUntil { model.content != nil }
    #expect(model.content == .binary)
    model.open("gone.txt")
    try await waitUntil { model.content != nil }
    #expect(model.content == .unreadable)
    model.query = "MAIN"
    try await waitUntil { !model.matches.isEmpty }
    #expect(model.matches.map(\.path) == ["Sources/main.swift"])

    // A file made on the host since shows after the card's refresh.
    try write("new", to: root.appendingPathComponent("later.txt"))
    model.reload()
    try await waitUntil { model.rows.contains { $0.entry.name == "later.txt" } }
    #expect(model.rows.contains { $0.entry.name == "later.txt" })
}

@MainActor @Test func aFileLargerThanTheCardShowsIsNotBroughtWhole() async throws {
    let home = try temporaryFolder("large")
    defer { try? FileManager.default.removeItem(at: home) }
    try Data(repeating: 0x61, count: FileBrowserModel.maxFileSize + 10).write(to: home.appendingPathComponent("huge.txt"))
    let model = FileBrowserModel(root: home.path, files: machine(home: home))
    model.open("huge.txt")
    try await waitUntil { model.content != nil }
    #expect(model.content == .tooLarge)
}

@MainActor @Test func cardsOfAWorktreeOnAHostGoToThatHostsStoreOnly() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let url = rig.folder.appendingPathComponent("cards.sqlite")
    let browsers = BrowserStore(database: try Database(url: url)), fileTrees = FileTreeStore(database: try Database(url: url))
    let there = rig.hosts.store(for: rig.host), here = rig.hosts.local
    for store in [here, there] {
        browsers.attach(to: store)
        fileTrees.attach(to: store)
    }
    // The same path on both machines: two worktrees, told apart by their host.
    let onHost = browsers.add(.desktop, to: "/w", on: rig.host, at: .zero), onMac = browsers.add(.desktop, to: "/w", at: .zero)
    let tree = fileTrees.add(to: "/w", on: rig.host, at: .zero)
    #expect(browsers.browsers(in: "/w", on: rig.host).map(\.id) == [onHost.id])
    #expect(browsers.browsers(in: "/w").map(\.id) == [onMac.id])
    #expect(fileTrees.trees(in: "/w").isEmpty && fileTrees.trees(in: "/w", on: rig.host).map(\.id) == [tree.id])
    #expect(Set(there.elements().map(\.id)) == [onHost.id, tree.id])
    #expect(here.elements().map(\.id) == [onMac.id])
    // The browser tools of the host's store are its own, so an agent there drives its cards.
    #expect(there.browserTools != nil && there.browserTools !== here.browserTools)

    // Kept with their host across launches.
    let again = try Database(url: url)
    #expect(try again.browsers().first { $0.id == onHost.id }?.host == rig.host)
    #expect(try again.browsers().first { $0.id == onMac.id }?.host == nil)
    #expect(try again.fileTrees().first?.host == rig.host)

    // A note on the host's file reaches the agent connected to the card there.
    let agent = AgentRecord(id: UUID(), worktree: "/w", providerID: "claude", name: "Agent", frame: .zero, organization: there.organizationID)
    there.insert(agent)
    there.connect(agent.id, tree.id)
    try await waitUntil { !fileTrees.connectedAgents(of: tree.id).isEmpty }
    #expect(fileTrees.connectedAgents(of: tree.id).map(\.id) == [agent.id])
}

// MARK: Pictures

private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

@MainActor @Test func aPictureGoesToTheHostBeforeItsCardAndOneMadeThereComesBack() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let hostData = rig.folder.appendingPathComponent("host-data")
    let store = rig.hosts.store(for: rig.host)
    store.hostDataFolder = hostData.path
    store.dataFolder = rig.folder.appendingPathComponent("copies")
    try await waitUntil { store.isLoaded }

    // Added here: stored in this Mac's copy, sent to the host's folder, then the card is made.
    let record = try await store.addImage(.data(png), named: "Shot", to: "/w", at: .zero)
    #expect(try Data(contentsOf: ImageFiles.url(of: record.file, in: hostData)) == png)
    #expect(FileManager.default.fileExists(atPath: ImageFiles.url(of: record.file, in: store.dataFolder).path))
    try await waitUntil { rig.orchestrator.images.contains { $0.id == record.id } }
    #expect(rig.orchestrator.images.contains { $0.id == record.id }, "the host's core found the file and kept the card")

    // Made on the host (an agent's screenshot): fetched when its card first shows, once.
    let made = try ImageFiles.store(png, in: hostData)
    let theirs = ImageRecord(id: UUID(), worktree: "/w", name: "Chart", frame: .zero, file: made.file, pixelSize: made.pixelSize)
    store.images.append(theirs)
    var arrived: [String] = []
    store.onMediaChange = { arrived.append($0) }
    store.fetchMedia(theirs)
    #expect(store.mediaNotes[made.file]?.contains("builder") == true, "the card says where its picture is coming from")
    store.fetchMedia(theirs)
    try await waitUntil { !arrived.isEmpty }
    #expect(arrived == [made.file])
    #expect(store.mediaNotes[made.file] == nil)
    #expect(try Data(contentsOf: ImageFiles.url(of: made.file, in: store.dataFolder)) == png)

    // One over the limit isn't brought, and its card says so.
    let large = try ImageFiles.store(png, in: hostData)
    store.fetchMedia(ImageRecord(id: UUID(), worktree: "/w", name: "Big", frame: .zero, file: large.file, pixelSize: large.pixelSize), limit: 10)
    try await waitUntil { arrived.count == 2 }
    #expect(store.mediaNotes[large.file] == AgentBoard.L("Larger than \(0) MB: too large to bring from \("builder")."))
    #expect(!FileManager.default.fileExists(atPath: ImageFiles.url(of: large.file, in: store.dataFolder).path))

    // A name that leaves the folder is never asked for; nor anything on this Mac's own store.
    for file in ["../account.json", "a/b.png", "..", ""] {
        store.fetchMedia(ImageRecord(id: UUID(), worktree: "/w", name: "x", frame: .zero, file: file, pixelSize: .zero))
        #expect(store.mediaNotes[file] == nil)
    }
    rig.hosts.local.fetchMedia(theirs)
    #expect(rig.hosts.local.mediaNotes.isEmpty)

    // Removing the card drops this Mac's copy.
    store.removeImage(theirs.id)
    #expect(!FileManager.default.fileExists(atPath: ImageFiles.url(of: made.file, in: store.dataFolder).path))
}

@MainActor @Test func aPictureThatCantReachTheHostAddsNoCard() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let store = rig.hosts.store(for: rig.host)
    store.dataFolder = rig.folder.appendingPathComponent("copies")
    // A folder the host can't write to.
    store.hostDataFolder = "/dev/null/nowhere"
    try await waitUntil { store.isLoaded }
    await #expect(throws: HostMediaFailure.self) { try await store.addImage(.data(png), named: "Shot", to: "/w", at: .zero) }
    #expect(store.images.isEmpty)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: ImageFiles.folder(in: store.dataFolder).path)) ?? []).isEmpty)
}

// MARK: Runner dialog

@MainActor @Test func theRunnerDialogChecksTheFolderAndReadsItsScriptsOnTheHost() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let root = rig.home.appendingPathComponent("mono")
    try write(#"{"scripts":{"dev":"vite","build":"vite build"}}"#, to: root.appendingPathComponent("apps/web/package.json"))
    try write("", to: root.appendingPathComponent("pnpm-lock.yaml"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try write(#"{"scripts":{"start":"node ."}}"#, to: rig.home.appendingPathComponent("plain/package.json"))
    try FileManager.default.createDirectory(at: rig.home.appendingPathComponent("plain/.git"), withIntermediateDirectories: true)
    let files = try #require(rig.hosts.store(for: rig.host).files)

    #expect(await files.isFolder(root.appendingPathComponent("apps/web").path))
    #expect(await !files.isFolder(root.appendingPathComponent("apps/api").path))
    #expect(await !files.isFolder(root.appendingPathComponent("apps/web/package.json").path))
    // A path with a quote and a space is an argument, never part of a script.
    #expect(await !files.isFolder(root.path + "/a\" && touch \"" + rig.home.path + "/made"))
    #expect(!FileManager.default.fileExists(atPath: rig.home.path + "/made"))

    // The same scripts and package manager the dialog finds for a folder on this Mac.
    let remote = await PackageScript.read(in: root.appendingPathComponent("apps/web").path, files: files)
    #expect(remote == PackageScript.read(in: root.appendingPathComponent("apps/web").path))
    #expect(remote.map(\.command) == ["pnpm build", "pnpm dev"])
    #expect(await PackageScript.read(in: rig.home.appendingPathComponent("plain").path, files: files).map(\.command) == ["npm run start"])
    #expect(await PackageScript.read(in: root.path, files: files).isEmpty)
}

// MARK: Pull and the tools

@MainActor @Test func pullRunsWhereTheWorktreeIsAndSaysWhyInGitsWords() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let caller = AgentRecord(id: UUID(), worktree: rig.repo.path, providerID: "claude", name: "Agent", frame: .zero,
                             organization: rig.projects.organizationID)
    rig.hosts.local.insert(caller)
    let tools = ProjectTools(projects: rig.projects, agents: rig.hosts.local, hosts: rig.hosts)
    git("-C", rig.repo.path, "branch", "topic")
    git("-C", rig.repo.path, "push", "-u", "origin", "topic")
    #expect(await !tools.call("worktree_create", arguments: ["branch": "topic", "host": "builder"], caller: caller.id).isError)
    let remote = try #require(rig.projects.worktrees[rig.project.id]?.last { $0.host == rig.host })

    // The tool lists it with its host.
    let listed = await tools.call("project_list", arguments: [:], caller: caller.id)
    #expect("\(listed)".contains("\(remote.path) (topic, on builder)"))

    // origin moves on; the host's worktree follows on Pull.
    git("-C", rig.repo.path, "checkout", "topic")
    try write("more", to: rig.repo.appendingPathComponent("more.txt"))
    git("-C", rig.repo.path, "add", "more.txt")
    git("-C", rig.repo.path, "commit", "-m", "More")
    git("-C", rig.repo.path, "push", "origin", "topic")
    await rig.projects.pull(remote).value
    #expect(rig.projects.errorMessage == nil)
    #expect(FileManager.default.fileExists(atPath: remote.path + "/more.txt"))

    // This Mac's worktree pulls here, as before there were hosts.
    let other = rig.folder.appendingPathComponent("other")
    git("clone", "-b", "topic", rig.folder.appendingPathComponent("origin.git").path, other.path)
    try write("again", to: other.appendingPathComponent("again.txt"))
    git("-C", other.path, "add", "again.txt")
    git("-C", other.path, "commit", "-m", "Again")
    git("-C", other.path, "push", "origin", "topic")
    await rig.projects.pull(Worktree(path: rig.repo.path, branch: "topic")).value
    #expect(rig.projects.errorMessage == nil)
    #expect(FileManager.default.fileExists(atPath: rig.repo.path + "/again.txt"))

    // History that parted from origin's can't be pulled forward: git says so.
    try write("theirs", to: URL(fileURLWithPath: remote.path).appendingPathComponent("theirs.txt"))
    git("-C", remote.path, "add", "theirs.txt")
    git("-C", remote.path, "commit", "-m", "Theirs")
    await rig.projects.pull(remote).value
    #expect(rig.projects.errorMessage?.contains("fast-forward") == true, "\(rig.projects.errorMessage ?? "no error")")
}

@MainActor @Test func anAgentOnAHostTitlesItsWorktreeWhateverOrganizationShows() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let home = rig.projects.organizationID
    let caller = AgentRecord(id: UUID(), worktree: rig.repo.path, providerID: "claude", name: "Agent", frame: .zero, organization: home)
    rig.hosts.local.insert(caller)
    #expect(await !ProjectTools(projects: rig.projects, agents: rig.hosts.local, hosts: rig.hosts)
        .call("worktree_create", arguments: ["branch": "topic", "host": "builder"], caller: caller.id).isError)
    let remote = try #require(rig.projects.worktrees[rig.project.id]?.last { $0.host == rig.host })
    let there = rig.hosts.store(for: rig.host)
    let agent = AgentRecord(id: UUID(), worktree: remote.path, providerID: "claude", name: "Agent", frame: .zero, organization: home)
    there.insert(agent)

    // The user looks at another organization meanwhile.
    rig.projects.selectOrganization(rig.projects.addOrganization(named: "Other").id)
    #expect(rig.projects.organizationID != home)
    let result = await ProjectTools(projects: rig.projects, agents: there, hosts: rig.hosts)
        .call("worktree_set_title", arguments: ["title": "Faster login"], caller: agent.id)
    #expect(!result.isError, "\(result)")
    #expect(rig.projects.agentTitles[remote.path] == "Faster login")
    // A folder that is no worktree of the host's is still refused.
    #expect(rig.projects.setAgentTitle("Nope", path: "/somewhere/else", in: home, on: rig.host) == .unknownWorktree)
}

// MARK: Skills and MCP servers

/// A home with everything an agent's configuration can hold, some of it never to leave.
private func configuredHome() throws -> URL {
    let home = try temporaryFolder("sync-home")
    let claude = home.appendingPathComponent(".claude")
    for (path, text) in [
        ("skills/review/SKILL.md", "review"), ("skills/review/.DS_Store", "junk"), ("skills/review/.git/HEAD", "ref"),
        ("skills/review/.env", "KEY=1"), ("commands/ship.md", "ship"), ("agents/tester.md", "tester"),
        ("CLAUDE.md", "@RTK.md"), ("RTK.md", "rtk"), ("settings.json", "{}"), ("plugins/tiny/plugin.json", "{}"),
        // Never copied.
        ("settings.local.json", "{}"), (".credentials.json", "{\"token\":1}"), ("projects/p/transcript.jsonl", "{}"),
        ("todos/1.json", "[]"), ("history.jsonl", "{}"), ("statsig/cache", "x"), ("shell-snapshots/s.sh", "x"),
    ] {
        try write(text, to: claude.appendingPathComponent(path))
    }
    // A skill linked in from elsewhere goes as its files.
    try write("linked", to: home.appendingPathComponent("elsewhere/SKILL.md"))
    try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("skills/linked"), withDestinationURL: home.appendingPathComponent("elsewhere"))
    try write("""
        {"oauthAccount": {"email": "me@example.test"}, "projects": {"/x": {}}, "mcpServers": {
          "search": {"type": "http", "url": "https://mcp.example.test", "headers": {"Authorization": "Bearer abc"}},
          "files": {"command": "npx", "args": ["-y", "files-mcp"], "env": {"TOKEN": "t"}},
          "brewed": {"command": "/opt/homebrew/bin/uvx", "args": ["tool"]},
          "mine": {"command": "mine-mcp"},
          "local": {"command": "/Users/me/bin/local-mcp"}}}
        """, to: home.appendingPathComponent(".claude.json"))
    return home
}

@Test func theArchiveHoldsWhatAgentsReadAndNothingElse() throws {
    let home = try configuredHome(), out = try temporaryFolder("sync-out")
    defer { [home, out].forEach { try? FileManager.default.removeItem(at: $0) } }
    func unpacked() throws -> Set<String> {
        let archive = out.appendingPathComponent("a.tgz"), folder = out.appendingPathComponent(UUID().uuidString)
        try #require(try HostSync.archive(of: home)).write(to: archive)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", folder.path]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        var files: Set<String> = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        for case let url as URL in walker! where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.insert(String(url.resolvingSymlinksInPath().path.dropFirst(folder.resolvingSymlinksInPath().path.count + 1)))
        }
        return files
    }
    let sent = [".claude/skills/review/SKILL.md", ".claude/skills/linked/SKILL.md", ".claude/commands/ship.md", ".claude/agents/tester.md",
                ".claude/CLAUDE.md", ".claude/RTK.md"]
    #expect(try unpacked() == Set(sent + [".claude/plugins/tiny/plugin.json"]))

    // Plugins past the limit stay; the rest still goes.
    try Data(count: HostSync.pluginsLimit + 1).write(to: home.appendingPathComponent(".claude/plugins/tiny/big.bin"))
    #expect(try unpacked() == Set(sent))

    // A home without any of it sends nothing.
    let empty = try temporaryFolder("sync-empty")
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(try HostSync.archive(of: empty) == nil)
}

@Test func mcpServersThatRunAProgramOfThisMacStayHere() throws {
    let home = try configuredHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let (copied, skipped, _) = HostSync.servers(in: try Data(contentsOf: home.appendingPathComponent(".claude.json")), searchPath: "/usr/bin:/bin")
    #expect(skipped == ["local": AgentBoard.L("a program only this Mac has")])
    #expect(Set(copied.keys) == ["search", "files", "brewed", "mine"])
    // Keys and headers go as they are; a known program goes by its name.
    #expect((copied["search"] as? [String: Any])?["headers"] as? [String: String] == ["Authorization": "Bearer abc"])
    #expect((copied["files"] as? [String: Any])?["env"] as? [String: String] == ["TOKEN": "t"])
    #expect((copied["brewed"] as? [String: Any])?["command"] as? String == "uvx")
    #expect(HostSync.servers(in: Data("not json".utf8)).copied.isEmpty)

    // A tool uv installed runs anywhere through uvx; a Mac binary stays, and says it is one.
    let tool = home.appendingPathComponent("bin/papers-mcp"), binary = home.appendingPathComponent("bin/mac-app-cli")
    try write("#!\(home.path)/.local/share/uv/tools/paper-search/bin/python\nimport sys\n", to: tool)
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]).write(to: binary)
    let config = try JSONSerialization.data(withJSONObject: ["mcpServers": [
        "papers": ["command": tool.path, "args": ["--fast"], "env": ["EMAIL": "me@example.test"]],
        "app": ["command": binary.path, "args": ["mcp"]],
    ]])
    let sorted = HostSync.servers(in: config)
    #expect(sorted.skipped == ["app": AgentBoard.L("a program built for the Mac")])
    let papers = try #require(sorted.copied["papers"] as? [String: Any])
    #expect(papers["command"] as? String == "uvx" && papers["args"] as? [String] == ["--from", "paper-search", "papers-mcp", "--fast"])
    #expect(papers["env"] as? [String: String] == ["EMAIL": "me@example.test"])
    let reason = AgentBoard.L("a program built for the Mac")
    #expect(HostSync.Outcome(skipped: ["b": reason, "a": reason, "c": "else"]).note(on: "builder").contains("a, b (\(reason)); c (else)"))
    // Held to the versions the tool has here, when the host has somewhere to keep them.
    let packages = home.appendingPathComponent(".local/share/uv/tools/paper-search/lib/python3.12/site-packages")
    for record in ["paper_search-0.1.4.dist-info", "mcp-1.9.2.dist-info", "not-a-record"] {
        try FileManager.default.createDirectory(at: packages.appendingPathComponent(record), withIntermediateDirectories: true)
    }
    let pinned = HostSync.servers(in: config, pinsFolder: "/data/synced-pins")
    #expect((pinned.copied["papers"] as? [String: Any])?["args"] as? [String]
        == ["--constraints", "/data/synced-pins/paper-search.txt", "--from", "paper-search==0.1.4", "papers-mcp", "--fast"])
    #expect(pinned.pins == ["paper-search": "mcp==1.9.2\npaper_search==0.1.4\n"])
    #expect(HostSync.servers(in: config).pins.isEmpty)
    #expect(HostSync.Outcome(unresolved: ["papers": "no wheel"]).note(on: "builder").contains("no wheel"))

    let note = HostSync.Outcome(skipped: sorted.skipped, kept: [], missing: ["papers": "uvx"]).note(on: "builder")
    #expect(note.contains("app (\(AgentBoard.L("a program built for the Mac")))") && note.contains(AgentBoard.L("\("papers"): \("uvx") isn't installed on \("builder")")))

    // A command that is an npm package installed for everyone here goes as npx fetches it.
    let prefix = home.appendingPathComponent("npm")
    try write("#!/usr/bin/env node\n", to: prefix.appendingPathComponent("lib/node_modules/@scope/gitlab-mcp/build/index.js"))
    try write("#!/usr/bin/env node\n", to: prefix.appendingPathComponent("lib/node_modules/plain-mcp/cli.js"))
    try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/gitlab-mcp").path, withDestinationPath: "../lib/node_modules/@scope/gitlab-mcp/build/index.js")
    try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/plain").path, withDestinationPath: "../lib/node_modules/plain-mcp/cli.js")
    let named = try JSONSerialization.data(withJSONObject: ["mcpServers": [
        "gitlab": ["command": "gitlab-mcp", "args": ["--read-only"]], "plain": ["command": "plain"], "other": ["command": "somewhere-else"], "node": ["command": "npx", "args": ["x"]],
    ]])
    let fetched = HostSync.servers(in: named, searchPath: "/nonexistent:" + prefix.appendingPathComponent("bin").path).copied
    #expect((fetched["gitlab"] as? [String: Any])?["command"] as? String == "npx")
    #expect((fetched["gitlab"] as? [String: Any])?["args"] as? [String] == ["-y", "@scope/gitlab-mcp", "--read-only"])
    #expect((fetched["plain"] as? [String: Any])?["args"] as? [String] == ["-y", "plain-mcp"])
    #expect((fetched["other"] as? [String: Any])?["command"] as? String == "somewhere-else")
    #expect((fetched["node"] as? [String: Any])?["args"] as? [String] == ["x"])
}

@Test func syncingCopiesSkillsAndMergesMcpServersWithoutTouchingTheHostsOwn() async throws {
    let home = try configuredHome(), host = try temporaryFolder("sync-host")
    defer { [home, host].forEach { try? FileManager.default.removeItem(at: $0) } }
    let files = machine(home: host), data = host.appendingPathComponent("data").path
    let config = host.appendingPathComponent(".claude.json")
    func servers() throws -> [String: [String: Any]] {
        let whole = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        return whole["mcpServers"] as? [String: [String: Any]] ?? [:]
    }
    // The host has settings of its own, a server of its own under a name this Mac also uses,
    // and a skill of its own.
    try write(#"{"numStartups": 7, "mcpServers": {"mine": {"command": "the-hosts-own"}, "theirs": {"command": "x"}}}"#, to: config)
    try write("own", to: host.appendingPathComponent(".claude/skills/own/SKILL.md"))

    let first = try await HostSync.run(from: home, to: files, dataFolder: data)
    #expect(first.skipped.keys.sorted() == ["local"] && first.kept == ["mine"])
    // The stand-in host has none of the programs the servers run, and the result says which.
    #expect(first.missing == ["files": "npx", "brewed": "uvx"])
    // Only what the host can run is said to be copied, and never that it starts.
    #expect(first.copied == ["search"] && first.note(on: "builder").contains(AgentBoard.L("Servers copied: \("search").")))
    #expect(first.note(on: "builder").contains("local") && first.note(on: "builder").contains("mine"))
    for path in ["skills/review/SKILL.md", "skills/linked/SKILL.md", "skills/own/SKILL.md", "CLAUDE.md", "RTK.md"] {
        #expect(FileManager.default.fileExists(atPath: host.appendingPathComponent(".claude/" + path).path), "\(path)")
    }
    #expect(!FileManager.default.fileExists(atPath: host.appendingPathComponent(".claude/.credentials.json").path))
    // Its hooks run programs of this Mac: the host keeps settings of its own.
    #expect(!FileManager.default.fileExists(atPath: host.appendingPathComponent(".claude/settings.json").path))
    var now = try servers()
    #expect(Set(now.keys) == ["mine", "theirs", "search", "files", "brewed"])
    #expect(now["mine"]?["command"] as? String == "the-hosts-own")
    #expect((now["files"]?["env"] as? [String: String]) == ["TOKEN": "t"])
    let whole = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    #expect(whole["numStartups"] as? Int == 7 && whole["oauthAccount"] == nil && whole["projects"] == nil)
    #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: data + "/synced-mcp.json"))) == ["brewed", "files", "search"])
    // Only its owner reads the file that now holds keys.
    #expect((try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int) == 0o600)

    #expect(try String(contentsOfFile: data + "/synced-files.txt", encoding: .utf8).contains(".claude/skills/review/SKILL.md"))
    // Next time: one changed here is changed there, one removed here is removed there, and the
    // host's own two are still its own. So with skills: one deleted here goes, the host's own stays.
    try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/skills/review"))
    try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/commands/ship.md"))
    try write(#"{"mcpServers": {"files": {"command": "npx", "args": ["-y", "files-mcp@2"]}, "mine": {"command": "mine-mcp"}}}"#,
              to: home.appendingPathComponent(".claude.json"))
    let second = try await HostSync.run(from: home, to: files, dataFolder: data)
    #expect(second.skipped.isEmpty && second.kept == ["mine"] && second.missing == ["files": "npx"])
    for (path, there) in [("skills/review/SKILL.md", false), ("commands/ship.md", false), ("skills/own/SKILL.md", true), ("skills/linked/SKILL.md", true), ("CLAUDE.md", true)] {
        #expect(FileManager.default.fileExists(atPath: host.appendingPathComponent(".claude/" + path).path) == there, "\(path)")
    }
    let list = try String(contentsOfFile: data + "/synced-files.txt", encoding: .utf8)
    #expect(!list.contains("review") && !list.contains("own") && list.contains(".claude/skills/linked/SKILL.md"))
    now = try servers()
    #expect(Set(now.keys) == ["mine", "theirs", "files"])
    #expect(now["files"]?["args"] as? [String] == ["-y", "files-mcp@2"])
    #expect(now["mine"]?["command"] as? String == "the-hosts-own")

    // A host file that isn't JSON is left as it is, and the sync says so.
    try write("{ broken", to: config)
    await #expect(throws: HostSync.Failure.self) { try await HostSync.run(from: home, to: files, dataFolder: data) }
    #expect(try String(contentsOf: config, encoding: .utf8) == "{ broken")

    // No file at all on the host: made, with the servers alone.
    try FileManager.default.removeItem(at: config)
    try FileManager.default.removeItem(atPath: data + "/synced-mcp.json")
    #expect(try await HostSync.run(from: home, to: files, dataFolder: data).kept.isEmpty)
    #expect(Set(try servers().keys) == ["files", "mine"])
}

@MainActor @Test func aHostIsSyncedOnceWhenItAnswersAndAgainWhenAsked() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    // Nothing is copied unasked without a home to copy from (every other test here).
    let store = rig.hosts.store(for: rig.host)
    try await waitUntil { store.isLoaded }
    #expect(rig.hosts.syncNotes.isEmpty)
    // A host that can't say where its data folder is: the row says the sync didn't happen.
    store.hostDataFolder = nil
    await rig.hosts.sync(rig.host, from: rig.folder)
    #expect(rig.hosts.syncNotes[rig.host]?.contains("builder") == true, "\(rig.hosts.syncNotes)")
}

// MARK: Pages

/// What a host serves on its loopback, standing in for the channel: every stream opened is one
/// end of a socket pair whose other end answers HTTP requests here, saying which port it is.
private final class Loopback: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [String] = []
    private var _requests: [String] = []
    /// Ports nothing listens on.
    var closed: Set<UInt16> = []
    /// Ports nothing listens on, as a real channel shows it: it opens, then ends without a byte.
    var refused: Set<UInt16> = []

    var opened: [String] { lock.withLock { _opened } }
    var requests: [String] { lock.withLock { _requests } }

    var open: HostProxy.Open {
        { [self] host, port in
            lock.withLock { _opened.append("\(host.uuidString.prefix(4)):\(port)") }
            guard !closed.contains(port) else { return nil }
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
            let inner = pair[1]
            guard !refused.contains(port) else {
                close(inner)
                return pair[0]
            }
            Thread.detachNewThread { [self] in
                var pending = Data()
                while let head = Self.head(inner, &pending) {
                    let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                        line.lowercased().hasPrefix("content-length:") ? Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil
                    }.first ?? 0
                    while pending.count < length, let more = Self.read(inner) { pending.append(more) }
                    let body = String(decoding: pending.prefix(length), as: UTF8.self)
                    pending = Data(pending.dropFirst(length))
                    lock.withLock { _requests.append(head + (body.isEmpty ? "" : "\r\n\r\n" + body)) }
                    let answer = "port \(port): \(head.components(separatedBy: "\r\n")[0])" + (body.isEmpty ? "" : " [\(body)]")
                    send(inner, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(answer.utf8.count)\r\n\r\n\(answer)")
                }
                close(inner)
            }
            return pair[0]
        }
    }

    static func read(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        return count > 0 ? Data(buffer[..<count]) : nil
    }

    static func head(_ fd: Int32, _ pending: inout Data) -> String? {
        while true {
            if let range = pending.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: pending[pending.startIndex..<range.lowerBound], as: UTF8.self)
                pending = Data(pending[range.upperBound...])
                return head
            }
            guard let more = read(fd) else { return nil }
            pending.append(more)
        }
    }
}

private func send(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return }
        offset += count
    }
}

/// A connection to a port of this Mac's loopback.
private func dial(_ port: UInt16) throws -> Int32 {
    try #require(connection(to: port))
}

/// A connection to a port of this Mac's loopback; nil when nothing listens there.
private func connection(to port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    guard connected else {
        close(fd)
        return nil
    }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

/// One answer off the connection: its status line and its body.
private func answer(_ fd: Int32) -> (status: String, body: String)? {
    var pending = Data()
    guard let head = Loopback.head(fd, &pending) else { return nil }
    let lines = head.components(separatedBy: "\r\n")
    let length = lines.compactMap { $0.lowercased().hasPrefix("content-length:") ? Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
    while pending.count < length, let more = Loopback.read(fd) { pending.append(more) }
    return (lines[0], String(decoding: pending.prefix(length), as: UTF8.self))
}

private let builder = UUID(uuidString: "0B6F0D6E-5F0A-4A55-9A37-0D5B8F1C2E11")!

private func pass(_ proxy: HostProxy, host: UUID = builder) -> String {
    "Proxy-Authorization: Basic " + Data("\(host.uuidString):\(proxy.token)".utf8).base64EncodedString() + "\r\n"
}

@Test func theProxySendsLoopbackRequestsToTheHostAndKeepsItsPasswordToItself() throws {
    let host = Loopback()
    let proxy = HostProxy(open: host.open)
    #expect(proxy.port != 0)
    #expect(proxy.settings(for: builder) == ["server": "http://127.0.0.1:\(proxy.port)", "username": builder.uuidString, "password": proxy.token])
    let page = try dial(proxy.port)
    defer { close(page) }

    // The page asks for localhost: the host's port answers, and sees an ordinary request.
    send(page, "GET http://localhost:5173/src/main.ts?v=1 HTTP/1.1\r\nHost: localhost:5173\r\n\(pass(proxy))Proxy-Connection: keep-alive\r\nAccept: */*\r\n\r\n")
    #expect(answer(page)?.body == "port 5173: GET /src/main.ts?v=1 HTTP/1.1")
    #expect(host.requests.last == "GET /src/main.ts?v=1 HTTP/1.1\r\nHost: localhost:5173\r\nAccept: */*")

    // The next one on the same connection uses the same stream; a body goes whole.
    send(page, "POST http://localhost:5173/api HTTP/1.1\r\nHost: localhost:5173\r\n\(pass(proxy))Content-Length: 11\r\n\r\nhello world")
    #expect(answer(page)?.body == "port 5173: POST /api HTTP/1.1 [hello world]")
    #expect(host.opened == ["0B6F:5173"])

    // Another port on the same connection: another stream, never the first one's.
    send(page, "GET http://127.0.0.1:3000 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\(pass(proxy))\r\n")
    #expect(answer(page)?.body == "port 3000: GET / HTTP/1.1")
    send(page, "GET http://[::1]:8080/x HTTP/1.1\r\nHost: [::1]:8080\r\n\(pass(proxy))\r\n")
    #expect(answer(page)?.body == "port 8080: GET /x HTTP/1.1")
    // A web socket, as WebKit asks a proxy for one: the same request, its upgrade kept.
    send(page, "GET ws://localhost:5173/hmr HTTP/1.1\r\nHost: localhost:5173\r\n\(pass(proxy))Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
    #expect(answer(page)?.body == "port 5173: GET /hmr HTTP/1.1")
    #expect(host.requests.last == "GET /hmr HTTP/1.1\r\nHost: localhost:5173\r\nUpgrade: websocket\r\nConnection: Upgrade")
    #expect(host.opened == ["0B6F:5173", "0B6F:3000", "0B6F:8080", "0B6F:5173"])
    #expect(!host.requests.contains { $0.lowercased().contains("proxy-") }, "the password never reaches a server")
}

@Test func theProxyTunnelsConnectAndRefusesWhoeverLacksTheToken() throws {
    let host = Loopback()
    host.closed = [9]
    host.refused = [10]
    let proxy = HostProxy(open: host.open)

    // A tunnel (https, a web socket) to the host's port: bytes both ways, untouched.
    let tunnel = try dial(proxy.port)
    defer { close(tunnel) }
    send(tunnel, "CONNECT localhost:8443 HTTP/1.1\r\nHost: localhost:8443\r\n\(pass(proxy))\r\n")
    #expect(answer(tunnel)?.status == "HTTP/1.1 200 Connection Established")
    send(tunnel, "GET /socket HTTP/1.1\r\nUpgrade: websocket\r\n\r\n")
    #expect(answer(tunnel)?.body == "port 8443: GET /socket HTTP/1.1")

    // Another program on this Mac, without the token or with a wrong one, gets nothing.
    for header in ["", "Proxy-Authorization: Basic " + Data("\(builder.uuidString):wrong".utf8).base64EncodedString() + "\r\n",
                   "Proxy-Authorization: Basic " + Data("nobody:\(proxy.token)".utf8).base64EncodedString() + "\r\n"] {
        let stranger = try dial(proxy.port)
        send(stranger, "GET http://localhost:5173/ HTTP/1.1\r\nHost: localhost:5173\r\n\(header)\r\n")
        #expect(answer(stranger)?.status == "HTTP/1.1 407 Proxy Authentication Required")
        close(stranger)
    }
    #expect(host.opened == ["0B6F:8443"])

    // A port nothing serves on the host, and a host that can't be reached: a plain failure.
    let dead = try dial(proxy.port)
    defer { close(dead) }
    send(dead, "GET http://localhost:9/ HTTP/1.1\r\nHost: localhost:9\r\n\(pass(proxy))\r\n")
    #expect(answer(dead)?.status == "HTTP/1.1 502 Bad Gateway")
    let silent = try dial(proxy.port)
    defer { close(silent) }
    send(silent, "GET http://localhost:10/ HTTP/1.1\r\nHost: localhost:10\r\n\(pass(proxy))\r\n")
    #expect(answer(silent)?.status == "HTTP/1.1 502 Bad Gateway")

    // Only the machine's own names go to the host: a name that merely looks like one is
    // connected to from here, like any other site (this one doesn't exist).
    let other = try dial(proxy.port)
    defer { close(other) }
    send(other, "GET http://127.example.invalid/ HTTP/1.1\r\nHost: 127.example.invalid\r\n\(pass(proxy))\r\n")
    #expect(answer(other)?.status == "HTTP/1.1 502 Bad Gateway")
    #expect(host.opened == ["0B6F:8443", "0B6F:9", "0B6F:10"])

    for name in ["localhost", "LOCALHOST", "app.localhost", "127.0.0.1", "127.8.9.1", "::1", "0.0.0.0"] { #expect(HostProxy.isLoopback(name), "\(name)") }
    for name in ["example.com", "127.example.com", "localhost.example.com", "128.0.0.1", "10.0.0.1", "::2"] { #expect(!HostProxy.isLoopback(name), "\(name)") }
    #expect(HostProxy.alias(for: "builder") == "builder.localhost" && HostProxy.alias(for: "Edu's Box #2") == "edu-s-box-2.localhost")
    #expect(HostProxy.alias(for: "") == "host.localhost" && HostProxy.isLoopback(HostProxy.alias(for: "çã")))
    #expect(HostProxy.authority("user:pw@[::1]:81", defaultPort: 80)?.port == 81)
    #expect(HostProxy.authority("localhost", defaultPort: 80)?.port == 80)
    #expect(HostProxy.authority("localhost:x", defaultPort: 80) == nil)
}

@Test func aRunnersLinkOpensOnAPortHereThatLeadsToTheHosts() throws {
    let host = Loopback()
    let proxy = HostProxy(open: host.open)
    let url = try #require(proxy.forwarded("http://localhost:3000/docs?tab=1", on: builder))
    #expect(url.host == "127.0.0.1" && url.path == "/docs" && url.query == "tab=1")
    let local = try #require(url.port.map(UInt16.init(clamping:)))
    #expect(local != 3000)
    // The same port each time it is asked for; another for another port or host.
    #expect(proxy.forward(3000, on: builder) == local)
    #expect(proxy.forward(3001, on: builder) != local && proxy.forward(3000, on: UUID()) != local)
    // What the host's network address serves is reached directly, not through here.
    #expect(proxy.forwarded("http://192.168.1.20:3000", on: builder) == nil)

    let browser = try dial(local)
    defer { close(browser) }
    send(browser, "GET /docs?tab=1 HTTP/1.1\r\nHost: 127.0.0.1:\(local)\r\n\r\n")
    #expect(answer(browser)?.body == "port 3000: GET /docs?tab=1 HTTP/1.1")
    #expect(host.opened == ["0B6F:3000"])

    // The runner serving 3000 stopped: its port here closes; the one still served stays.
    let kept = try #require(proxy.forward(3001, on: builder)), elsewhere = UUID()
    let others = try #require(proxy.forward(3000, on: elsewhere))
    proxy.keepForwards([3001], on: builder)
    #expect(connection(to: local) == nil)
    #expect(proxy.forward(3001, on: builder) == kept && proxy.forward(3000, on: elsewhere) == others)
    close(try dial(kept))
    // Asked for again (the runner is back, the link clicked), it opens anew.
    let anew = try dial(try #require(proxy.forward(3000, on: builder)))
    defer { close(anew) }
    send(anew, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    #expect(answer(anew)?.body == "port 3000: GET / HTTP/1.1")
}

/// A real page in the browser cards' WebKit, through the proxy: run with
/// `AGENTBOARD_WEBKIT_PROBE=<folder holding node_modules/playwright-core>` and
/// `AGENTBOARD_NODE=<node>` (and `PLAYWRIGHT_BROWSERS_PATH` when the home isn't the user's).
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_WEBKIT_PROBE"] != nil))
func aRealPageReachesWhatOnlyTheHostServes() throws {
    let environment = ProcessInfo.processInfo.environment
    let host = Loopback()
    let proxy = HostProxy(open: host.open)
    let folder = try temporaryFolder("webkit")
    defer { try? FileManager.default.removeItem(at: folder) }
    // Nothing listens on these ports on this Mac: only the stand-in host answers them.
    try write("""
        import { createRequire } from 'node:module';
        const { webkit } = createRequire(process.argv[2] + '/')('playwright-core');
        const browser = await webkit.launch();
        const out = [];
        // Many pages, each in a context of its own as a card is: WebKit's first request in a
        // context is the one that strays when it does.
        for (let i = 0; i < 12; i++) {
          const context = await browser.newContext({ proxy: JSON.parse(process.argv[3]) });
          const page = await context.newPage();
          // What the sidecar navigates to for `localhost:45173` on a host called builder (`onHost`).
          await page.goto('http://builder.localhost:45173/index.html');
          out.push(await page.textContent('body') + ' at ' + page.url());
          out.push(await page.evaluate(() => fetch('/api', { method: 'POST', body: 'from the page' }).then(r => r.text())));
          await page.goto('http://builder.localhost:43000/');
          out.push(await page.textContent('body'));
          await context.close();
        }
        const direct = await browser.newContext();
        const lost = await (await direct.newPage()).goto('http://builder.localhost:45173/', { timeout: 5000 }).then(() => 'reached', () => 'unreachable');
        console.log(JSON.stringify({ out, lost }));
        await browser.close();
        """, to: folder.appendingPathComponent("probe.mjs"))
    let node = Process()
    node.executableURL = URL(fileURLWithPath: try #require(environment["AGENTBOARD_NODE"]))
    node.arguments = [folder.appendingPathComponent("probe.mjs").path, try #require(environment["AGENTBOARD_WEBKIT_PROBE"]),
                      String(decoding: try JSONSerialization.data(withJSONObject: proxy.settings(for: builder)), as: UTF8.self)]
    let output = Pipe()
    node.standardOutput = output
    try node.run()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    node.waitUntilExit()
    for text in ["port 45173: GET /index.html HTTP/1.1 at http://builder.localhost:45173/index.html", "port 45173: POST /api HTTP/1.1 [from the page]",
                 "port 43000: GET / HTTP/1.1"] {
        #expect(printed.components(separatedBy: text).count - 1 == 12, "\(text): \(printed) \(host.opened)")
    }
    #expect(host.requests.contains { $0.contains("Host: builder.localhost:45173") }, "the server sees a localhost name")
    #expect(printed.contains("\"lost\":\"unreachable\""), "a page without the proxy doesn't reach the host: \(printed)")
}
