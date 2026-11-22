import AgentRuntime
import AppKit
import CryptoKit
import Foundation

/// Keeps this Mac's projects database and the account's catalog (docs/catalog.md) the same,
/// both ways: what this Mac has new goes up, what another board (a phone) added comes down.
enum CatalogSync {
    /// The account server's catalog calls.
    struct Server: Sendable {
        /// Nil: no catalog yet.
        var get: @Sendable () async throws -> (version: Int, document: Data)?
        /// The new version, or nil when `version` wasn't the current one (`stale`).
        var put: @Sendable (_ version: Int, _ document: Data) async throws -> Int?
        /// Every organization's avatar version.
        var avatarVersions: @Sendable () async throws -> [UUID: Int]
        /// One avatar's version and image (nil: removed); nil when it never had one.
        var getAvatar: @Sendable (UUID) async throws -> (version: Int, image: Data?)?
        /// Sets (nil: removes) one avatar; the new version, or nil on `stale`.
        var putAvatar: @Sendable (_ organization: UUID, _ version: Int, _ image: Data?) async throws -> Int?

        static func http(server: URL, token: String, session: URLSession = .shared) -> Server {
            @Sendable func call(_ method: String, _ path: String, _ json: [String: Any]? = nil) async throws -> (status: Int, reply: Any?) {
                var request = URLRequest(url: server.appendingPathComponent(path))
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let json {
                    request.httpBody = try JSONSerialization.data(withJSONObject: json)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let (data, response) = try await session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
            }
            @Sendable func refused(_ answer: (status: Int, reply: Any?)) -> GitError {
                GitError(message: "The account server refused the catalog (\((answer.reply as? [String: Any])?["error"] as? String ?? String(answer.status))).")
            }
            @Sendable func avatar(_ organization: UUID) -> String { "v1/catalog/avatars/\(organization.uuidString.lowercased())" }
            return Server(get: {
                let answer = try await call("GET", "v1/catalog")
                if answer.status == 404 { return nil }
                let reply = answer.reply as? [String: Any]
                guard answer.status == 200, let version = reply?["version"] as? Int,
                      let document = (reply?["document"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw refused(answer) }
                return (version, document)
            }, put: { version, document in
                let answer = try await call("PUT", "v1/catalog", ["version": version, "document": document.base64EncodedString()])
                if answer.status == 200, let version = (answer.reply as? [String: Any])?["version"] as? Int { return version }
                guard answer.status == 409 else { throw refused(answer) }
                return nil
            }, avatarVersions: {
                let answer = try await call("GET", "v1/catalog/avatars")
                guard answer.status == 200, let rows = answer.reply as? [[String: Any]] else { throw refused(answer) }
                return rows.reduce(into: [:]) { result, row in
                    if let id = (row["organization"] as? String).flatMap(UUID.init), let version = row["version"] as? Int { result[id] = version }
                }
            }, getAvatar: { organization in
                let answer = try await call("GET", avatar(organization))
                if answer.status == 404 { return nil }
                let reply = answer.reply as? [String: Any]
                guard answer.status == 200, let version = reply?["version"] as? Int else { throw refused(answer) }
                return (version, (reply?["image"] as? String).flatMap { Data(base64Encoded: $0) })
            }, putAvatar: { organization, version, image in
                let answer = try await call("PUT", avatar(organization), ["version": version, "image": image?.base64EncodedString() ?? NSNull()])
                if answer.status == 200, let version = (answer.reply as? [String: Any])?["version"] as? Int { return version }
                guard answer.status == 409 else { throw refused(answer) }
                return nil
            })
        }
    }

    /// How often the app syncs while signed in: what a phone adds shows within this.
    static let interval: Duration = .seconds(30)

    /// This Mac's id as a host of the account: the one `agentboard relay` keeps in
    /// `host/host.json` in the data folder and registers in `/v1/hosts` (docs/hosts.md), so the
    /// phone reaches the Mac's worktrees by the same id. Nil until the relay first ran.
    static func macHostID(in dataFolder: URL) -> String? {
        guard let data = try? Data(contentsOf: dataFolder.appendingPathComponent("host/host.json")),
              let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String,
              UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }

    /// Syncs the app's database while it runs, whenever signed in (the bases live next to the
    /// database), and shows in the sidebar what came down.
    @MainActor
    static func keep(_ projects: ProjectStore, account: AccountStore) {
        Task { @MainActor in
            while true {
                if let token = account.token, let url = try? Database.defaultURL() {
                    let server = Server.http(server: account.server, token: token)
                    let folder = url.deletingLastPathComponent()
                    let changed = await Task.detached {
                        guard let database = try? Database(url: url) else { return false }
                        do {
                            return try await sync(database, macHost: macHostID(in: DataFolder.url), server: server, bases: folder,
                                                  avatars: OrganizationHome.folder) { Git.worktrees(at: $0) }
                        } catch {
                            NSLog("Catalog sync failed: \(error.localizedDescription)")
                            return false
                        }
                    }.value
                    if changed { projects.reload() }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The catalog as `database` holds it: every organization, project and known host worktree,
    /// and this Mac's own worktrees (`listing`, git's list of a repository) under `macHost`
    /// (none without it: no phone can reach them yet).
    static func local(_ database: Database, macHost: String?, listing: (String) -> [Worktree]?) throws -> CatalogDocument {
        let organizations = try database.organizations()
        let projects = try organizations.flatMap { organization in
            try database.projects(in: organization.id).map { CatalogProject(organization: organization.id, name: $0.name, path: $0.path) }
        }
        var worktrees: [CatalogWorktree] = []
        if let macHost {
            for project in projects {
                worktrees += (listing(project.path) ?? []).enumerated().map {
                    CatalogWorktree(project: project.path, host: macHost, path: $1.path, branch: $1.branch, isMain: $0 == 0)
                }
            }
        }
        for (host, byProject) in try database.hostWorktrees() where host.uuidString.lowercased() != macHost {
            for (project, list) in byProject where projects.contains(where: { $0.path == project }) {
                worktrees += list.enumerated().map {
                    CatalogWorktree(project: project, host: host.uuidString.lowercased(), path: $1.path, branch: $1.branch, isMain: $0 == 0)
                }
            }
        }
        return CatalogDocument(organizations: organizations.map { CatalogOrganization(id: $0.id, name: $0.name, color: $0.color) },
                               projects: projects, worktrees: worktrees)
    }

    /// Adds to `database` what `document` has and it lacks: organizations, projects (of a known
    /// organization) and other hosts' worktrees (of a known project). Removals elsewhere aren't
    /// applied here: forgetting a project is the user's call on this Mac. Returns whether anything changed.
    static func apply(_ document: CatalogDocument, to database: Database, local: CatalogDocument, macHost: String?) throws -> Bool {
        var changed = false
        let known = Set(local.organizations.map(\.id))
        for organization in document.organizations where !known.contains(organization.id) {
            try database.saveOrganization(Organization(id: organization.id, name: organization.name, color: organization.color))
            changed = true
        }
        let organizations = known.union(document.organizations.map(\.id))
        let projects = Set(local.projects.map(\.path))
        for project in document.projects where !projects.contains(project.path) && organizations.contains(project.organization) {
            try database.insertProject(name: project.name, path: project.path, organization: project.organization)
            changed = true
        }
        let allProjects = projects.union(document.projects.filter { organizations.contains($0.organization) }.map(\.path))
        let had = Set(local.worktrees.map(\.id))
        let existing = try database.hostWorktrees()
        // This Mac's own worktrees come from git here, never from the catalog.
        let arrived = document.worktrees.filter {
            !had.contains($0.id) && $0.host != macHost && allProjects.contains($0.project) && UUID(uuidString: $0.host) != nil
        }
        for (key, list) in Dictionary(grouping: arrived, by: { [$0.host, $0.project] }) {
            guard let host = UUID(uuidString: key[0]) else { continue }
            let kept = existing[host]?[key[1]] ?? []
            // The clone first: a host's list starts with it.
            let added = list.map { Worktree(path: $0.path, branch: $0.branch, host: host) }
            let clone = kept.isEmpty ? list.filter(\.isMain).map(\.path) : []
            try database.setHostWorktrees(kept + added.filter { clone.contains($0.path) } + added.filter { !clone.contains($0.path) }, host: host, project: key[1])
            changed = true
        }
        return changed
    }

    /// One round: reads the server's catalog, merges this Mac's changes since its last round
    /// (the base, `catalog.base` in `bases`) into it, writes it back when that changes it (again
    /// from the read on `stale`), adds to `database` what others added, then does the same for
    /// avatars (`avatars`: an organization's folder). Returns whether `database` changed.
    @discardableResult
    static func sync(_ database: Database, macHost: String?, server: Server, bases: URL, avatars: @escaping (UUID) -> URL,
                     listing: @escaping (String) -> [Worktree]?) async throws -> Bool {
        let file = bases.appendingPathComponent("catalog.base")
        let base = (try? Data(contentsOf: file)).flatMap { try? CatalogCodec.decode($0) } ?? CatalogDocument()
        let local = try Self.local(database, macHost: macHost, listing: listing)
        var changed: Bool?
        for _ in 0..<5 where changed == nil {
            let read = try await server.get()
            let current = try read.map { try CatalogCodec.decode($0.document) } ?? CatalogDocument()
            let merged = CatalogCodec.merge(server: current, local: local, base: base)
            if merged != current || read == nil {
                guard try await server.put(read?.version ?? 0, CatalogCodec.encode(merged)) != nil else { continue }
            }
            changed = try apply(merged, to: database, local: local, macHost: macHost)
            // What this Mac holds now is what the next round compares with: never another
            // board's entries it doesn't keep, or they would look removed here.
            keep(try CatalogCodec.encode(changed == true ? Self.local(database, macHost: macHost, listing: listing) : local), at: file)
        }
        guard let changed else { throw GitError(message: "The catalog kept changing on the account server; try again.") }
        let pulled = try await syncAvatars(database, server: server, base: bases.appendingPathComponent("catalog-avatars.base"), folder: avatars)
        return changed || pulled
    }

    private static func keep(_ data: Data, at file: URL) {
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: Avatars

    /// What an avatar was at the last round: its server version and the digest of the icon
    /// file this Mac had then (empty: none).
    struct AvatarBase: Codable, Equatable {
        var version: Int
        var digest: String
    }

    /// An organization's icon as the catalog carries it: square, 256 px, at most 64 KiB (PNG, or
    /// JPEG when the PNG is bigger); nil when it can't be made that small.
    static func avatarImage(fileAt path: String) -> Data? {
        guard let png = NSImage(contentsOfFile: path)?.squarePNG(side: 128) else { return nil }
        if png.count <= 64 * 1024 { return png }
        for quality in [0.8, 0.6, 0.4] {
            if let jpeg = NSBitmapImageRep(data: png)?.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= 64 * 1024 {
                return jpeg
            }
        }
        return nil
    }

    private static func fileDigest(ofFileAt path: String?) -> String {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sends up the icons changed here since the last round and brings down the ones changed
    /// elsewhere (written into the organization's folder). Returns whether `database` changed.
    static func syncAvatars(_ database: Database, server: Server, base file: URL, folder: (UUID) -> URL) async throws -> Bool {
        var bases = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([UUID: AvatarBase].self, from: $0) } ?? [:]
        var versions = try await server.avatarVersions()
        var changed = false
        for var organization in try database.organizations() {
            let before = bases[organization.id] ?? AvatarBase(version: 0, digest: "")
            let digest = fileDigest(ofFileAt: organization.icon)
            let remote = versions[organization.id] ?? 0
            if digest != before.digest {
                let image = organization.icon.flatMap(avatarImage(fileAt:))
                var version = remote
                for _ in 0..<3 {
                    if let written = try await server.putAvatar(organization.id, version, image) { version = written; break }
                    version = try await server.avatarVersions()[organization.id] ?? 0
                }
                versions[organization.id] = version
                bases[organization.id] = AvatarBase(version: version, digest: digest)
            } else if remote > before.version, let fetched = try await server.getAvatar(organization.id) {
                let old = organization.icon
                if let image = fetched.image {
                    let place = folder(organization.id)
                    let icon = place.appendingPathComponent("icon-\(UUID().uuidString.prefix(8)).png")
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    try image.write(to: icon)
                    organization.icon = icon.path
                } else {
                    organization.icon = nil
                }
                try database.saveOrganization(organization)
                if let old { try? FileManager.default.removeItem(atPath: old) }
                bases[organization.id] = AvatarBase(version: fetched.version, digest: fileDigest(ofFileAt: organization.icon))
                changed = true
            }
        }
        keep(try JSONEncoder().encode(bases), at: file)
        return changed
    }
}
