@testable import AgentRuntime
import Connections
import Darwin
import Foundation
@testable import Orchestration
import Testing
@testable import AgentBoard

/// The app's own code against a real host, through the deployed account server: what the UI
/// calls when the user signs in, makes a worktree on a host, opens it, and uses its cards.
/// `AGENTBOARD_PILOT=<account.json> scripts/test-safe --filter HostAppPilotTests`, the file
/// holding a signed-in account (`token`, `account`). It syncs this Mac's skills and MCP servers
/// to the host (as the app does on connecting) and otherwise leaves nothing there.
/// `AGENTBOARD_WEBKIT_PROBE`, `AGENTBOARD_NODE` and `PLAYWRIGHT_BROWSERS_PATH` add a real page.
@MainActor struct HostAppPilotTests {
    nonisolated private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func waitUntil(_ seconds: Double = 60, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func text(_ result: ToolResult) -> String {
        result.content.map { if case .text(let text) = $0 { text } else { "" } }.joined()
    }

    private func localGit(_ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.environment = Git.environment
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// The pilot's own key, which the host must trust: `board.key` beside the account file.
    static var pilotKey: TokenVault { .file(URL(fileURLWithPath: environment["AGENTBOARD_PILOT"] ?? "").deletingLastPathComponent().appendingPathComponent("board.key")) }

    /// Approving, forgetting and removing a computer, by the app's own stores against the real
    /// host, with keys made here and never kept. The host's list ends as it was found.
    @Test(.enabled(if: environment["AGENTBOARD_PILOT"] != nil), .timeLimit(.minutes(5)))
    func aRealHostAdmitsAndForgetsComputersThroughTheApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-boards-pilot-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pilot = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Self.environment["AGENTBOARD_PILOT"]!))) as? [String: Any])
        let signedIn = folder.appendingPathComponent("account.json")
        try JSONSerialization.data(withJSONObject: ["account": pilot["account"] ?? [:]]).write(to: signedIn)
        // A computer of the account: the pilot's with its kept key, or one whose key lives in this process only.
        func computer(_ name: String, key: TokenVault = .memory()) async throws -> HostStores {
            let account = AccountStore(file: signedIn, vault: .memory(pilot["token"] as? String), boardVault: key)
            account.boardName = name
            try await waitUntil(30) { account.hosts.contains { $0.online } }
            return HostStores(local: AgentStore(database: folder.appendingPathComponent("\(UUID().uuidString).sqlite"), connect: { .failure(.noCore) }), account: account)
        }
        let trusted = try await computer("pilot", key: Self.pilotKey)
        let host = try #require(trusted.account.hosts.first { $0.online }, "no host of this account is online").id
        await trusted.listBoards(of: host)
        let found = try #require(trusted.boards[host], "the host trusts the pilot's key")
        print("boards: found \(found.trusted.map(\.fingerprint)) trusted, \(found.pending.map(\.fingerprint)) pending")
        func opensCore(_ computer: HostStores) async -> Bool {
            guard let target = computer.account.channel(to: host) else { return false }
            let opening = Task.detached { HostChannel.open(server: target.server, token: target.token, host: host, hostKey: target.key, board: target.board).channel }
            let channel = await opening.value
            if let channel { close(channel) }
            return channel != nil
        }

        // Whatever happens in between, every key made here is forgotten there (trusted or waiting) before the end.
        final class Made { var keys: [String] = [] }
        let made = Made()
        do {
            // 1. A computer the host never saw waits, and hears how many the host trusts.
            let new = try await computer("pilot\u{1B}[2K throwaway\u{7}")
            let newKey = try #require(new.account.boardPublicKey), newPrint = AccountStore.fingerprint(of: newKey)
            made.keys.append(newKey)
            await new.listBoards(of: host)
            #expect(new.waiting[host] ?? 0 >= 1 && new.boards[host] == nil)
            #expect(!(await opensCore(new)))
            print("boards: 1. \(newPrint) is waiting for approval; the host trusts \(new.waiting[host] ?? -1)")

            // 2. The trusted one sees it asking, its name without what could redraw a line.
            await trusted.listBoards(of: host)
            let asking = try #require(trusted.boards[host]?.pending.first { $0.key == newKey })
            #expect(asking.name == "pilot[2K throwaway")
            print("boards: 2. pending as “\(asking.name)”")

            // 3. Approved through the store: it gets in.
            #expect(await trusted.changeBoard(newKey, on: host))
            #expect(await opensCore(new))
            await new.listBoards(of: host)
            #expect(new.waiting[host] == nil && new.boards[host]?.trusted.contains { $0.key == newKey } == true)
            print("boards: 3. approved, and a core channel opens for it: \(await opensCore(new))")

            // 4. A third key the host doesn't know decides nothing (the host takes one new key every 10 seconds).
            try await Task.sleep(for: .seconds(11))
            let stranger = try await computer("pilot stranger")
            let strangerKey = try #require(stranger.account.boardPublicKey)
            made.keys.append(strangerKey)
            let trustedItself = await stranger.changeBoard(strangerKey, on: host)
            let forgotAnother = await stranger.changeBoard(newKey, on: host, forget: true)
            #expect(!trustedItself && !forgotAnother && stranger.waiting[host] ?? 0 >= 2 && stranger.boards[host] == nil)
            await trusted.listBoards(of: host)
            #expect(trusted.boards[host]?.trusted.contains { $0.key == newKey } == true && trusted.boards[host]?.trusted.contains { $0.key == strangerKey } == false)
            print("boards: 4. an unknown key's trust and forget got: trusted itself \(trustedItself), forgot another \(forgotAnother), verdict pending \(stranger.waiting[host] ?? -1)")

            // 5. Forgotten through the store: waiting again at its next try.
            #expect(await trusted.changeBoard(newKey, on: host, forget: true))
            // Once forgotten it is a new key to the host again: recorded as pending only 10 seconds after the stranger was.
            try await Task.sleep(for: .seconds(11))
            await new.listBoards(of: host)
            #expect(new.waiting[host] ?? 0 >= 1 && new.boards[host] == nil)
            #expect(!(await opensCore(new)))
            print("boards: 5. forgotten, and pending again (\(new.waiting[host] ?? -1) trusted)")

            // 6. What signing out with "Remove this Mac from its hosts first" does before it signs
            // out, for that computer only; the sign-out itself (the pilot's session) is never sent.
            #expect(await trusted.changeBoard(newKey, on: host))
            await new.listBoards(of: host)
            try #require(new.waiting[host] == nil)
            await new.removeThisMac()
            await trusted.listBoards(of: host)
            #expect(trusted.boards[host]?.trusted.contains { $0.key == newKey } == false)
            print("boards: 6. removed by itself; among the trusted now: \(trusted.boards[host]?.trusted.contains { $0.key == newKey } ?? true)")
        } catch {
            Issue.record("stopped: \(error)")
        }
        for key in made.keys { _ = await trusted.changeBoard(key, on: host, forget: true) }
        await trusted.listBoards(of: host)
        let left = try #require(trusted.boards[host])
        #expect(left == found, "the host's list isn't as it was found")
        print("boards: left \(left.trusted.map(\.fingerprint)) trusted, \(left.pending.map(\.fingerprint)) pending")
    }

    @Test(.enabled(if: environment["AGENTBOARD_PILOT"] != nil), .timeLimit(.minutes(15)))
    func theAppDrivesARealHost() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-app-pilot-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = isolatedGitConfig

        // 1. The account, as the app loads it at launch, and its hosts.
        // The token goes from the pilot's file to memory only: never to another file, the
        // Keychain or the output. The file given to the store says who is signed in, no more.
        let pilot = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Self.environment["AGENTBOARD_PILOT"]!))) as? [String: Any])
        let signedIn = folder.appendingPathComponent("account.json")
        try JSONSerialization.data(withJSONObject: ["account": pilot["account"] ?? [:]]).write(to: signedIn)
        let account = AccountStore(file: signedIn, vault: .memory(pilot["token"] as? String), boardVault: Self.pilotKey)
        print("pilot: this board is \(AccountStore.fingerprint(of: account.boardPublicKey ?? ""))")
        try #require(account.account != nil, "the pilot's account file didn't load")
        try await waitUntil(30) { account.hosts.contains { $0.online } }
        let host = try #require(account.hosts.first { $0.online }, "no host of this account is online")
        print("pilot: \(host.name) is online (\(host.platform), \(host.version))")

        let local = AgentStore(database: folder.appendingPathComponent("cards.sqlite"), connect: { .failure(.noCore) })
        let hosts = HostStores(local: local, account: account)
        let projects = ProjectStore(databaseURL: folder.appendingPathComponent("board.sqlite"))
        projects.hosts = hosts
        hosts.prepare = { $0.projectTools = ProjectTools(projects: projects, agents: $0, hosts: hosts) }
        hosts.prepare?(local)

        // A project here whose origin anyone can read.
        let name = "pilot-\(UUID().uuidString.prefix(6).lowercased())"
        let repo = folder.appendingPathComponent(name)
        try Git.createRepository(at: repo)
        localGit("-C", repo.path, "remote", "add", "origin", "https://github.com/octocat/Hello-World.git")
        localGit("-C", repo.path, "fetch", "origin")
        let project = try #require(projects.addProject(at: repo))

        let opening = Date()
        let store = hosts.store(for: host.id)
        try await waitUntil(60) { store.isLoaded }
        try #require(store.isLoaded, "couldn't reach \(host.name): \(store.notice ?? "no answer")\(hosts.waiting[host.id].map { _ in " (run `agentboard trust \(account.boardPublicKey ?? "")` on it)" } ?? "")")
        // What a trusted board may ask about the others.
        await hosts.listBoards(of: host.id)
        let listed = try #require(hosts.boards[host.id], "the host lists its boards to one it trusts")
        #expect(listed.trusted.contains { $0.key == account.boardPublicKey })
        print("pilot: the host trusts \(listed.trusted.map(\.fingerprint)) and has \(listed.pending.count) pending")
        print("pilot: connected in \(Int(Date().timeIntervalSince(opening) * 1000)) ms")
        let files = try #require(store.files)
        // What of that is the channel itself, and what trying the host's own addresses first costs.
        if let target = account.channel(to: host.id) {
            func opening(_ addresses: [String]) async -> Int {
                let asked = Date()
                let channel = await Task.detached { HostChannel.open(server: target.server, token: target.token, host: host.id, hostKey: target.key, board: target.board, addresses: addresses).channel }.value
                if let channel { close(channel) }
                return Int(Date().timeIntervalSince(asked) * 1000)
            }
            let first = store.core, again = Date()
            store.reconnect()
            try await waitUntil(30) { store.core != nil && store.core !== first && store.isLoaded }
            print("pilot: connected again, the server already spoken to, in \(Int(Date().timeIntervalSince(again) * 1000)) ms")
            print("pilot: a channel alone opens in \(await opening([])) ms through the relay, and in \(await opening(target.addresses)) ms with the host's \(target.addresses.count) addresses tried first")
        }

        // Whatever happens below, nothing of this stays on the host.
        func cleanUp() async {
            for record in store.agents where record.worktree.contains("/agentboard/projects/\(name)") { store.remove(record.id) }
            for image in store.images where image.worktree.contains("/agentboard/projects/\(name)") { store.removeImage(image.id) }
            try? await Task.sleep(for: .seconds(1))
            let removed = await store.run("sh", ["-c", "rm -rf \"$HOME/agentboard/projects/$1\"*; ls \"$HOME/agentboard/projects\" | grep -c \"^$1\"", "sh", name])
            print("pilot: left on the host under that name: \(removed.map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown")")
            store.quit()
        }
        do {
            try await drive(host: host, hosts: hosts, projects: projects, project: project, store: store, files: files, folder: folder, name: name)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    private func drive(host: AgentBoard.Host, hosts: HostStores, projects: ProjectStore, project: Project, store: AgentStore, files: HostFiles,
                       folder: URL, name: String) async throws {
        let account = hosts.account, local = hosts.local
        let caller = AgentRecord(id: UUID(), worktree: project.path, providerID: "claude", name: "Agent", frame: .zero,
                                 organization: projects.organizationID)
        local.insert(caller)
        let tools = try #require(local.projectTools)

        // 1. host_list, with the host's stats once its store hears them.
        try await waitUntil(30) { store.hostStats != nil }
        let listed = text(await tools.call("host_list", arguments: [:], caller: caller.id))
        print("pilot: host_list:\n\(listed)")
        #expect(listed.contains(host.name) && listed.contains("online"))
        #expect(listed.contains("CPU") && listed.contains("memory"), "the connected host shows its stats")
        print("pilot: the host was reached \(store.hostPath.map { "\($0)" } ?? "by no path it said")")
        #expect(store.hostPath != nil, "the store knows which path its channel took")
        #expect(account.pins[host.id]?.key == host.publicKey, "the host is pinned to the key it showed first")

        // 2. A worktree on the host through the dialog's own draft: checked, then created.
        let git = try await projects.gitHost(host.id)
        let draft = WorktreeDraft(repository: project.path)
        draft.host = git
        draft.name = "Pilot work"
        await draft.validate()
        #expect(draft.problem == nil, "\(draft.problem ?? "")")
        var created: Git.CreatedWorktree?
        draft.onCreated = { created = $0 }
        let creating = Date()
        await draft.submit()
        #expect(draft.error == nil, "\(draft.error ?? "")")
        let made = try #require(created, "the draft created nothing: \(draft.error ?? "no error")")
        print("pilot: the dialog's path made \(made.path) in \(Int(Date().timeIntervalSince(creating) * 1000)) ms")
        let worktree = await projects.hostWorktree(at: made.path, branch: draft.check?.branch, on: host.id, in: project)
        #expect(worktree.host == host.id && worktree.branch == "pilot-work")
        #expect(projects.worktrees[project.id]?.contains(worktree) == true, "it lists under the project, on its host")
        #expect(await files.isFolder(worktree.path), "its folder is on the host")

        // And once through the tool agents call, on a branch origin has (so it has an upstream).
        let viaTool = await tools.call("worktree_create", arguments: ["branch": "test", "host": host.name], caller: caller.id)
        #expect(!viaTool.isError, "\(text(viaTool))")
        print("pilot: worktree_create: \(text(viaTool))")
        let tracked = try #require(projects.worktrees[project.id]?.first { $0.host == host.id && $0.branch == "test" })
        let list = text(await tools.call("project_list", arguments: [:], caller: caller.id))
        #expect(list.contains("\(worktree.path) (pilot-work, on \(host.name))") && list.contains("(test, on \(host.name))"), "\(list)")

        // 3. Opening it: a runner there, mirrored here, and the port it serves.
        let port = 40000 + Int.random(in: 0..<5000)
        let runner = store.addRunner(command: "python3 -u -m http.server \(port)", name: "pilot server", directory: worktree.path, to: worktree.path, at: .zero)
        let session = store.session(for: runner, cols: 100, rows: 24)
        func screen(_ session: AgentSession) -> String { session.withTerminal { $0.screenText().joined(separator: "\n") }.trimmingCharacters(in: .whitespacesAndNewlines) }
        try await waitUntil(60) { screen(session).contains("Serving HTTP") }
        #expect(screen(session).contains("Serving HTTP"), "the runner's screen: \(screen(session)) (\(session.state))")
        #expect(store.agents(in: worktree.path).map(\.id) == [runner.id])
        try await waitUntil(60) { store.urls(of: runner.id).contains { $0.local == "http://localhost:\(port)" } }
        print("pilot: the runner shows “\(screen(session))” and reports \(store.urls(of: runner.id))")
        #expect(store.urls(of: runner.id).contains { $0.local == "http://localhost:\(port)" }, "the report has its port")

        // 4. The file tree card's model over the host's files.
        let model = FileBrowserModel(root: worktree.path, files: files)
        try await waitUntil(30) { !model.rows.isEmpty }
        #expect(model.rows.map(\.entry.name) == ["README"], "\(model.rows.map(\.entry.name))")
        model.open("README")
        try await waitUntil(30) { model.content != nil }
        #expect(model.content == .lines(["Hello World!"]), "\(String(describing: model.content))")

        // 5. A page's request, as a browser card of this worktree makes it: through the app's
        // proxy, to the alias the sidecar turns `localhost` into.
        let proxy = HostProxy(account: account)
        let settings = proxy.settings(for: host.id)
        let alias = HostProxy.alias(for: host.name)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(proxy.port)]
        configuration.timeoutIntervalForRequest = 60
        // The credentials a card's context is given, sent as WebKit sends them.
        configuration.httpAdditionalHeaders = ["Proxy-Authorization": "Basic " + Data("\(settings["username"]!):\(settings["password"]!)".utf8).base64EncodedString()]
        let browser = URLSession(configuration: configuration)
        // Without them the proxy serves nobody.
        let stranger = URLSessionConfiguration.ephemeral
        stranger.connectionProxyDictionary = configuration.connectionProxyDictionary
        #expect((try await URLSession(configuration: stranger).data(from: URL(string: "http://\(alias):\(port)/README")!).1 as? HTTPURLResponse)?.statusCode == 407)
        let asking = Date()
        let (body, response) = try await browser.data(from: URL(string: "http://\(alias):\(port)/README")!)
        print("pilot: http://\(alias):\(port)/README through the proxy: \((response as? HTTPURLResponse)?.statusCode ?? 0) “\(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))” in \(Int(Date().timeIntervalSince(asking) * 1000)) ms")
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: body, as: UTF8.self) == "Hello World!\n")
        try await waitUntil(30) { screen(session).contains("GET /README") }
        #expect(screen(session).contains("GET /README"), "the host's server logged the request: \(screen(session))")
        // A port nothing serves there fails plainly.
        // (On a connection of its own: the server closed the first one after answering, and
        // through the relay that reaches here a moment after a client could reuse it.)
        let dead = try await URLSession(configuration: configuration).data(from: URL(string: "http://\(alias):\(port + 1)/")!).1
        #expect((dead as? HTTPURLResponse)?.statusCode == 502)
        // The runner's link, as the system browser opens it.
        let forwarded = try #require(proxy.forwarded("http://localhost:\(port)/README", on: host.id))
        let direct = try await URLSession(configuration: .ephemeral).data(from: forwarded)
        #expect(String(decoding: direct.0, as: UTF8.self) == "Hello World!\n", "\(forwarded)")
        if let playwright = Self.environment["AGENTBOARD_WEBKIT_PROBE"], let node = Self.environment["AGENTBOARD_NODE"] {
            // Off the main thread, which the proxy asks for the account at each connection.
            let page = try await Task.detached { try Self.webKit(node: node, playwright: playwright, settings: settings, url: "http://\(alias):\(port)/", in: folder) }.value
            print("pilot: WebKit shows “\(page.trimmingCharacters(in: .whitespacesAndNewlines))”")
            // The server's listing of the worktree (a file without a type would download).
            #expect(page.contains("Directory listing") && page.contains("README"), "the server saw: \(screen(session))")
        }

        // 6. A picture added here goes to the host's folder first; one made there comes back.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let picture = try await store.addImage(.data(png), named: "Pilot", to: worktree.path, at: .zero)
        let hostData = try #require(await store.askHostDataFolder())
        #expect(await files.read("\(hostData)/images/\(picture.file)", limit: 1000) == png, "the picture is in \(hostData)/images")
        let theirs = "pilot-\(UUID().uuidString).png"
        #expect(await files.write(png, to: "\(hostData)/images/\(theirs)"))
        let record = ImageRecord(id: UUID(), worktree: worktree.path, name: "Theirs", frame: .zero, file: theirs, pixelSize: CGSize(width: 1, height: 1))
        store.fetchMedia(record)
        let copy = ImageFiles.url(of: theirs, in: store.dataFolder)
        try await waitUntil(30) { store.mediaNotes[theirs] == nil && FileManager.default.fileExists(atPath: copy.path) }
        #expect((try? Data(contentsOf: copy)) == png, "\(store.mediaNotes[theirs] ?? "not fetched")")
        _ = await store.run("rm", ["-f", "\(hostData)/images/\(theirs)"])
        store.removeImage(picture.id)
        try await waitUntil(30) { await !(files.read("\(hostData)/images/\(picture.file)", limit: 10) != nil) }
        #expect(await files.read("\(hostData)/images/\(picture.file)", limit: 10) == nil, "the host's core removed the picture with its card")

        // 7. Pull, where the worktree is.
        await projects.pull(tracked).value
        #expect(projects.errorMessage == nil, "\(projects.errorMessage ?? "")")
        // A new branch has nothing to pull from: git's own words reach the user.
        await projects.pull(worktree).value
        print("pilot: pulling a branch without an upstream says: \(projects.errorMessage ?? "nothing")")
        // In the host's language: whatever it is, it is git's and not "couldn't reach".
        #expect(projects.errorMessage?.isEmpty == false && projects.errorMessage?.contains(host.name) == false)
        projects.errorMessage = nil

        // With a way straight to the host (`AGENTBOARD_PILOT_ADDRESS`, e.g. a tunnel to its port),
        // the live store moves from the relay onto it, and what it mirrors carries on.
        if let address = Self.environment["AGENTBOARD_PILOT_ADDRESS"] {
            func roundTrip() async -> Int {
                let asked = Date()
                _ = await store.run("true", [])
                return Int(Date().timeIntervalSince(asked) * 1000)
            }
            let before = store.hostPath, relayed = await roundTrip(), old = store.core
            account.directAddresses = { _ in [address] }
            await hosts.retryDirect()
            try await waitUntil(20) { store.core != nil && store.core !== old && store.isLoaded }
            try await waitUntil(5) { if case .direct = store.hostPath { true } else { false } }
            let direct = await roundTrip()
            print("pilot: the store was on \(before.map { "\($0)" } ?? "?") (\(relayed) ms a round trip) and is now on \(store.hostPath.map { "\($0)" } ?? "?") (\(direct) ms)")
            #expect({ if case .direct = store.hostPath { true } else { false } }(), "the store moved to the direct path")
            #expect(store.notice == nil && store.agents(in: worktree.path).contains { $0.id == runner.id }, "its cards are still there")
            try await waitUntil(20) { store.sessions[runner.id]?.state == .running }
            #expect(store.sessions[runner.id]?.state == .running, "the runner is still mirrored, running")
        }

        // A project of the same name from another origin gets a clone of its own on the host.
        let twin = folder.appendingPathComponent("twin/\(name)")
        try Git.createRepository(at: twin)
        localGit("-C", twin.path, "remote", "add", "origin", "https://github.com/octocat/Spoon-Knife.git")
        localGit("-C", twin.path, "fetch", "origin")
        let twinPath = twin.path
        let apart = try await Task.detached { try Git.createWorktree(branch: "twin-work", in: twinPath, on: git) }.value
        print("pilot: the same name from another origin went to \(apart.path)")
        #expect(apart.path.contains("/\(name)-\(Git.shortHash(of: "github.com/octocat/Spoon-Knife"))-worktrees/"), "\(apart.path)")
        #expect(await files.output("git", ["-C", worktree.path, "remote", "get-url", "origin"])?.contains("Hello-World") == true)

        // A repository the host has no credentials for: the dialog says so, soon.
        let locked = folder.appendingPathComponent("locked/\(name)-locked")
        try Git.createRepository(at: locked)
        localGit("-C", locked.path, "remote", "add", "origin", "git@github.com:octocat/private-\(name).git")
        let lockedDraft = WorktreeDraft(repository: locked.path)
        lockedDraft.host = git
        lockedDraft.name = "Locked work"
        await lockedDraft.validate()
        let lockedSince = Date()
        await lockedDraft.submit()
        let waited = Date().timeIntervalSince(lockedSince)
        print("pilot: a clone the host has no credentials for, after \(Int(waited * 1000)) ms, shows in the dialog:\n\(lockedDraft.error ?? "nothing")")
        #expect(lockedDraft.error?.contains(host.name) == true && waited < 60)

        // 8. This Mac's skills and MCP servers, as the app sends them when the host answers.
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))
        // Kept in the account's vault (sealed with a key that stays beside the pilot's files) and applied by the host itself.
        let beside = URL(fileURLWithPath: Self.environment["AGENTBOARD_PILOT"]!).deletingLastPathComponent()
        hosts.syncHome = home
        hosts.vaultKeys = .file(beside.appendingPathComponent("vault.key"))
        hosts.vaultState = beside.appendingPathComponent("vault.base")
        hosts.githubLogin = { HostSync.githubLogin() }
        let syncing = Date()
        await hosts.syncVault()
        print("pilot: vault written and applied in \(Int(Date().timeIntervalSince(syncing) * 1000)) ms: \(hosts.vaultNote ?? "no note") Sent \(hosts.vaultSent?.sent ?? 0) bytes for \(hosts.vaultSent?.plain ?? 0) plain bytes of chunks.")
        print("pilot: the host says: \(hosts.syncNotes[host.id] ?? "no note")")
        let report = try #require(hosts.reports[host.id], "the host applied the vault and said what it did")
        // The report holds no secret: names, counts and whether `gh` took the login.
        print("pilot: pull report: version \(report.version), files \(report.files), removed \(report.removed), servers \(report.servers), lacking \(report.lacking), github \(report.github)")
        #expect(report.version > 0 && store.notice == nil && store.core != nil)
        let again = Date()
        await hosts.syncVault()
        print("pilot: synced again in \(Int(Date().timeIntervalSince(again) * 1000)) ms: \(hosts.vaultNote ?? "no note") The host: files \(hosts.reports[host.id]?.files ?? -1), removed \(hosts.reports[host.id]?.removed ?? -1)")
        #expect(hosts.vaultNote == AgentBoard.L("Up to date.") && hosts.reports[host.id]?.files == 0, "nothing changed: nothing to send or write")
        let signedIn = await store.run("sh", ["-c", #"PATH="$HOME/.local/bin:$PATH"; gh auth status 2>&1 | grep -E "Logged in|not logged|command not found" | sed -E 's/\(.*//'"#])
        print("pilot: `gh auth status` on the host: \(String(decoding: signedIn?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        if let skill = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude/skills").path))?.sorted().first(where: { !$0.hasPrefix(".") }) {
            #expect(await store.run("sh", ["-c", "test -e \"$HOME/.claude/skills/$1\"", "sh", skill])?.status == 0, "the skill \(skill) is on the host")
        }
        if let config = try? Data(contentsOf: home.appendingPathComponent(".claude.json")) {
            let sent = Set(HostSync.servers(in: config).copied.keys)
            let theirs = await files.output("sh", ["-c", "cat \"$HOME/.claude.json\""]) ?? ""
            let there = ((try? JSONSerialization.jsonObject(with: Data(theirs.utf8))) as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
            print("pilot: MCP servers on the host: \(there.keys.sorted())")
            #expect(Set(report.servers).isSubset(of: Set(there.keys)), "the host has what it said it ended with; sent \(sent.sorted())")
        }

        // What an agent there is given: the servers as its own program lists them (names and
        // state only: the rest of each line may hold a key), and the skills in its home.
        let offered = await store.run("sh", ["-c", "claude mcp list 2>&1 | sed -E 's/^([^:]*):.* - ([^-]*)$/\\1: \\2/'"], patience: 180)
        print("pilot: `claude mcp list` on the host (exit \(offered?.status ?? -1)):\n\(String(decoding: offered?.output ?? Data(), as: UTF8.self))")
        let skills = await files.output("sh", ["-c", "ls \"$HOME/.claude/skills\" | wc -l; ls \"$HOME/.claude/skills\" | head -8"]) ?? ""
        print("pilot: skills in the host's home (count, then the first):\n\(skills)")

        // 9. An agent on the host: its own screen, mirrored here.
        let provider = try #require(AgentCatalog.all.first)
        let agent = store.add(provider, to: worktree.path, at: CGPoint(x: 700, y: 0))
        let terminal = store.session(for: agent, cols: 120, rows: 36)
        try await waitUntil(90) { screen(terminal).count > 20 || { if case .failed = terminal.state { true } else { false } }() }
        try await waitUntil(20) { screen(terminal).split(separator: "\n").count > 3 }
        print("pilot: the \(provider.title) card (\(terminal.state)) shows:\n\(screen(terminal))")
        #expect(terminal.state == .running, "\(terminal.state)")
        #expect(screen(terminal).count > 20, "the agent drew its screen")
        store.remove(agent.id)
        store.remove(runner.id)

        // 2, the end. Removing, as the sidebar does: gone on the host.
        try await Task.sleep(for: .seconds(1))
        for removing in [tracked, worktree] {
            projects.removeWorktree(removing, from: project, force: true)
            try await waitUntil(60) { projects.worktrees[project.id]?.contains(removing) == false }
            #expect(projects.errorMessage == nil, "\(projects.errorMessage ?? "")")
            #expect(await !files.isFolder(removing.path), "\(removing.path) is gone from the host")
        }
        #expect(projects.worktrees[project.id]?.contains { $0.host == host.id } == false)
    }

    /// A real page in the browser cards' WebKit, with the proxy a card's context gets.
    nonisolated private static func webKit(node: String, playwright: String, settings: [String: String], url: String, in folder: URL) throws -> String {
        let script = folder.appendingPathComponent("page.mjs")
        try Data("""
            import { createRequire } from 'node:module';
            const { webkit } = createRequire(process.argv[2] + '/')('playwright-core');
            const browser = await webkit.launch();
            const page = await (await browser.newContext({ proxy: JSON.parse(process.argv[3]) })).newPage();
            await page.goto(process.argv[4], { timeout: 60000 });
            console.log(await page.textContent('body'));
            await browser.close();
            """.utf8).write(to: script)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, playwright, String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self), url]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return printed
    }

    /// What screenshots of a build under test need on the real host (see `AGENTBOARD_SHOTS` in
    /// docs/core.md): with `AGENTBOARD_PILOT_SHOTS=seed:<data folder>`, a project in that data
    /// folder's database with a worktree on the host and a runner in it, the host pinned and
    /// allowed to be synced to; with `clean:<data folder>`, all of it gone from the host again.
    @Test(.enabled(if: environment["AGENTBOARD_PILOT"] != nil && environment["AGENTBOARD_PILOT_SHOTS"] != nil), .timeLimit(.minutes(5)))
    func whatTheScreenshotsShowIsOnTheHost() async throws {
        let parts = Self.environment["AGENTBOARD_PILOT_SHOTS"]!.split(separator: ":", maxSplits: 1).map(String.init)
        let home = URL(fileURLWithPath: try #require(parts.last)), name = "shots-demo"
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = isolatedGitConfig
        let pilot = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Self.environment["AGENTBOARD_PILOT"]!))) as? [String: Any])
        let signedIn = home.appendingPathComponent("pilot-account.json")
        try JSONSerialization.data(withJSONObject: ["account": pilot["account"] ?? [:]]).write(to: signedIn)
        defer { try? FileManager.default.removeItem(at: signedIn) }
        let projects = ProjectStore(databaseURL: home.appendingPathComponent("agentboard.sqlite"))
        let account = AccountStore(file: signedIn, vault: .memory(pilot["token"] as? String), boardVault: Self.pilotKey, database: projects.database)
        try await waitUntil(30) { account.hosts.contains { $0.online } }
        let host = try #require(account.hosts.first { $0.online })
        let hosts = HostStores(local: AgentStore(database: home.appendingPathComponent("unused-cards.sqlite"), connect: { .failure(.noCore) }), account: account)
        projects.hosts = hosts
        let store = hosts.store(for: host.id)
        try await waitUntil(60) { store.isLoaded }
        try #require(store.isLoaded)

        if parts.first == "clean" {
            for record in store.agents where record.worktree.contains("/agentboard/projects/\(name)") { store.remove(record.id) }
            try await Task.sleep(for: .seconds(1))
            let left = await store.run("sh", ["-c", "rm -rf \"$HOME/agentboard/projects/$1\"*; ls \"$HOME/agentboard/projects\" | grep -c \"^$1\"", "sh", name])
            print("shots: left on the host: \(left.map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown")")
            return store.quit()
        }
        let repo = home.appendingPathComponent("projects/\(name)")
        if !FileManager.default.fileExists(atPath: repo.path) {
            try Git.createRepository(at: repo)
            localGit("-C", repo.path, "remote", "add", "origin", "https://github.com/octocat/Hello-World.git")
            localGit("-C", repo.path, "fetch", "origin")
        }
        let project = try #require(projects.projects.first { $0.path == repo.path } ?? projects.addProject(at: repo))
        let git = try await projects.gitHost(host.id), repository = repo.path
        let made = try await Task.detached { try Git.createWorktree(branch: "fix-login-redirect", in: repository, on: git) }.value
        let worktree = await projects.hostWorktree(at: made.path, branch: "fix-login-redirect", on: host.id, in: project)
        let runner = store.addRunner(command: "python3 -u -m http.server 8123", name: "dev server", directory: worktree.path, to: worktree.path, at: CGPoint(x: 80, y: 120))
        store.startRunner(runner.id)
        try await waitUntil(30) { !store.urls(of: runner.id).isEmpty }
        print("shots: worktree \(worktree.path)")
        store.quit()
    }
}
