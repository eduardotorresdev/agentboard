import CryptoKit
import Foundation
import Testing
@testable import AgentBoard

/// The account's vault, a board's side: sealing as the host opens it, writing as a merge, a
/// host's own servers, and what a host says of its pull ("The vault" in docs/hosts.md).
private func hex(_ text: String) -> Data {
    Data(stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! })
}

@Test func sealingAndChunkNamesAreTheOnesTheHostUses() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/fixtures/vault.json")
    let vector = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let text = { (name: String) in try #require(vector[name] as? String) }
    let key = hex(try text("key")), chunk = hex(try text("chunk"))
    #expect(Vault.sealingKey(key).withUnsafeBytes { Data($0) } == hex(try text("sealing_key")))
    #expect(Vault.chunkID(chunk, key: key) == (try text("chunk_id")))
    // What the host sealed opens here, and what is sealed here with its nonce is what it sealed.
    let sealedChunk = hex(try text("sealed_chunk")), sealedManifest = try #require(Data(base64Encoded: try text("sealed_manifest")))
    #expect(Vault.open(sealedChunk, key: key) == chunk)
    #expect(Vault.seal(chunk, key: key, nonce: hex(try text("chunk_nonce"))) == sealedChunk)
    let manifest = try #require(Vault.open(sealedManifest, key: key))
    let read = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
    let expected = try #require(try JSONSerialization.jsonObject(with: Data((vector["manifest"] as? String ?? "").utf8)) as? NSDictionary)
    #expect((read as NSDictionary) == expected)
    // The compressed ones the host seals open here too (what is sealed here opens there: the pilot).
    #expect(Vault.open(hex(try text("sealed_zlib_chunk")), key: key) == hex(try text("zlib_chunk")))
    #expect(Vault.chunkID(hex(try text("zlib_chunk")), key: key) == (try text("zlib_chunk_id")))
    let sealedZipped = try #require(Data(base64Encoded: try text("sealed_zlib_manifest")))
    let zipped = try #require(Vault.open(sealedZipped, key: key))
    #expect(try JSONSerialization.jsonObject(with: zipped) as? NSDictionary != nil)
    #expect(Vault.open(sealedChunk, key: Data(repeating: 1, count: 32)) == nil)
}

@Test func whatIsSealedIsCompressedWhenThatIsSmaller() throws {
    let key = Data(repeating: 5, count: 32)
    let text = Data(String(repeating: "A skill, in words that repeat. ", count: 400).utf8)
    let packed = Vault.packed(text)
    // zlib (RFC 1950): its two header bytes, the deflate stream, the Adler-32 of the plain bytes.
    #expect(packed.prefix(3) == Data([1, 0x78, 0x9C]) && packed.count < text.count / 10 && Vault.unpacked(packed) == text)
    #expect(Vault.packed(Data("abc".utf8)).suffix(4) != Data() && Vault.packed(Data("abc".utf8)) == Data([0]) + Data("abc".utf8))
    let inflated = Process(), given = Pipe(), back = Pipe()
    inflated.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    inflated.arguments = ["-c", "import sys, zlib; sys.stdout.buffer.write(zlib.decompress(sys.stdin.buffer.read()))"]
    inflated.standardInput = given
    inflated.standardOutput = back
    try inflated.run()
    given.fileHandleForWriting.write(packed.dropFirst())
    try given.fileHandleForWriting.close()
    #expect(back.fileHandleForReading.readDataToEndOfFile() == text, "another zlib reads it, checksum and all")
    // Noise doesn't shrink: kept as it is.
    let noise = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
    #expect(Vault.packed(noise) == Data([0]) + noise && Vault.unpacked(Vault.packed(noise)) == noise)
    #expect(Vault.unpacked(Data([2, 1])) == nil && Vault.unpacked(Data()) == nil)
    let sealed = try #require(Vault.seal(text, key: key))
    #expect(sealed.count < text.count / 10 && Vault.open(sealed, key: key) == text)
    #expect(Vault.seal(Data(), key: key).flatMap { Vault.open($0, key: key) } == Data())
}

/// The account server's vault, in memory, with its rules: a write names the version it read,
/// and no chunk the server lacks.
private final class FakeVault: @unchecked Sendable {
    let lock = NSLock()
    var version = 0, manifest: Data?, chunks: [String: Data] = [:]
    var requests: [Int] = [], lies = 0, interferes: (() -> Void)?

    var server: Vault.Server {
        Vault.Server(get: { self.lock.withLock { self.manifest.map { (self.version, $0) } } },
                     have: { ids in self.lock.withLock {
                         // Told once that it has everything, as when another writer's chunks went meanwhile.
                         if self.lies > 0 { self.lies -= 1; return [] }
                         return ids.filter { self.chunks[$0] == nil }
                     } },
                     putChunks: { sent in self.lock.withLock {
                         self.requests.append(sent.count)
                         for chunk in sent { self.chunks[chunk.id] = chunk.sealed }
                     } },
                     put: { version, manifest, ids in
                         let interferes = self.lock.withLock { () -> (() -> Void)? in defer { self.interferes = nil }; return self.interferes }
                         interferes?()
                         return self.lock.withLock {
                             guard version == self.version else { return .stale }
                             let missing = ids.filter { self.chunks[$0] == nil }
                             guard missing.isEmpty else { return .missing(missing) }
                             self.chunks = self.chunks.filter { ids.contains($0.key) }
                             self.manifest = manifest
                             self.version += 1
                             return .wrote(self.version)
                         }
                     })
    }

    func held(_ key: Data) -> Vault.Manifest {
        lock.withLock { manifest }.flatMap { Vault.open($0, key: key) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? Vault.Manifest } ?? [:]
    }
}

/// A computer with a home of its own and what it remembers of its last write.
private struct Writer {
    let home: URL, state: URL, name: String
    static let key = Data(repeating: 9, count: 32)

    init(_ name: String) throws {
        self.name = name
        home = FileManager.default.temporaryDirectory.appendingPathComponent("abvault-\(UUID().uuidString.prefix(8))")
        state = home.appendingPathComponent("vault.base")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
    }

    func put(_ text: String?, at path: String) throws {
        let file = home.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: file)
        guard let text else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @discardableResult
    func write(to vault: FakeVault, github: (user: String, token: String)? = nil, edit: (@Sendable (inout Vault.Manifest) -> Void)? = nil) async throws -> Int? {
        let local = Vault.local(home: home, key: Self.key, github: github)
        return try await Vault.write(local, key: Self.key, to: vault.server, state: state, by: name, edit: edit)?.version
    }
}

private func paths(_ manifest: Vault.Manifest) -> [String] { (manifest["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String } }
private func names(_ manifest: Vault.Manifest, _ section: String = "mcp") -> [String] { (manifest[section] as? [String: Any] ?? [:]).keys.sorted() }

@Test func twoComputersWriteTheVaultWithoutUndoingEachOther() async throws {
    let vault = FakeVault(), studio = try Writer("studio"), laptop = try Writer("laptop")
    defer { [studio, laptop].forEach { try? FileManager.default.removeItem(at: $0.home) } }
    try studio.put("review", at: ".claude/skills/review/SKILL.md")
    try studio.put("rules", at: ".claude/CLAUDE.md")
    try studio.put(#"{"mcpServers": {"alpha": {"command": "npx", "args": ["-y", "alpha"]}, "app": {"command": "/Applications/App.app/mcp"}}}"#, at: ".claude.json")
    try laptop.put("ship", at: ".claude/skills/ship/SKILL.md")
    try laptop.put(#"{"mcpServers": {"beta": {"type": "http", "url": "https://beta.example.test"}}}"#, at: ".claude.json")

    // Each adds what it has: both stay, with one request for all of a computer's chunks.
    #expect(try await studio.write(to: vault, github: ("octo", "gho_secret")) == 1)
    #expect(try await laptop.write(to: vault) == 2)
    var held = vault.held(Writer.key)
    #expect(paths(held) == [".claude/CLAUDE.md", ".claude/skills/review/SKILL.md", ".claude/skills/ship/SKILL.md"])
    #expect(names(held) == ["alpha", "beta"] && (held["github"] as? [String: String])?["user"] == "octo" && held["by"] as? String == "laptop")
    #expect(vault.requests == [2, 1] && vault.chunks.count == 3)
    // The server holds nothing it can read.
    #expect(!String(decoding: vault.manifest ?? Data(), as: UTF8.self).contains("gho_secret") && !vault.chunks.values.contains { $0.range(of: Data("review".utf8)) != nil })
    // Nothing changed here: nothing is asked of the server at all.
    let asked = vault.version
    #expect(try await studio.write(to: vault, github: ("octo", "gho_secret")) == nil && vault.version == asked)

    // One removes a skill and a server of its own, and changes a file: the other's entries are neither deleted nor brought back.
    try studio.put(nil, at: ".claude/skills/review/SKILL.md")
    try studio.put("rules, revised", at: ".claude/CLAUDE.md")
    try studio.put(#"{"mcpServers": {}}"#, at: ".claude.json")
    #expect(try await studio.write(to: vault, github: ("octo", "gho_secret")) == 3)
    held = vault.held(Writer.key)
    #expect(paths(held) == [".claude/CLAUDE.md", ".claude/skills/ship/SKILL.md"] && names(held) == ["beta"])
    // The laptop, which never had the removed skill, writes a change of its own: the removal stays, the studio's file stays.
    try laptop.put("ship it", at: ".claude/skills/ship/SKILL.md")
    #expect(try await laptop.write(to: vault) == 4)
    held = vault.held(Writer.key)
    #expect(paths(held) == [".claude/CLAUDE.md", ".claude/skills/ship/SKILL.md"] && names(held) == ["beta"] && held["github"] != nil)
    #expect(vault.chunks.count == 2, "chunks no file names any more are gone")

    // Another writer gets in between the read and the write: read again, and both are there.
    try laptop.put("notes", at: ".claude/skills/notes/SKILL.md")
    try studio.put("plan", at: ".claude/skills/plan/SKILL.md")
    vault.lock.withLock { vault.interferes = { Task { try? await laptop.write(to: vault) }; Thread.sleep(forTimeInterval: 0.5) } }
    #expect(try await studio.write(to: vault, github: ("octo", "gho_secret")) == 6)
    #expect(paths(vault.held(Writer.key)) == [".claude/CLAUDE.md", ".claude/skills/notes/SKILL.md", ".claude/skills/plan/SKILL.md", ".claude/skills/ship/SKILL.md"])

    // The server lacks a chunk it was thought to have: said so, uploaded, written.
    try studio.put("more", at: ".claude/skills/more/SKILL.md")
    vault.lock.withLock { vault.lies = 1 }
    #expect(try await studio.write(to: vault, github: ("octo", "gho_secret")) == 7)
    #expect(paths(vault.held(Writer.key)).contains(".claude/skills/more/SKILL.md") && vault.chunks.count == 5)

    // A computer new to a vault that exists, with nothing of its own: it removes nothing.
    let new = try Writer("new")
    defer { try? FileManager.default.removeItem(at: new.home) }
    let before = vault.held(Writer.key)
    #expect(try await new.write(to: vault) == 8)
    #expect(paths(vault.held(Writer.key)) == paths(before) && names(vault.held(Writer.key)) == names(before) && vault.held(Writer.key)["github"] != nil)

    // A server that never takes the write: given up on after three tries, and said.
    try new.put("x", at: ".claude/skills/x/SKILL.md")
    vault.lock.withLock { vault.lies = 99 }
    await #expect(throws: Vault.Failure.self) { try await new.write(to: vault) }
}

@Test func aFileLargerThanAChunkGoesInPiecesAndASealedVaultOfAnotherKeyIsLeftAlone() async throws {
    let vault = FakeVault(), writer = try Writer("studio")
    defer { try? FileManager.default.removeItem(at: writer.home) }
    let large = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
    try FileManager.default.createDirectory(at: writer.home.appendingPathComponent(".claude/skills/big"), withIntermediateDirectories: true)
    try large.write(to: writer.home.appendingPathComponent(".claude/skills/big/data.bin"))
    #expect(try await writer.write(to: vault) == 1)
    let file = try #require((vault.held(Writer.key)["files"] as? [[String: Any]])?.first)
    let ids = try #require(file["chunks"] as? [String])
    #expect(ids.count == 3 && file["size"] as? Int == large.count && file["mode"] as? Int == 0o644)
    // Put back together from what the server holds, each piece named by its plain bytes.
    let pieces = try ids.map { try #require(vault.chunks[$0].flatMap { Vault.open($0, key: Writer.key) }) }
    #expect(pieces.reduce(Data(), +) == large && zip(ids, pieces).allSatisfy { Vault.chunkID($1, key: Writer.key) == $0 })

    let other = try Writer("other")
    defer { try? FileManager.default.removeItem(at: other.home) }
    try other.put("x", at: ".claude/skills/x/SKILL.md")
    let local = Vault.local(home: other.home, key: Data(repeating: 3, count: 32))
    await #expect(throws: Vault.Failure.self) { try await Vault.write(local, key: Data(repeating: 3, count: 32), to: vault.server, state: other.state, by: "other") }
    #expect(vault.version == 1)
}

@Test func aHostGetsServersOfItsOwnAndLeavesOutTheOnesItShouldNot() async throws {
    let host = UUID(), other = UUID()
    var manifest: Vault.Manifest = ["mcp": ["gitlab": ["command": "npx", "args": ["-y", "gitlab-mcp"]], "papers": ["command": "uvx", "args": ["papers"]],
                                            "notes": ["type": "http", "url": "https://notes.example.test"]],
                                    "hosts": [other.uuidString.uppercased(): ["without": ["gitlab"]]]]
    let lacking = ["papers": "uvx"], skipped = ["dokk": "a program built for the Mac"]
    func rows() -> [String: Vault.ServerRow] { Dictionary(Vault.rows(manifest, host: host, lacking: lacking, skipped: skipped).map { ($0.name, $0) }) { $1 } }
    // As the account has it, with what the host said it lacks and what never left the Mac.
    #expect(rows()["gitlab"]?.origin == .account && rows()["gitlab"]?.command == "npx -y gitlab-mcp" && rows()["notes"]?.command == "https://notes.example.test")
    #expect(rows()["papers"]?.lacking == "uvx" && rows()["dokk"]?.origin == .macOnly("a program built for the Mac") && rows().count == 4)

    // Its own command for a name the account has, and for one that only works on the Mac; a server only it gets; one it leaves out.
    Vault.setServer(["command": "/usr/local/bin/dokk", "args": ["mcp"], "env": ["TOKEN": "t"]], named: "dokk", on: host, in: &manifest)
    Vault.setServer(["command": "glab-mcp"], named: "gitlab", on: host, in: &manifest)
    Vault.setServer(["command": "builds"], named: "builds", on: host, in: &manifest)
    Vault.setUsed(false, "notes", on: host, in: &manifest)
    #expect(rows()["dokk"]?.origin == .onlyHere && rows()["dokk"]?.command == "/usr/local/bin/dokk mcp")
    #expect(rows()["gitlab"]?.origin == .ownCommand && rows()["gitlab"]?.command == "glab-mcp" && rows()["builds"]?.origin == .onlyHere)
    #expect(rows()["notes"]?.origin == .unused && rows()["papers"]?.origin == .account)
    let section = try #require((manifest["hosts"] as? [String: Any])?[host.uuidString.lowercased()] as? [String: Any])
    #expect((section["mcp"] as? [String: Any])?.keys.sorted() == ["builds", "dokk", "gitlab"] && section["without"] as? [String] == ["notes"])
    // The other host's section, however its id was spelled, is as it was; and it is found by id, not by spelling.
    #expect(((manifest["hosts"] as? [String: Any])?[other.uuidString.uppercased()] as? [String: Any])?["without"] as? [String] == ["gitlab"])
    #expect(Vault.rows(manifest, host: other).first { $0.name == "gitlab" }?.origin == .unused)
    Vault.setUsed(true, "gitlab", on: other, in: &manifest)
    #expect((manifest["hosts"] as? [String: Any])?.keys.sorted() == [host.uuidString.lowercased()])

    // Each undone: the account's again, and no section left behind.
    Vault.setServer(nil, named: "gitlab", on: host, in: &manifest)
    Vault.setServer(nil, named: "builds", on: host, in: &manifest)
    Vault.setServer(nil, named: "dokk", on: host, in: &manifest)
    Vault.setUsed(true, "notes", on: host, in: &manifest)
    #expect(rows()["gitlab"]?.origin == .account && rows()["builds"] == nil && rows()["notes"]?.origin == .account && manifest["hosts"] == nil)

    // Saved as an edit of what the account holds: another writer's section and servers stay.
    let vault = FakeVault(), writer = try Writer("studio")
    defer { try? FileManager.default.removeItem(at: writer.home) }
    try writer.put(#"{"mcpServers": {"alpha": {"command": "npx"}}}"#, at: ".claude.json")
    try await writer.write(to: vault) { Vault.setUsed(false, "alpha", on: other, in: &$0) }
    #expect(try await writer.write(to: vault) { Vault.setServer(["command": "own"], named: "alpha", on: host, in: &$0) } == 2)
    let hosts = try #require(vault.held(Writer.key)["hosts"] as? [String: Any])
    #expect(hosts.count == 2 && (hosts[other.uuidString.lowercased()] as? [String: Any])?["without"] as? [String] == ["alpha"])
}

@Test func whatAHostSaysOfItsPullBecomesItsRowsNote() throws {
    let line = #"{"version":4,"files":12,"removed":1,"servers":["gitlab","papers"],"lacking":[{"server":"papers","command":"uvx"}],"github":true}"#
    let report = try #require(Vault.Report(Data(("fetching…\n" + line + "\n").utf8)))
    #expect(report.version == 4 && report.files == 12 && report.removed == 1 && report.lacking == ["papers": "uvx"] && report.github)
    let note = report.note(on: "builder", skipped: ["dokk": "a program built for the Mac"])
    #expect(note.contains("12") && note.contains("gitlab") && note.contains(AgentBoard.L("\("papers"): \("uvx") isn't installed on \("builder")")))
    #expect(note.contains("dokk (a program built for the Mac)") && note.contains(AgentBoard.L("GitHub: signed in.")))
    let idle = try #require(Vault.Report(Data(#"{"version":4,"files":0,"removed":0,"servers":[],"lacking":[],"github":false}"#.utf8)))
    #expect(idle.note(on: "builder").hasPrefix(AgentBoard.L("Up to date.")) && idle.note(on: "builder").contains(AgentBoard.L("GitHub: not signed in there.")))
    #expect(Vault.Report(Data(#"{"version":0,"files":0,"removed":0,"servers":[],"lacking":[],"github":false}"#.utf8))?.note(on: "builder") == AgentBoard.L("Nothing is kept in your account yet."))
    #expect(Vault.Report(Data("could not reach the account server".utf8)) == nil)
}

@MainActor @Test func theVaultsKeyIsMadeForAnEmptyAccountAndFetchedFromAHostOtherwise() async throws {
    let stub = StubServer.make { call in call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}") }
    let file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"account":{"login":"octo"}}"#.utf8).write(to: file)
    let account = AccountStore(server: stub.server, session: stub.session, file: file, vault: .memory("secret"))
    // The host's end of a `vault` channel: one line in, one line out.
    final class Host: @unchecked Sendable {
        let lock = NSLock()
        var asked: [String] = []
    }
    let host = Host(), held = Writer.key.base64EncodedString()
    let hosts = HostStores(local: AgentStore(database: file.deletingLastPathComponent().appendingPathComponent("cards.sqlite"), connect: { .failure(.noCore) }),
                           account: account, open: { _, carrying in
        guard case .vault = carrying else { return .failed }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return .failed }
        let theirs = pair[1]
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(theirs, &buffer, buffer.count)
            let request = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
            host.lock.withLock { host.asked.append(request.contains("\"get\"") ? "get" : request.contains("\"set\"") ? "set" : "other") }
            let answer = request.contains("\"get\"") ? "{\"key\":\"\(held)\"}\n" : "{\"ok\":true}\n"
            _ = write(theirs, answer, answer.utf8.count)
            close(theirs)
        }
        return .channel(pair[0])
    })
    let home = try Writer("this Mac"), other = try Writer("studio"), vault = FakeVault()
    defer { [home, other].forEach { try? FileManager.default.removeItem(at: $0.home) } }
    try other.put("theirs", at: ".claude/skills/theirs/SKILL.md")
    try await other.write(to: vault)
    try home.put("mine", at: ".claude/skills/mine/SKILL.md")
    hosts.syncHome = home.home
    hosts.vaultServer = vault.server
    hosts.vaultState = home.state
    let deadline = Date().addingTimeInterval(10)
    while account.hosts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!account.vaultAllowed)

    // A vault exists and this Mac has no key: a host that trusts it gives it; then the host is handed it back before any pull.
    await hosts.syncVault()
    #expect(hosts.vaultKeys.read() == held && account.vaultAllowed, "\(hosts.vaultNote ?? "")")
    #expect(host.lock.withLock { host.asked } == ["get", "set"])
    #expect(paths(vault.held(Writer.key)) == [".claude/skills/mine/SKILL.md", ".claude/skills/theirs/SKILL.md"])
    #expect(hosts.vaultNote == AgentBoard.L("Kept in your account (version \(2))."))
    // Nothing changed: nothing written, and said so.
    await hosts.syncVault()
    #expect(hosts.vaultNote == AgentBoard.L("Up to date.") && vault.version == 2)

    // An account with no vault: this Mac makes the key, and asks no host for one.
    let empty = FakeVault()
    hosts.vaultKeys = .memory()
    hosts.vaultServer = empty.server
    hosts.vaultState = home.home.appendingPathComponent("other.base")
    host.lock.withLock { host.asked = [] }
    await hosts.syncVault()
    let made = try #require(hosts.vaultKeys.read().flatMap { Data(base64Encoded: $0) })
    #expect(made.count == 32 && made != Writer.key && empty.version == 1 && paths(empty.held(made)) == [".claude/skills/mine/SKILL.md"])
    #expect(host.lock.withLock { host.asked } == ["set"])
}
