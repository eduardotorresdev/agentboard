import Foundation
import Testing
@testable import AgentBoard

/// The account server's catalog, in memory: a version and a document, `stale` when behind.
private final class FakeCatalog: @unchecked Sendable {
    let lock = NSLock()
    var version = 0
    var document: Data?
    /// Writes made by "someone else" right before this board's next write, to force `stale`.
    var interleave: [CatalogDocument] = []

    var server: CatalogSync.Server {
        CatalogSync.Server(get: { [self] in
            lock.withLock { document.map { (version, $0) } }
        }, put: { [self] version, data in
            lock.withLock {
                if let other = interleave.popLast() { document = try? CatalogCodec.encode(other); self.version += 1 }
                guard version == self.version else { return nil }
                self.version += 1
                document = data
                return self.version
            }
        })
    }

    var current: CatalogDocument { lock.withLock { document.flatMap { try? CatalogCodec.decode($0) } } ?? CatalogDocument() }
}

private struct Mac {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-catalog-\(UUID().uuidString)")
    let database: Database
    var base: URL { folder.appendingPathComponent("catalog.base") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = try Database(url: folder.appendingPathComponent("db.sqlite"))
    }

    func sync(_ catalog: FakeCatalog, listing: @escaping (String) -> [Worktree]? = { _ in nil }) async throws -> Bool {
        try await CatalogSync.sync(database, board: "board:mac", server: catalog.server, base: base, listing: listing)
    }
}

@Suite struct CatalogSyncTests {
    let organization = UUID()
    let host = UUID()

    @Test func codecRoundTripsADocument() throws {
        let document = CatalogDocument(organizations: [CatalogOrganization(id: organization, name: "Team", color: 2)],
                                       projects: [CatalogProject(organization: organization, name: "app", path: "/p/app")],
                                       worktrees: [CatalogWorktree(project: "/p/app", host: "board:mac", path: "/p/app", branch: nil, isMain: true)])
        #expect(try CatalogCodec.decode(CatalogCodec.encode(document)) == document)
    }

    @Test func mergeKeepsOthersChangesAndAppliesOnlyMine() {
        let a = CatalogProject(organization: organization, name: "a", path: "/a")
        let b = CatalogProject(organization: organization, name: "b", path: "/b")
        let c = CatalogProject(organization: organization, name: "c", path: "/c")
        let renamed = CatalogProject(organization: organization, name: "B!", path: "/b")
        // Here: removed a, kept b, added c. Elsewhere: renamed b, added d.
        let d = CatalogProject(organization: organization, name: "d", path: "/d")
        let merged = CatalogCodec.merge(server: CatalogDocument(projects: [a, renamed, d]),
                                        local: CatalogDocument(projects: [b, c]),
                                        base: CatalogDocument(projects: [a, b]))
        #expect(merged.projects == [renamed, d, c])
    }

    @Test func aMacsProjectsGoUpAndAPhonesComeDown() async throws {
        let mac = try Mac()
        try mac.database.saveOrganization(Organization(id: organization, name: "Team", color: 1))
        try mac.database.insertProject(name: "app", path: "/p/app", organization: organization)
        let catalog = FakeCatalog()
        let listing: (String) -> [Worktree]? = { [Worktree(path: $0, branch: "main", host: nil)] }

        #expect(try await mac.sync(catalog, listing: listing) == false)
        #expect(catalog.version == 1)
        #expect(catalog.current.projects.map(\.path) == ["/p/app"])
        #expect(catalog.current.worktrees.map(\.id) == ["board:mac:/p/app"])

        // A phone adds a project and a worktree on a host, then this Mac syncs.
        var phone = catalog.current
        phone.projects.append(CatalogProject(organization: organization, name: "api", path: "/p/api"))
        phone.worktrees += [CatalogWorktree(project: "/p/api", host: host.uuidString.lowercased(), path: "/h/api", branch: "main", isMain: true),
                            CatalogWorktree(project: "/p/api", host: host.uuidString.lowercased(), path: "/h/api-fix", branch: "fix", isMain: false)]
        catalog.document = try CatalogCodec.encode(phone)
        catalog.version += 1

        #expect(try await mac.sync(catalog, listing: listing) == true)
        #expect(try mac.database.projects(in: organization).map(\.path).sorted() == ["/p/api", "/p/app"])
        #expect(try mac.database.hostWorktrees()[host]?["/p/api"]?.map(\.path) == ["/h/api", "/h/api-fix"])
        // Nothing new on either side: no write.
        let version = catalog.version
        #expect(try await mac.sync(catalog, listing: listing) == false)
        #expect(catalog.version == version)

        // Removed on this Mac: removed from the catalog, the phone's other entries kept.
        try mac.database.deleteProject(id: try #require(mac.database.projects(in: organization).first { $0.path == "/p/app" }).id)
        _ = try await mac.sync(catalog, listing: listing)
        #expect(catalog.current.projects.map(\.path) == ["/p/api"])
        #expect(!catalog.current.worktrees.contains { $0.project == "/p/app" })
    }

    @Test func aStaleWriteIsMergedAgainAndRepeated() async throws {
        let mac = try Mac()
        try mac.database.saveOrganization(Organization(id: organization, name: "Team", color: 1))
        try mac.database.insertProject(name: "app", path: "/p/app", organization: organization)
        let catalog = FakeCatalog()
        let other = CatalogProject(organization: organization, name: "other", path: "/p/other")
        catalog.interleave = [CatalogDocument(organizations: [CatalogOrganization(id: organization, name: "Team", color: 1)], projects: [other])]

        _ = try await mac.sync(catalog)
        #expect(Set(catalog.current.projects.map(\.path)) == ["/p/app", "/p/other"])
        #expect(try mac.database.projects(in: organization).count == 2)
    }

    @Test func anotherBoardsWorktreesAreLeftAlone() async throws {
        let mac = try Mac()
        try mac.database.saveOrganization(Organization(id: organization, name: "Team", color: 1))
        try mac.database.insertProject(name: "app", path: "/p/app", organization: organization)
        let catalog = FakeCatalog()
        let theirs = CatalogWorktree(project: "/p/app", host: "board:other", path: "/o/app", branch: "main", isMain: true)
        catalog.document = try CatalogCodec.encode(CatalogDocument(organizations: [CatalogOrganization(id: organization, name: "Team", color: 1)],
                                                                   projects: [CatalogProject(organization: organization, name: "app", path: "/p/app")],
                                                                   worktrees: [theirs]))
        catalog.version = 1
        _ = try await mac.sync(catalog)
        _ = try await mac.sync(catalog)
        #expect(catalog.current.worktrees == [theirs])
    }
}
