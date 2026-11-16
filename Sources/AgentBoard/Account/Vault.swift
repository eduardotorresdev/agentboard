import AgentRuntime
import CryptoKit
import Foundation

/// The account's vault, a board's side (see "The vault" in docs/hosts.md): what every host
/// should have, sealed with a key the server never sees, written here as a merge into what the
/// server holds and applied by each host with `agentboard vault pull`.
enum Vault {
    /// A manifest as JSON: entries this build doesn't know (another writer's) go through untouched.
    typealias Manifest = [String: Any]

    static let chunkBytes = 1_000_000
    /// Plain bytes to one upload request: under the server's 8 MiB whatever sealing adds.
    static let batchBytes = 6 * 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Sealing

    static func sealingKey(_ key: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), info: Data("agentboard vault v1".utf8), outputByteCount: 32)
    }

    /// What is sealed: a byte saying how the rest is packed (0 as it is, 1 zlib, RFC 1950), then
    /// the bytes, compressed when that makes them smaller ("Small on the wire").
    static func packed(_ plain: Data) -> Data {
        // Apple's "zlib" is the bare deflate stream: the two header bytes and the Adler-32 go around it.
        if let deflated = try? (plain as NSData).compressed(using: .zlib) as Data, deflated.count + 6 < plain.count {
            var one: UInt32 = 1, two: UInt32 = 0
            for byte in plain {
                one = (one + UInt32(byte)) % 65521
                two = (two + one) % 65521
            }
            return Data([1, 0x78, 0x9C]) + deflated + withUnsafeBytes(of: (two << 16 | one).bigEndian) { Data($0) }
        }
        return Data([0]) + plain
    }

    static func unpacked(_ packed: Data) -> Data? {
        switch packed.first {
        case 0: return Data(packed.dropFirst())
        // What is inside was authenticated when it was opened: the checksum adds nothing.
        case 1 where packed.count >= 7: return try? (Data(packed.dropFirst(3).dropLast(4)) as NSData).decompressed(using: .zlib) as Data
        default: return nil
        }
    }

    /// `nonce ‖ ciphertext ‖ tag` of `plain` packed; the nonce is random unless given (tests).
    static func seal(_ plain: Data, key: Data, nonce: Data? = nil) -> Data? {
        let nonce = nonce.flatMap { try? ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce()
        return (try? ChaChaPoly.seal(packed(plain), using: sealingKey(key), nonce: nonce))?.combined
    }

    static func open(_ sealed: Data, key: Data) -> Data? {
        (try? ChaChaPoly.SealedBox(combined: sealed)).flatMap { try? ChaChaPoly.open($0, using: sealingKey(key)) }.flatMap(unpacked)
    }

    /// A chunk's name on the server: the same bytes always have it, and it says nothing without the key.
    static func chunkID(_ plain: Data, key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("agentboard vault blob v1".utf8) + plain, using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func encoded(_ manifest: Manifest) -> Data {
        (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: What this Mac has

    /// This Mac's part of the manifest, where each chunk's bytes are, and the MCP servers left
    /// out with why (see `HostSync.servers`).
    struct Local {
        var manifest: Manifest = [:]
        var chunks: [String: (file: URL, offset: Int, count: Int)] = [:]
        var skipped: [String: String] = [:]

        /// What changing means: the manifest, whatever its keys' order.
        var digest: String { SHA256.hash(data: Vault.encoded(manifest)).map { String(format: "%02x", $0) }.joined() }
    }

    /// The chunk ids found this launch, by file, with the size and date each file had then: a
    /// file is read again only when one of those changed (reading every skill takes seconds).
    private static let read = Read()
    private final class Read: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: (size: Int, changed: Date, key: Data, ids: [String])] = [:]
    }

    static func local(home: URL, key: Data, github: (user: String, token: String)? = nil, git: (name: String, email: String)? = nil) -> Local {
        var local = Local()
        var files: [[String: Any]] = []
        for path in HostSync.files(in: home) {
            let file = home.appendingPathComponent(path).resolvingSymlinksInPath()
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize,
                  let changed = values.contentModificationDate else { continue }
            var ids = read.lock.withLock { read.files[file.path] }.flatMap { $0.size == size && $0.changed == changed && $0.key == key ? $0.ids : nil }
            if ids == nil, let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count == size {
                ids = stride(from: 0, to: size, by: chunkBytes).map { chunkID(data.subdata(in: $0..<min($0 + chunkBytes, size)), key: key) }
                read.lock.withLock { read.files[file.path] = (size, changed, key, ids ?? []) }
            }
            guard let ids else { continue }
            for (index, id) in ids.enumerated() { local.chunks[id] = (file, index * chunkBytes, min(chunkBytes, size - index * chunkBytes)) }
            let mode = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int ?? 0o644) & 0o777
            files.append(["path": path, "mode": mode, "size": size, "chunks": ids])
        }
        local.manifest["files"] = files
        if let config = try? Data(contentsOf: home.appendingPathComponent(".claude.json")) {
            let servers = HostSync.servers(in: config, pinned: true)
            local.manifest["mcp"] = servers.copied
            local.manifest["pins"] = servers.pins
            local.skipped = servers.skipped
        }
        if let github { local.manifest["github"] = ["user": github.user, "token": github.token] }
        if let git { local.manifest["git"] = ["name": git.name, "email": git.email] }
        return local
    }

    // MARK: Merging

    private static func same(_ one: Any?, _ other: Any?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case (let one as NSObject, let other as NSObject): one.isEqual(other)
        default: false
        }
    }

    private static func byPath(_ files: Any?) -> [String: Any] {
        Dictionary((files as? [[String: Any]] ?? []).compactMap { file in (file["path"] as? String).map { ($0, file as Any) } }) { $1 }
    }

    /// `current` (what the server holds, whoever wrote it) with this board's changes since
    /// `base` (its own entries when it last wrote): an entry of `mine` that isn't as `base`
    /// has it is set, one `base` has and `mine` doesn't is removed, every other stays as
    /// `current` has it. Entries: each file, MCP server, pin and host's section, the GitHub
    /// login and the git identity.
    static func merged(current: Manifest, base: Manifest, mine: Manifest) -> Manifest {
        func merge(_ current: [String: Any], _ base: [String: Any], _ mine: [String: Any]) -> [String: Any] {
            var entries = current
            for (name, entry) in mine where !same(entry, base[name]) { entries[name] = entry }
            for name in base.keys where mine[name] == nil { entries[name] = nil }
            return entries
        }
        var result = current
        for section in ["mcp", "pins", "hosts"] {
            let entries = merge(current[section] as? [String: Any] ?? [:], base[section] as? [String: Any] ?? [:], mine[section] as? [String: Any] ?? [:])
            result[section] = entries.isEmpty && section == "hosts" ? nil : entries
        }
        let files = merge(byPath(current["files"]), byPath(base["files"]), byPath(mine["files"]))
        result["files"] = files.keys.sorted().compactMap { files[$0] }
        for single in ["github", "git"] where !same(mine[single], base[single]) { result[single] = mine[single] }
        return result
    }

    // MARK: The server

    /// The account server's vault calls (see the table in docs/hosts.md).
    struct Server: Sendable {
        enum Put: Equatable { case wrote(Int), stale, missing([String]) }
        /// Nil: no vault yet.
        var get: @Sendable () async throws -> (version: Int, manifest: Data)?
        var have: @Sendable ([String]) async throws -> [String]
        /// Several chunks in one request (8 MiB of them at most): each its id and its sealed bytes.
        var putChunks: @Sendable ([(id: String, sealed: Data)]) async throws -> Void
        var put: @Sendable (_ version: Int, _ manifest: Data, _ chunks: [String]) async throws -> Put

        static func http(server: URL, token: String, session: URLSession = .shared) -> Server {
            @Sendable func call(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil) async throws -> (status: Int, reply: [String: Any]) {
                var request = URLRequest(url: server.appendingPathComponent(path))
                request.httpMethod = method
                request.timeoutInterval = 120
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let json {
                    request.httpBody = try JSONSerialization.data(withJSONObject: json)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                } else if let body {
                    request.httpBody = body
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                }
                let (data, response) = try await session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            }
            @Sendable func refused(_ answer: (status: Int, reply: [String: Any])) -> Failure {
                Failure(message: L("The account server refused (\(answer.reply["error"] as? String ?? String(answer.status)))."))
            }
            return Server(get: {
                let answer = try await call("GET", "v1/vault")
                if answer.status == 404 { return nil }
                guard answer.status == 200, let version = answer.reply["version"] as? Int,
                      let manifest = (answer.reply["manifest"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw refused(answer) }
                return (version, manifest)
            }, have: { ids in
                var missing: [String] = []
                for start in stride(from: 0, to: ids.count, by: 5000) {
                    let answer = try await call("POST", "v1/vault/have", json: ["ids": Array(ids[start..<min(start + 5000, ids.count)])])
                    guard answer.status == 200, let lacks = answer.reply["missing"] as? [String] else { throw refused(answer) }
                    missing += lacks
                }
                return missing
            }, putChunks: { chunks in
                var body = Data()
                for chunk in chunks {
                    body += Data(chunk.id.utf8) + withUnsafeBytes(of: UInt32(chunk.sealed.count).bigEndian) { Data($0) } + chunk.sealed
                }
                let answer = try await call("POST", "v1/vault/chunks", body: body)
                guard answer.status == 200 else { throw refused(answer) }
            }, put: { version, manifest, chunks in
                let answer = try await call("PUT", "v1/vault", json: ["version": version, "manifest": manifest.base64EncodedString(), "chunks": chunks])
                if answer.status == 200, let version = answer.reply["version"] as? Int { return .wrote(version) }
                guard answer.status == 409 else { throw refused(answer) }
                return answer.reply["error"] as? String == "missing_chunks" ? .missing(answer.reply["missing"] as? [String] ?? []) : .stale
            })
        }
    }

    // MARK: Writing

    /// What this board remembers of its last write: its own entries then (`base`: what it
    /// compares its home with next time; never another writer's, or their entries would look
    /// removed here), their digest, and the whole manifest as it left it (`whole`). Kept sealed
    /// with the vault's key: it holds the servers' keys and the GitHub login.
    static func state(at file: URL, key: Data) -> (digest: String, base: Manifest, whole: Manifest)? {
        guard let sealed = try? Data(contentsOf: file), let plain = open(sealed, key: key),
              let kept = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let digest = kept["digest"] as? String, let base = kept["base"] as? Manifest else { return nil }
        return (digest, base, kept["whole"] as? Manifest ?? [:])
    }

    private static func keep(digest: String, base: Manifest, whole: Manifest, at file: URL, key: Data) {
        guard let sealed = seal(encoded(["digest": digest, "base": base, "whole": whole]), key: key) else { return }
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: sealed, attributes: [.posixPermissions: 0o600])
    }

    /// Writes this board's changes into the vault: nothing when `local` is what it last wrote
    /// and there is no `edit` (nil comes back), else the server's manifest with the changes
    /// since then applied (`merged`), then `edit` (a host's section, changed in place), its
    /// missing chunks uploaded first. Read again and repeated when another writer got there
    /// first or the server lacks a chunk; given up on after 3 tries.
    static func write(_ local: Local, key: Data, to server: Server, state file: URL, by board: String,
                      edit: (@Sendable (inout Manifest) -> Void)? = nil) async throws -> (version: Int, manifest: Manifest, plainBytes: Int, sentBytes: Int)? {
        let kept = state(at: file, key: key)
        // The hosts' sections are only ever changed through `edit`, on what the server has.
        let mine = local.manifest
        if edit == nil, kept?.digest == local.digest { return nil }
        var sent = (plain: 0, sealed: 0)
        for _ in 0..<3 {
            let held = try await server.get()
            var current: Manifest = [:]
            if let held {
                guard let plain = open(held.manifest, key: key), let read = try? JSONSerialization.jsonObject(with: plain) as? Manifest else {
                    throw Failure(message: L("What your account holds was sealed with another key."))
                }
                current = read
            }
            var target = merged(current: current, base: kept?.base ?? [:], mine: mine)
            edit?(&target)
            target["updated"] = Int(Date().timeIntervalSince1970)
            target["by"] = board
            let ids = Array(Set((target["files"] as? [[String: Any]] ?? []).flatMap { $0["chunks"] as? [String] ?? [] })).sorted()
            // Only what the server lacks travels, many chunks to a request and a few requests at a time.
            let missing = try await server.have(ids).compactMap { id in local.chunks[id].map { (id: id, place: $0) } }
            var batches: [[(id: String, place: (file: URL, offset: Int, count: Int))]] = [[]], room = batchBytes
            for chunk in missing {
                if chunk.place.count + 128 > room, !batches[batches.count - 1].isEmpty {
                    batches.append([])
                    room = batchBytes
                }
                batches[batches.count - 1].append(chunk)
                room -= chunk.place.count + 128
            }
            let counted = try await withThrowingTaskGroup(of: (plain: Int, sealed: Int).self) { group in
                var waiting = batches.filter { !$0.isEmpty }[...], total = (plain: 0, sealed: 0)
                func next() {
                    guard let batch = waiting.popFirst() else { return }
                    group.addTask {
                        var sealed: [(id: String, sealed: Data)] = []
                        for (id, place) in batch {
                            guard let handle = try? FileHandle(forReadingFrom: place.file), (try? handle.seek(toOffset: UInt64(place.offset))) != nil,
                                  let plain = try? handle.read(upToCount: place.count), chunkID(plain, key: key) == id,
                                  let bytes = seal(plain, key: key) else { throw Failure(message: L("\(place.file.lastPathComponent) changed while it was being sent.")) }
                            sealed.append((id, bytes))
                        }
                        try await server.putChunks(sealed)
                        return (batch.reduce(0) { $0 + $1.place.count }, sealed.reduce(0) { $0 + $1.sealed.count })
                    }
                }
                for _ in 0..<3 { next() }
                while let sent = try await group.next() {
                    total = (total.plain + sent.plain, total.sealed + sent.sealed)
                    next()
                }
                return total
            }
            sent = (sent.plain + counted.plain, sent.sealed + counted.sealed)
            guard let sealed = seal(encoded(target), key: key) else { throw Failure(message: L("Couldn't seal it.")) }
            if case .wrote(let version) = try await server.put(held?.version ?? 0, sealed, ids) {
                keep(digest: local.digest, base: mine, whole: target, at: file, key: key)
                return (version, target, sent.plain, sent.sealed + sealed.count)
            }
        }
        throw Failure(message: L("Other computers kept changing it meanwhile. Try again."))
    }

    // MARK: A host's own servers

    private static func section(of host: UUID, in manifest: Manifest) -> (key: String, section: [String: Any]) {
        let hosts = manifest["hosts"] as? [String: Any] ?? [:]
        // Host ids compare as UUIDs, however another writer spelled one.
        let key = hosts.keys.first { UUID(uuidString: $0) == host } ?? host.uuidString.lowercased()
        return (key, hosts[key] as? [String: Any] ?? [:])
    }

    private static func change(_ host: UUID, in manifest: inout Manifest, _ body: (inout [String: Any], inout [String]) -> Void) {
        let (key, old) = section(of: host, in: manifest)
        var section = old, servers = old["mcp"] as? [String: Any] ?? [:], without = old["without"] as? [String] ?? []
        body(&servers, &without)
        section["mcp"] = servers.isEmpty ? nil : servers
        section["without"] = without.isEmpty ? nil : without.sorted()
        var hosts = manifest["hosts"] as? [String: Any] ?? [:]
        hosts[key] = section.isEmpty ? nil : section
        manifest["hosts"] = hosts.isEmpty ? nil : hosts
    }

    /// Gives `host` its own server under `name` (its own version of the account's, when the
    /// account has one by that name); nil takes the host's own away again.
    static func setServer(_ entry: [String: Any]?, named name: String, on host: UUID, in manifest: inout Manifest) {
        change(host, in: &manifest) { servers, without in
            servers[name] = entry
            if entry != nil { without.removeAll { $0 == name } }
        }
    }

    /// Whether `host` uses the account's server `name`.
    static func setUsed(_ used: Bool, _ name: String, on host: UUID, in manifest: inout Manifest) {
        change(host, in: &manifest) { _, without in
            without.removeAll { $0 == name }
            if !used { without.append(name) }
        }
    }

    /// One server in a host's list, and why it is or isn't there.
    struct ServerRow: Equatable, Identifiable {
        enum Origin: Equatable {
            /// The account's, as every host gets it.
            case account
            /// The account's name, with a command of this host's own.
            case ownCommand
            case onlyHere
            /// The account's, left out on this host.
            case unused
            /// On this Mac only: it runs a program that can't go to a host (the reason).
            case macOnly(String)
        }
        var name: String
        var origin: Origin
        /// The command the host would run, when it has the server.
        var command: String
        /// The program the host lacks for it, from its last pull.
        var lacking: String?
        var id: String { name }
    }

    /// What `host` ends with and why, by name. `lacking`: server → program, from the host's
    /// last pull; `skipped`: this Mac's servers that can't go to a host, and why.
    static func rows(_ manifest: Manifest, host: UUID, lacking: [String: String] = [:], skipped: [String: String] = [:]) -> [ServerRow] {
        let account = manifest["mcp"] as? [String: Any] ?? [:], own = section(of: host, in: manifest).section
        let servers = own["mcp"] as? [String: Any] ?? [:], without = Set(own["without"] as? [String] ?? [])
        func command(_ entry: Any?) -> String {
            let entry = entry as? [String: Any] ?? [:]
            return ([entry["command"] as? String ?? entry["url"] as? String ?? ""] + (entry["args"] as? [Any] ?? []).map { "\($0)" }).joined(separator: " ")
        }
        return Set(account.keys).union(servers.keys).union(skipped.keys).sorted().map { name in
            if let entry = servers[name] {
                return ServerRow(name: name, origin: account[name] == nil ? .onlyHere : .ownCommand, command: command(entry), lacking: lacking[name])
            }
            guard let entry = account[name] else { return ServerRow(name: name, origin: .macOnly(skipped[name] ?? ""), command: "") }
            return ServerRow(name: name, origin: without.contains(name) ? .unused : .account, command: command(entry), lacking: without.contains(name) ? nil : lacking[name])
        }
    }

    // MARK: What a host did with it

    /// The line `agentboard vault pull` prints.
    struct Report: Equatable {
        var version = 0, files = 0, removed = 0
        var servers: [String] = []
        /// Servers whose program the host lacks, and the program.
        var lacking: [String: String] = [:]
        var github = false

        init?(_ output: Data) {
            guard let line = String(decoding: output, as: UTF8.self).split(separator: "\n").last,
                  let report = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let version = report["version"] as? Int else { return nil }
            self.version = version
            files = report["files"] as? Int ?? 0
            removed = report["removed"] as? Int ?? 0
            servers = report["servers"] as? [String] ?? []
            for entry in report["lacking"] as? [[String: Any]] ?? [] {
                if let server = entry["server"] as? String { lacking[server] = entry["command"] as? String ?? "" }
            }
            github = report["github"] as? Bool ?? false
        }

        /// For the row of the host called `host`. `skipped`: this Mac's servers that didn't go, and why.
        func note(on host: String, skipped: [String: String] = [:]) -> String {
            guard version > 0 else { return L("Nothing is kept in your account yet.") }
            var parts = [files + removed == 0 ? L("Up to date.") : L("Synced: \(files) files written, \(removed) removed.")]
            let working = servers.filter { lacking[$0] == nil }
            if !working.isEmpty { parts.append(L("Servers: \(working.joined(separator: ", ")).")) }
            if !lacking.isEmpty {
                let each = lacking.sorted { $0.key < $1.key }.map { L("\($0.key): \($0.value) isn't installed on \(host)") }
                parts.append(L("Won't start there: \(each.joined(separator: "; "))."))
            }
            if !skipped.isEmpty {
                // Each reason once, after the servers it is for.
                let byReason = Dictionary(grouping: skipped.keys.sorted()) { skipped[$0] ?? "" }
                parts.append(L("Not copied: \(byReason.sorted { $0.value[0] < $1.value[0] }.map { "\($0.value.joined(separator: ", ")) (\($0.key))" }.joined(separator: "; "))."))
            }
            parts.append(github ? L("GitHub: signed in.") : L("GitHub: not signed in there."))
            return parts.joined(separator: " ")
        }
    }
}
