import AppKit
import Foundation
import Testing
@testable import AgentBoard

/// The account server's catalog, in memory: a version and a document, `stale` when behind, and
/// the avatars with a version each.
private final class FakeCatalog: @unchecked Sendable {
    let lock = NSLock()
    var version = 0
    var document: Data?
    /// Writes made by "someone else" right before this board's next write, to force `stale`.
    var interleave: [CatalogDocument] = []
    var avatars: [UUID: (version: Int, image: Data?)] = [:]

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
        }, avatarVersions: { [self] in
            lock.withLock { avatars.mapValues(\.version) }
        }, getAvatar: { [self] id in
            lock.withLock { avatars[id] }
        }, putAvatar: { [self] id, version, image in
            lock.withLock {
                guard (avatars[id]?.version ?? 0) == version else { return nil }
                avatars[id] = (version + 1, image)
                return version + 1
            }
        })
    }

    var current: CatalogDocument { lock.withLock { document.flatMap { try? CatalogCodec.decode($0) } } ?? CatalogDocument() }

    /// What another board does: read, change, write.
    func edit(_ change: (inout CatalogDocument) -> Void) throws {
        var document = current
        change(&document)
        lock.withLock {
            self.document = try? CatalogCodec.encode(document)
            version += 1
        }
    }
}

private let macHost = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

private struct Mac {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-catalog-\(UUID().uuidString)")
    let database: Database

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = try Database(url: folder.appendingPathComponent("db.sqlite"))
    }

    func sync(_ catalog: FakeCatalog, host: String? = macHost, listing: @escaping (String) -> [Worktree]? = { _ in nil }) async throws -> Bool {
        try await CatalogSync.sync(database, macHost: host, server: catalog.server, bases: folder,
                                   avatars: { folder.appendingPathComponent("organizations/\($0.uuidString)") }, listing: listing)
    }
}

@Suite struct CatalogSyncTests {
    let organization = UUID()
    let host = UUID()
    let listing: (String) -> [Worktree]? = { [Worktree(path: $0, branch: "main", host: nil)] }

    private func macWithApp() throws -> Mac {
        let mac = try Mac()
        try mac.database.saveOrganization(Organization(id: organization, name: "Team", color: 1))
        try mac.database.insertProject(name: "app", path: "/p/app", organization: organization)
        return mac
    }

    @Test func codecRoundTripsADocument() throws {
        let document = CatalogDocument(organizations: [CatalogOrganization(id: organization, name: "Team", color: 2)],
                                       projects: [CatalogProject(organization: organization, name: "app", path: "/p/app")],
                                       worktrees: [CatalogWorktree(project: "/p/app", host: macHost, path: "/p/app", branch: nil, isMain: true)])
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

    @Test func theMacsHostIDIsTheRelays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-host-\(UUID().uuidString)")
        #expect(CatalogSync.macHostID(in: folder) == nil)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("host"), withIntermediateDirectories: true)
        try Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","key":"x","name":"mac"}"#.utf8).write(to: folder.appendingPathComponent("host/host.json"))
        #expect(CatalogSync.macHostID(in: folder) == macHost)
    }

    @Test func aMacsProjectsGoUpAndAPhonesComeDown() async throws {
        let mac = try macWithApp()
        let catalog = FakeCatalog()

        #expect(try await mac.sync(catalog, listing: listing) == false)
        #expect(catalog.version == 1)
        #expect(catalog.current.projects.map(\.path) == ["/p/app"])
        #expect(catalog.current.worktrees.map(\.id) == ["\(macHost):/p/app"])

        // A phone adds a project and a worktree on a host, then this Mac syncs.
        try catalog.edit {
            $0.projects.append(CatalogProject(organization: organization, name: "api", path: "/p/api"))
            $0.worktrees += [CatalogWorktree(project: "/p/api", host: host.uuidString.lowercased(), path: "/h/api", branch: "main", isMain: true),
                             CatalogWorktree(project: "/p/api", host: host.uuidString.lowercased(), path: "/h/api-fix", branch: "fix", isMain: false)]
        }
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

    @Test func whatAPhoneRemovedIsNotBroughtBack() async throws {
        let mac = try macWithApp()
        let catalog = FakeCatalog()
        _ = try await mac.sync(catalog, listing: listing)
        try catalog.edit {
            $0.projects.removeAll { $0.path == "/p/app" }
            $0.worktrees.removeAll { $0.project == "/p/app" }
        }
        _ = try await mac.sync(catalog, listing: listing)
        _ = try await mac.sync(catalog, listing: listing)
        #expect(catalog.current.projects.isEmpty)
        #expect(catalog.current.worktrees.isEmpty)
        // The Mac keeps its own copy: an outside removal never deletes here.
        #expect(try mac.database.projects(in: organization).map(\.path) == ["/p/app"])
    }

    @Test func withoutAHostIDTheMacsFoldersStayOut() async throws {
        let mac = try macWithApp()
        let catalog = FakeCatalog()
        _ = try await mac.sync(catalog, host: nil, listing: listing)
        #expect(catalog.current.projects.map(\.path) == ["/p/app"])
        #expect(catalog.current.worktrees.isEmpty)
    }

    @Test func aStaleWriteIsMergedAgainAndRepeated() async throws {
        let mac = try macWithApp()
        let catalog = FakeCatalog()
        let other = CatalogProject(organization: organization, name: "other", path: "/p/other")
        catalog.interleave = [CatalogDocument(organizations: [CatalogOrganization(id: organization, name: "Team", color: 1)], projects: [other])]

        _ = try await mac.sync(catalog)
        #expect(Set(catalog.current.projects.map(\.path)) == ["/p/app", "/p/other"])
        #expect(try mac.database.projects(in: organization).count == 2)
    }

    @Test func anotherBoardsWorktreesAreLeftAlone() async throws {
        let mac = try macWithApp()
        let catalog = FakeCatalog()
        let theirs = CatalogWorktree(project: "/p/app", host: "0d6e5b8c-1111-4a1a-9a9a-000000000001", path: "/o/app", branch: "main", isMain: true)
        try catalog.edit {
            $0.organizations = [CatalogOrganization(id: organization, name: "Team", color: 1)]
            $0.projects = [CatalogProject(organization: organization, name: "app", path: "/p/app")]
            $0.worktrees = [theirs]
        }
        // Even though it comes down into this Mac's database, the Mac doesn't own it.
        _ = try await mac.sync(catalog)
        _ = try await mac.sync(catalog)
        #expect(catalog.current.worktrees == [theirs])
    }

    @Test func avatarsGoUpSmallAndComeDown() async throws {
        let mac = try macWithApp()
        let catalog = FakeCatalog()
        // A big noisy picture: the PNG would pass 64 KiB.
        let side = 1024
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for i in 0..<(bitmap.bytesPerRow * side) { pixels[i] = i % 4 == 3 ? 255 : .random(in: 0...255) }
        let icon = mac.folder.appendingPathComponent("icon.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: icon)
        var organization = try #require(mac.database.organizations().first { $0.id == self.organization })
        organization.icon = icon.path
        try mac.database.saveOrganization(organization)

        _ = try await mac.sync(catalog)
        let sent = try #require(catalog.avatars[self.organization])
        #expect(sent.version == 1)
        let image = try #require(sent.image)
        #expect(image.count <= 64 * 1024)
        #expect(NSBitmapImageRep(data: image)?.pixelsWide == 256)

        // Another board changes it: this Mac takes the new one; unchanged, nothing goes up again.
        catalog.avatars[self.organization] = (2, Data("new".utf8))
        #expect(try await mac.sync(catalog) == true)
        let stored = try #require(mac.database.organizations().first { $0.id == self.organization }?.icon)
        #expect(FileManager.default.contents(atPath: stored) == Data("new".utf8))
        _ = try await mac.sync(catalog)
        #expect(catalog.avatars[self.organization]?.version == 2)

        // Removed elsewhere: removed here.
        catalog.avatars[self.organization] = (3, nil)
        _ = try await mac.sync(catalog)
        #expect(try mac.database.organizations().first { $0.id == self.organization }?.icon == nil)
        #expect(catalog.avatars[self.organization]?.version == 3)
    }
}

/// The relay the app runs as this Mac's host, built by `cargo build -p agentboard` in core/.
private let relayBinary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("core/target/debug/agentboard").path

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: relayBinary), "Build the relay first: cd core && cargo build -p agentboard."))
struct CatalogRelayHostIDTests {
    /// The id `agentboard relay` writes into `host/host.json` is the one the Mac's worktrees go up under.
    @Test func theMacsWorktreesGoUpUnderTheRelaysHostID() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // No server answers: the relay makes its identity, saves it, then fails to sign in and exits.
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: relayBinary)
        relay.arguments = ["relay", "--core", home.appendingPathComponent("no-core.sock").path]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTBOARD_HOME"] = home.path
        environment["AGENTBOARD_SERVER"] = "http://127.0.0.1:9"
        relay.environment = environment
        relay.standardOutput = FileHandle.nullDevice
        relay.standardError = FileHandle.nullDevice
        try relay.run()
        let deadline = Date().addingTimeInterval(30)
        while relay.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if relay.isRunning { relay.terminate() }
        #expect(relay.terminationStatus != 0)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("host/host.json"))) as? [String: Any]
        let relayID = try #require(written?["id"] as? String)
        let id = try #require(CatalogSync.macHostID(in: home))
        #expect(id == relayID.lowercased())

        let mac = try Mac()
        let organization = UUID()
        try mac.database.saveOrganization(Organization(id: organization, name: "Team", color: 1))
        try mac.database.insertProject(name: "app", path: "/p/app", organization: organization)
        let catalog = FakeCatalog()
        _ = try await mac.sync(catalog, host: id) { [Worktree(path: $0, branch: "main", host: nil), Worktree(path: $0 + "-fix", branch: "fix", host: nil)] }
        #expect(catalog.current.worktrees.map(\.host) == [id, id])
        #expect(catalog.current.worktrees.map(\.id) == ["\(id):/p/app", "\(id):/p/app-fix"])
    }
}
