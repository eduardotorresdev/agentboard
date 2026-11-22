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

        static func http(server: URL, token: String, session: URLSession = .shared) -> Server {
            @Sendable func call(_ method: String, _ json: [String: Any]? = nil) async throws -> (status: Int, reply: [String: Any]) {
                var request = URLRequest(url: server.appendingPathComponent("v1/catalog"))
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let json {
                    request.httpBody = try JSONSerialization.data(withJSONObject: json)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let (data, response) = try await session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            }
            @Sendable func refused(_ answer: (status: Int, reply: [String: Any])) -> GitError {
                GitError(message: "The account server refused the catalog (\(answer.reply["error"] as? String ?? String(answer.status))).")
            }
            return Server(get: {
                let answer = try await call("GET")
                if answer.status == 404 { return nil }
                guard answer.status == 200, let version = answer.reply["version"] as? Int,
                      let document = (answer.reply["document"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw refused(answer) }
                return (version, document)
            }, put: { version, document in
                let answer = try await call("PUT", ["version": version, "document": document.base64EncodedString()])
                if answer.status == 200, let version = answer.reply["version"] as? Int { return version }
                guard answer.status == 409 else { throw refused(answer) }
                return nil
            })
        }
    }

    /// How often the app syncs while signed in: what a phone adds shows within this.
    static let interval: Duration = .seconds(30)

    /// Syncs the app's database while it runs, whenever signed in (the base lives next to the
    /// database), and shows in the sidebar what came down.
    @MainActor
    static func keep(_ projects: ProjectStore, account: AccountStore) {
        Task { @MainActor in
            while true {
                if let token = account.token, let board = account.boardPublicKey, let url = try? Database.defaultURL() {
                    let server = Server.http(server: account.server, token: token)
                    let base = url.deletingLastPathComponent().appendingPathComponent("catalog.base")
                    let changed = await Task.detached {
                        guard let database = try? Database(url: url) else { return false }
                        do {
                            return try await sync(database, board: "board:" + board, server: server, base: base) { Git.worktrees(at: $0) }
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
    /// and this Mac's own worktrees (`listing`, git's list of a repository) under `board`.
    static func local(_ database: Database, board: String, listing: (String) -> [Worktree]?) throws -> CatalogDocument {
        let organizations = try database.organizations()
        let projects = try organizations.flatMap { organization in
            try database.projects(in: organization.id).map { CatalogProject(organization: organization.id, name: $0.name, path: $0.path) }
        }
        var worktrees: [CatalogWorktree] = []
        for project in projects {
            worktrees += (listing(project.path) ?? []).enumerated().map {
                CatalogWorktree(project: project.path, host: board, path: $1.path, branch: $1.branch, isMain: $0 == 0)
            }
        }
        for (host, byProject) in try database.hostWorktrees() {
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
    /// organization) and hosts' worktrees (of a known project). Removals elsewhere aren't
    /// applied here: forgetting a project is the user's call on this Mac. Returns whether anything changed.
    static func apply(_ document: CatalogDocument, to database: Database, local: CatalogDocument) throws -> Bool {
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
        let arrived = document.worktrees.filter { !had.contains($0.id) && allProjects.contains($0.project) && UUID(uuidString: $0.host) != nil }
        for (key, list) in Dictionary(grouping: arrived, by: { [$0.host, $0.project] }) {
            guard let host = UUID(uuidString: key[0]) else { continue }
            let kept = existing[host]?[key[1]] ?? []
            // The clone first: a host's list starts with it.
            let added = list.map { Worktree(path: $0.path, branch: $0.branch, host: host) }
            let clone = kept.isEmpty ? list.filter(\.isMain).map(\.path) : []
            let all = kept + added.filter { clone.contains($0.path) } + added.filter { !clone.contains($0.path) }
            try database.setHostWorktrees(all, host: host, project: key[1])
            changed = true
        }
        return changed
    }

    /// One round: reads the server's catalog, merges this Mac's changes since its last round
    /// (`base`, kept in that file) into it, writes it back when that changes it (again from the
    /// read on `stale`), and adds to `database` what others added. Returns whether `database` changed.
    @discardableResult
    static func sync(_ database: Database, board: String, server: Server, base file: URL, listing: @escaping (String) -> [Worktree]?) async throws -> Bool {
        let base = (try? Data(contentsOf: file)).flatMap { try? CatalogCodec.decode($0) } ?? CatalogDocument()
        let local = try Self.local(database, board: board, listing: listing)
        for _ in 0..<5 {
            let read = try await server.get()
            let current = try read.map { try CatalogCodec.decode($0.document) } ?? CatalogDocument()
            let merged = CatalogCodec.merge(server: current, local: local, base: base)
            if merged != current || read == nil {
                guard try await server.put(read?.version ?? 0, CatalogCodec.encode(merged)) != nil else { continue }
            }
            let changed = try apply(merged, to: database, local: local)
            // What this Mac holds now is what the next round compares with: never another
            // board's entries it doesn't keep, or they would look removed here.
            let kept = changed ? try Self.local(database, board: board, listing: listing) : local
            try? FileManager.default.removeItem(at: file)
            FileManager.default.createFile(atPath: file.path, contents: try CatalogCodec.encode(kept), attributes: [.posixPermissions: 0o600])
            return changed
        }
        throw GitError(message: "The catalog kept changing on the account server; try again.")
    }
}
