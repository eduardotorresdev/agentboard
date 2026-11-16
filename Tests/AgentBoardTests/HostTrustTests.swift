@testable import AgentRuntime
import Darwin
import Foundation
@testable import Orchestration
import Testing
@testable import AgentBoard

/// Flipped by a test while its stubbed server runs.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private let firstKey = String(repeating: "A", count: 43) + "="
private let otherKey = "B" + String(repeating: "A", count: 42) + "="

// MARK: The token

@MainActor @Test func theTokenLivesInTheVaultAndAnOldFilesTokenMovesThereOnce() async throws {
    let stub = StubServer.make { call in call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}") }
    let file = accountFile(), vault = TokenVault.memory()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"token":"secret","account":{"login":"octo"}}"#.utf8).write(to: file)

    let store = AccountStore(server: stub.server, session: stub.session, file: file, vault: vault)
    #expect(store.account?.login == "octo" && store.token == "secret")
    #expect(vault.read() == "secret")
    let kept = try String(contentsOf: file, encoding: .utf8)
    #expect(!kept.contains("secret") && !kept.contains("token") && kept.contains("octo"))

    // The next launch reads it from the vault; without the vault's token nobody is signed in.
    #expect(AccountStore(server: stub.server, session: stub.session, file: file, vault: vault).token == "secret")
    #expect(AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory()).account == nil)

    // Signing out empties the vault too.
    await store.signOut()
    #expect(vault.read() == nil && !FileManager.default.fileExists(atPath: file.path))
}

@Test func anUnsignedBuildKeepsItsTokenInAFileOnlyItsOwnerReads() throws {
    let url = accountFile().deletingLastPathComponent().appendingPathComponent("account.token")
    let vault = TokenVault.file(url)
    #expect(vault.read() == nil && !vault.unreadable())
    #expect(vault.write("first") && vault.write("second") && vault.read() == "second")
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    #expect(vault.write(nil) && vault.read() == nil && !FileManager.default.fileExists(atPath: url.path))
}

@MainActor @Test func aSavedSignInThatCantBeReadSaysSoInsteadOfSigningOutSilently() throws {
    let file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let refusing = TokenVault(read: { nil }, write: { _ in false }, unreadable: { true })
    let store = AccountStore(server: URL(string: "https://nowhere.test")!, file: file, vault: refusing)
    #expect(store.account == nil && store.token == nil)
    #expect(store.isSigningIn && store.error == AgentBoard.L("Couldn't read the saved sign-in from the Keychain. Sign in again."))
    // Nobody saved: nothing to say.
    let nobody = AccountStore(server: URL(string: "https://nowhere.test")!, file: accountFile(), vault: refusing)
    #expect(!nobody.isSigningIn && nobody.error == nil)
}

@MainActor @Test func signingOutEverywhereAsksTheServerFirstAndOnlyThenSignsOutHere() async throws {
    let refusing = Flag()
    refusing.isOn = true
    let stub = StubServer.make { call in
        call.path == "/v1/logout/boards" ? (refusing.isOn ? (500, "{}") : (200, "{}")) : call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}")
    }
    let file = accountFile(), vault = TokenVault.memory("secret")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let store = AccountStore(server: stub.server, session: stub.session, file: file, vault: vault)
    var signedOut = 0
    store.onSignOut = { signedOut += 1 }

    // The server didn't do it: still signed in here.
    #expect(await store.signOutEverywhere() == false)
    #expect(store.account != nil && vault.read() == "secret" && signedOut == 0)

    refusing.isOn = false
    #expect(await store.signOutEverywhere())
    #expect(stub.calls().contains(StubServer.Call(method: "POST", path: "/v1/logout/boards", authorization: "Bearer secret")))
    #expect(store.account == nil && store.token == nil && vault.read() == nil && signedOut == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(!stub.calls().contains { $0.path == "/v1/logout" }, "the one call covers this board's session too")
}

// MARK: Whose host it is

@Test func aKeysFingerprintIsWhatTheHostPrints() {
    // SHA-256 of 32 zero bytes starts 66687aadf862bd776c8f.
    #expect(AccountStore.fingerprint(of: firstKey) == "6668 7aad f862 bd77 6c8f")
    #expect(AccountStore.fingerprint(of: otherKey) != AccountStore.fingerprint(of: firstKey))
}

@MainActor @Test func aHostIsHeldToTheKeyItFirstShowedUntilTheUserAcceptsAnother() async throws {
    let replaced = Flag()
    let stub = StubServer.make { call in
        call.path == "/v1/hosts" ? (200, replaced.isOn ? hostsJSON.replacingOccurrences(of: firstKey, with: otherKey) : hostsJSON) : (200, "{}")
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("abpins-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let vault = TokenVault.memory("secret"), file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let store = AccountStore(server: stub.server, session: stub.session, file: file, vault: vault, database: try Database(url: url))
    try await waitUntil { store.hosts.count == 2 }
    let builder = store.hosts[0].id

    // First seen: pinned, connected to, nothing to say.
    #expect(store.pins[builder] == AccountStore.Pin(key: firstKey))
    #expect(store.channel(to: builder)?.key == Data(base64Encoded: firstKey) && !store.identityChanged(builder))

    // The server now gives another key for it: refused, here and after a relaunch.
    replaced.isOn = true
    var told = 0
    store.onHosts = { told += 1 }
    await store.refreshHosts()
    #expect(store.identityChanged(builder) && store.channel(to: builder) == nil && told == 1)
    #expect(store.pins[builder]?.key == firstKey, "never accepted silently")
    let relaunched = AccountStore(server: stub.server, session: stub.session, file: file, vault: vault, database: try Database(url: url))
    await relaunched.refreshHosts()
    #expect(relaunched.identityChanged(builder) && relaunched.channel(to: builder) == nil)

    // Accepted by the user: connected to with the new key.
    store.acceptIdentity(of: builder)
    #expect(!store.identityChanged(builder) && store.channel(to: builder)?.key == Data(base64Encoded: otherKey))
    #expect(try Database(url: url).hostPins()[builder]?.key == otherKey)

    // Forgotten: gone from the account on the server, with its pin.
    #expect(await store.forgetHost(builder))
    #expect(stub.calls().contains(StubServer.Call(method: "DELETE", path: "/v1/hosts/\(builder.uuidString.lowercased())", authorization: "Bearer secret")))
    #expect(store.pins[builder] == nil && !store.hosts.contains { $0.id == builder })
    #expect(try Database(url: url).hostPins()[builder] == nil)
}

@MainActor @Test func aHostThatCantBeForgottenOnTheServerStays() async throws {
    let stub = StubServer.make { call in call.method == "DELETE" ? (500, "{}") : call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}") }
    let file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let store = AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory("secret"))
    try await waitUntil { store.hosts.count == 2 }
    let builder = store.hosts[0].id
    #expect(await store.forgetHost(builder) == false)
    #expect(store.pins[builder] != nil && store.hosts.contains { $0.id == builder })
}

// MARK: The path

@MainActor @Test func aRelayedHostMovesToTheDirectPathWhenItOpens() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let store = rig.hosts.store(for: rig.host)
    try await waitUntil { store.isLoaded }
    let relayed = try #require(store.core)
    store.hostPath = .relay
    let git = try await rig.projects.gitHost(rig.host)

    // The direct path doesn't open: everything stays as it is, and the user who asked hears so.
    #expect(await rig.hosts.retryDirect(only: rig.host) == false)
    #expect(store.core === relayed)

    // It opens: asking for another host leaves this one, asking for this one moves it.
    let socket = rig.socket
    rig.hosts.openDirect = { _ in try? UnixSocket.connect(to: socket) }
    #expect(await rig.hosts.retryDirect(only: UUID()) == false)
    #expect(store.core === relayed)
    #expect(await rig.hosts.retryDirect(only: rig.host))
    try await waitUntil { store.core != nil && store.core !== relayed }
    try await waitUntil { if case .direct = store.hostPath { true } else { false } }
    #expect(store.notice == nil)
    let ran = try #require(await store.run("sh", ["-c", "printf %s direct"]))
    #expect(String(decoding: ran.output, as: UTF8.self) == "direct")
    // Git made before the move goes through the new connection.
    #expect(await Task.detached { git.run("true", []) }.value?.status == 0)
}

// MARK: Clones and git on a host

@Test func theSameRepositoryIsRecognizedHoweverItsAddressIsWritten() {
    let same = ["git@github.com:Owner/Repo.git", "ssh://git@github.com/Owner/Repo.git", "ssh://git@GitHub.com:22/Owner/Repo",
                "https://github.com/Owner/Repo/", "https://github.com/Owner/Repo.git\n"]
    #expect(Set(same.map(Git.normalized)) == ["github.com/Owner/Repo"])
    #expect(Git.normalized("git@github.com:Owner/Other.git") != Git.normalized(same[0]))
    #expect(Git.normalized("git@gitlab.com:Owner/Repo.git") != Git.normalized(same[0]))
    #expect(Git.normalized("/srv/git/repo.git/") == "/srv/git/repo.git")
    #expect(Git.shortHash(of: "a") == Git.shortHash(of: "a") && Git.shortHash(of: "a") != Git.shortHash(of: "b"))
    #expect(Git.shortHash(of: "a").count == 8)
}

@MainActor @Test func aProjectDoesntShareAHostsCloneWithAnotherOfTheSameName() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    // The host already has a clone under this project's name, of another repository.
    let usual = rig.home.appendingPathComponent("agentboard/projects/repo")
    try FileManager.default.createDirectory(at: usual, withIntermediateDirectories: true)
    for arguments in [["init", "-q"], ["remote", "add", "origin", "https://example.test/someone/repo.git"]] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", usual.path] + arguments
        try git.run()
        git.waitUntilExit()
    }
    let repository = rig.repo.path
    let host = try await rig.projects.gitHost(rig.host)
    let created = try await Task.detached { try Git.createWorktree(branch: "topic", in: repository, on: host) }.value
    let clone = await Task.detached { host.clone(of: repository) }.value
    #expect(clone != usual.path && clone.hasPrefix(usual.path + "-") && clone.count == usual.path.count + 9)
    #expect(created.path.hasPrefix(usual.path + "-"), "\(created.path)")
    #expect(FileManager.default.fileExists(atPath: clone + "/.git"))
    #expect(!FileManager.default.fileExists(atPath: usual.appendingPathComponent(".git/refs/remotes/origin").path), "the other clone was left alone")

    // Found again, by a board that starts over; a project whose clone is the usual folder keeps it.
    let again = try await rig.projects.gitHost(rig.host)
    #expect(await Task.detached { again.clone(of: repository) }.value == clone)
    #expect(again.knownClone(of: repository) == clone)
}

@Test func gitOnAHostWithoutCredentialsSaysWhatToSetUp() {
    for said in ["git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
                 "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
                 "Host key verification failed.\nfatal: Could not read from remote repository."] {
        let host = GitHost(name: "builder", home: "/home/dev") { _, _ in (128, Data(), Data(said.utf8)) }
        do {
            try host.output("git", ["clone"])
            Issue.record("it failed there")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("builder") && message.hasSuffix(said) && message.count > said.count + 20, "\(message)")
        }
    }
    // Anything else is git's own words.
    let host = GitHost(name: "builder", home: "/home/dev") { _, _ in (1, Data(), Data("fatal: not a git repository".utf8)) }
    #expect(throws: GitError.self) { try host.output("git", ["status"]) }
    #expect((try? host.output("git", ["status"])) == nil)
}

@MainActor @Test func aProgramOnAHostThatNeverAnswersIsGivenUpOn() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let host = try await rig.projects.gitHost(rig.host)
    GitHost.patience = 0.3
    defer { GitHost.patience = 16 * 60 }
    let started = Date()
    let ran = await Task.detached { host.run("sh", ["-c", "sleep 3"]) }.value
    #expect(ran?.status == 1 && ran?.error.isEmpty == false)
    #expect(Date().timeIntervalSince(started) < 2)
}

private func waitUntil(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(await condition())
}

/// The real Keychain, under a service made for this run and removed by it:
/// `AGENTBOARD_KEYCHAIN_TEST=1 scripts/test-safe --filter theRealKeychainKeepsReplacesAndForgetsAToken`,
/// alone: the Keychain is found through the home folder, read once per process.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_KEYCHAIN_TEST"] == "1"))
func theRealKeychainKeepsReplacesAndForgetsAToken() {
    // test-safe gives the tests a home of their own, where there is no keychain (adding to it
    // would stop at a "keychain not found" dialog): the user's own, for this test only.
    let given = ProcessInfo.processInfo.environment["HOME"]
    setenv("HOME", String(cString: getpwuid(getuid()).pointee.pw_dir), 1)
    defer { if let given { setenv("HOME", given, 1) } }
    let vault = TokenVault.keychain(service: "AgentBoard test \(UUID().uuidString)")
    defer { _ = vault.write(nil) }
    #expect(vault.read() == nil)
    #expect(vault.write("first") && vault.read() == "first")
    #expect(vault.write("second") && vault.read() == "second")
    #expect(vault.write(nil) && vault.read() == nil)
}

// MARK: Board identity

@MainActor @Test func thisMacsKeyIsMadeAtTheFirstSignInAndKept() async throws {
    let stub = StubServer.make { call in call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}") }
    let file = accountFile(), keys = TokenVault.memory()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Signed out: no key yet.
    #expect(AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory(), boardVault: keys).boardKey == nil && keys.read() == nil)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let store = AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory("secret"), boardVault: keys)
    let made = try #require(store.boardPublicKey)
    #expect(Data(base64Encoded: made)?.count == 32 && keys.read() != nil && keys.read() != made, "the vault holds the private half")
    try await waitUntil { store.hosts.count == 2 }
    #expect(store.channel(to: store.hosts[0].id)?.board.key.publicKey.rawRepresentation.base64EncodedString() == made)
    // Signing out keeps it: the hosts that trust this Mac still do after signing in again.
    await store.signOut()
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    #expect(AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory("secret"), boardVault: keys).boardPublicKey == made)
    // One the vault holds but won't give isn't replaced by a new one.
    let refusing = TokenVault(read: { nil }, write: { _ in Issue.record("a key was written over one that couldn't be read"); return false }, unreadable: { true })
    #expect(AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory("secret"), boardVault: refusing).boardKey == nil)
}

@Test func whatIsAskedOfAHostAboutItsBoardsAndWhatIsShownOfItsAnswer() throws {
    #expect(String(decoding: HostStores.Boards.request("list"), as: UTF8.self) == #"{"list":{}}"#)
    #expect(String(decoding: HostStores.Boards.request("trust", key: "a+b/c="), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") == #"{"trust":{"key":"a+b/c="}}"#)
    #expect(String(decoding: HostStores.Boards.request("forget", key: "k"), as: UTF8.self) == #"{"forget":{"key":"k"}}"#)
    #expect(!HostStores.Boards.request("list").contains(10), "one line")

    // A name is anyone's words: shown without what could redraw the line it is on.
    let answer = #"{"trusted":[{"key":"\#(firstKey)","name":"Studio","added":1}],"pending":[{"key":"\#(otherKey)","name":"ok\u001b[2K\rtrusted\u202e\nMac","first_seen":1,"last_seen":2},{"name":"no key"}]}"#
    let listed = try #require(HostStores.Boards(Data(answer.utf8)))
    #expect(listed.trusted.map(\.name) == ["Studio"] && listed.trusted[0].fingerprint == "6668 7aad f862 bd77 6c8f")
    #expect(listed.pending.map(\.name) == ["ok[2KtrustedMac"])
    #expect(HostStores.Boards.shown(String(repeating: "a", count: 200)).count == 64)
    #expect(HostStores.Boards(Data(#"{"error":"not_trusted"}"#.utf8)) == nil && HostStores.Boards(nil) == nil)
}

@MainActor @Test func aHostThatDoesNotTrustThisMacYetIsWaitedForAndAskedAgainEveryInterval() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let account = rig.hosts.account, socket = rig.socket, host = rig.host
    final class Said: @unchecked Sendable {
        let lock = NSLock()
        var verdict = HostChannel.Opened.pending(trusted: 2), asked: [HostChannel.Carrying] = []
    }
    let said = Said()
    let hosts = HostStores(local: rig.hosts.local, account: account, open: { _, carrying in
        said.lock.withLock {
            said.asked.append(carrying)
            guard case .channel = said.verdict else { return said.verdict }
            // The core standing in for the host speaks no `boards`: only its own stream is opened to it.
            guard case .core = carrying else { return .failed }
            return (try? UnixSocket.connect(to: socket)).map { .channel($0) } ?? .failed
        }
    })
    let store = hosts.store(for: host)
    try await waitUntil { hosts.waiting[host] == 2 && store.notice != nil }
    // Not "can't reach": it answered, and says what it waits for; another computer got there first.
    #expect(store.notice?.contains("this Mac") == true || store.notice?.contains("este Mac") == true, "\(store.notice ?? "")")
    #expect(!account.wasTrusted(by: host))
    // The link retries every 5 seconds; the host is asked again only every `boardInterval`.
    try await Task.sleep(for: .seconds(6))
    #expect(said.lock.withLock { said.asked.count } == 1 && !store.isLoaded)

    // Approved meanwhile: the next try gets in, and this Mac remembers the host let it in.
    said.lock.withLock { said.verdict = .channel(-1) }
    hosts.boardInterval = 0.1
    try await waitUntil(20) { store.isLoaded }
    #expect(hosts.waiting[host] == nil && store.notice == nil && account.wasTrusted(by: host))
    // Forgotten there later: waiting again, now as a computer the host once trusted.
    said.lock.withLock { said.verdict = .pending(trusted: 1) }
    await hosts.listBoards(of: host)
    try await waitUntil { hosts.waiting[host] == 1 }
    #expect(account.wasTrusted(by: host) && hosts.boards[host] == nil)
    store.quit()
}

@MainActor @Test func aHostThatNeverLetThisMacInIsAskedWithoutTheMenuOrAWorktree() async throws {
    let offline = Flag()
    let stub = StubServer.make { call in
        call.path == "/v1/hosts" ? (200, offline.isOn ? hostsJSON.replacingOccurrences(of: "\"online\":true", with: "\"online\":false") : hostsJSON) : (200, "{}")
    }
    let file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let account = AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory("secret"))
    final class Said: @unchecked Sendable {
        let lock = NSLock()
        var asked: [UUID] = []
    }
    let said = Said()
    let hosts = HostStores(local: AgentStore(database: file.deletingLastPathComponent().appendingPathComponent("cards.sqlite"), connect: { .failure(.noCore) }),
                           account: account, open: { host, _ in said.lock.withLock { said.asked.append(host) }; return .pending(trusted: 1) })
    let asked = { said.lock.withLock { said.asked } }
    // The hosts arrive: the one online is asked, once, and this Mac waits for it; the offline one isn't.
    try await waitUntil { account.hosts.count == 2 && !hosts.waiting.isEmpty }
    let online = try #require(account.hosts.first { $0.online }).id
    #expect(hosts.waiting == [online: 1] && asked() == [online])
    // Refreshed again within the interval: not asked again. After it: asked again, the menu still closed.
    await account.refreshHosts()
    try await Task.sleep(for: .milliseconds(200))
    #expect(asked() == [online])
    hosts.boardInterval = 0.3
    try await Task.sleep(for: .milliseconds(400))
    await account.refreshHosts()
    try await waitUntil { asked().count == 2 }
    // The host goes offline: no more asking, and it isn't waited for.
    offline.isOn = true
    await account.refreshHosts()
    #expect(hosts.waiting.isEmpty)
    let before = asked().count
    try await Task.sleep(for: .milliseconds(500))
    await account.refreshHosts()
    try await Task.sleep(for: .milliseconds(200))
    #expect(asked().count == before)
}

@MainActor @Test func whatIsLargeTravelsOnAConnectionOfItsOwnAndASilentHostIsGivenUpOn() async throws {
    let rig = try await Rig()
    defer { rig.cleanUp() }
    let socket = rig.socket, host = rig.host
    final class Opened: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    let opened = Opened()
    let hosts = HostStores(local: rig.hosts.local, account: rig.hosts.account, open: { _, carrying in
        // The core standing in for the host speaks no `boards`: only its own stream is opened to it.
        guard case .core = carrying else { return .failed }
        opened.lock.withLock { opened.count += 1 }
        return (try? UnixSocket.connect(to: socket)).map { .channel($0) } ?? .failed
    })
    hosts.bulkIdle = 0.3
    let count = { opened.lock.withLock { opened.count } }
    let store = hosts.store(for: host)
    try await waitUntil { store.isLoaded }
    let own = try #require(store.core), files = try #require(store.files)
    // Small: the store's own connection.
    #expect(await files.run("sh", ["-c", "printf ok"], nil)?.output == Data("ok".utf8))
    #expect(count() == 1)
    // Past the limit: a second connection, opened for it; the store's own is the one it had.
    let large = Data(repeating: 7, count: HostFiles.bulkBytes + 1)
    #expect(await files.run("wc", ["-c"], large).map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespaces) } == "\(large.count)\n")
    #expect(count() == 2 && store.core === own)
    // Much to come back: the same second connection, still open.
    let file = NSTemporaryDirectory() + "abbulk-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: file) }
    try large.write(to: URL(fileURLWithPath: file))
    #expect(await files.read(file, limit: 4 * 1024 * 1024) == large)
    #expect(await files.read(file, limit: 16)?.count == 17)
    #expect(count() == 2)
    // Idle, it is closed; the next large one opens another.
    try await Task.sleep(for: .milliseconds(700))
    #expect(await files.run("wc", ["-c"], large)?.status == 0)
    #expect(count() == 3 && store.core === own)

    // A program that outlasts what it is given: an answer saying so, not a wait.
    let started = Date()
    let silent = try #require(await files.carried("sleep", ["20"], patience: 0.3))
    #expect(silent.status != 0 && silent.error == HostFiles.unanswered.error && Date().timeIntervalSince(started) < 5)
    #expect(await files.run("sh", ["-c", "printf alive"], nil)?.output == Data("alive".utf8), "the store's connection is as live as before")
    store.quit()
}
