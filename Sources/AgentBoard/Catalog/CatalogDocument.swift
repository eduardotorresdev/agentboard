import Foundation

// The account's catalog (docs/catalog.md): its organizations, projects and the worktrees on each
// host, as the boards keep it in the account server. Foundation only, so a phone app can copy
// this file. Nothing here names how a Mac stores them.

public struct CatalogDocument: Codable, Equatable, Sendable {
    public var organizations: [CatalogOrganization]
    public var projects: [CatalogProject]
    public var worktrees: [CatalogWorktree]

    public init(organizations: [CatalogOrganization] = [], projects: [CatalogProject] = [], worktrees: [CatalogWorktree] = []) {
        self.organizations = organizations
        self.projects = projects
        self.worktrees = worktrees
    }
}

public struct CatalogOrganization: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Index into the board's avatar palette. Avatar images aren't in the catalog yet.
    public var color: Int

    public init(id: UUID, name: String, color: Int) {
        self.id = id
        self.name = name
        self.color = color
    }
}

public struct CatalogProject: Codable, Equatable, Sendable, Identifiable {
    /// Its repository path on the board that added it; how every host's clone is found.
    public var id: String { path }
    public var organization: UUID
    public var name: String
    public var path: String
    /// Its place among its organization's projects in the board's sidebar; nil when unknown.
    public var position: Int?

    public init(organization: UUID, name: String, path: String, position: Int? = nil) {
        self.organization = organization
        self.name = name
        self.path = path
        self.position = position
    }
}

public struct CatalogWorktree: Codable, Equatable, Sendable, Identifiable {
    /// Unique in the catalog: the core it is on, then its path.
    public var id: String { "\(host):\(path)" }
    /// The `CatalogProject.path` it belongs to.
    public var project: String
    /// The core it is on: a host's id (lowercase UUID), or `board:<identity key, base64>` for a
    /// Mac's own folders.
    public var host: String
    public var path: String
    /// Nil on a detached HEAD.
    public var branch: String?
    /// The checkout itself (a Mac's project folder, or a host's clone), not an added worktree.
    public var isMain: Bool
    /// The name the user or an agent gave it (see `WorktreeTitle`); nil when it has none.
    public var title: String?
    /// Its place among its project's worktrees in the board's sidebar; nil when the sidebar doesn't
    /// show it (a host's clone itself).
    public var position: Int?

    public init(project: String, host: String, path: String, branch: String?, isMain: Bool, title: String? = nil, position: Int? = nil) {
        self.project = project
        self.host = host
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.title = title
        self.position = position
    }
}

/// The only place catalog documents become bytes and back: sealing them later (as the vault is)
/// changes these two functions only.
public enum CatalogCodec {
    public static func encode(_ document: CatalogDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> CatalogDocument {
        try JSONDecoder().decode(CatalogDocument.self, from: data)
    }

    /// Three-way merge of a writer's change: `server`'s document, minus what this writer had
    /// (`base`) and no longer has, plus what it has new or changed since `base`. Entries are
    /// matched by id; a change made elsewhere to an entry this writer left alone survives.
    public static func merge(server: CatalogDocument, local: CatalogDocument, base: CatalogDocument) -> CatalogDocument {
        func merged<T: Identifiable & Equatable>(_ server: [T], _ local: [T], _ base: [T]) -> [T] where T.ID: Hashable {
            let here = Dictionary(local.map { ($0.id, $0) }) { first, _ in first }
            let before = Dictionary(base.map { ($0.id, $0) }) { first, _ in first }
            var result = server.filter { before[$0.id] == nil || here[$0.id] != nil }
            for entry in local where before[entry.id] != entry {
                if let index = result.firstIndex(where: { $0.id == entry.id }) { result[index] = entry } else { result.append(entry) }
            }
            return result
        }
        return CatalogDocument(organizations: merged(server.organizations, local.organizations, base.organizations),
                               projects: merged(server.projects, local.projects, base.projects),
                               worktrees: merged(server.worktrees, local.worktrees, base.worktrees))
    }
}
