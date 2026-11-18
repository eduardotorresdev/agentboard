import AgentRuntime
import Foundation
import SQLite3

struct Project: Identifiable, Hashable {
    let id: Int64
    var name: String
    var path: String
}

/// A separate set of projects whose agents sign in to Claude Code on their own (see
/// `OrganizationHome`). Shown as a round avatar: its initial on `color`, or its own image.
struct Organization: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Index into `OrganizationAvatar.palette`.
    var color: Int
    /// An image file the user picked, copied into the organization's folder.
    var icon: String?

    var isDefault: Bool { id == OrganizationHome.defaultID }
}

enum DatabaseError: Error {
    case sqlite(String)
}

/// Thin wrapper over the system SQLite library: projects, worktree names and browsers. The
/// cards and the lines between elements are in the same file, kept by the core (`CardDatabase`).
final class Database {
    private var db: OpaquePointer?

    static func defaultURL() throws -> URL {
        let dir = DataFolder.url
        #if BENCH
        // A bench run once kept its cards in its own database but its media in the user's folder,
        // and a sweep deleted their images: database, data folder and media share one base.
        precondition(ProcessInfo.processInfo.environment["AGENTBOARD_HOME"]?.isEmpty == false,
                     "bench builds need AGENTBOARD_HOME")
        if let url = BenchScenario.database {
            precondition(url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
                         "the bench database must live in AGENTBOARD_HOME")
            return url
        }
        #endif
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agentboard.sqlite")
    }

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw error() }
        // The core has the same file open.
        sqlite3_busy_timeout(db, 3000)
        try execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS organizations (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                color INTEGER NOT NULL,
                icon TEXT
            );
            CREATE TABLE IF NOT EXISTS worktree_aliases (
                path TEXT PRIMARY KEY,
                alias TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS worktree_titles (
                path TEXT PRIMARY KEY,
                title TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS browsers (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                name TEXT NOT NULL,
                device TEXT NOT NULL,
                url TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS browser_profiles (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS file_trees (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                name TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL,
                organization TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS host_pins (
                host TEXT PRIMARY KEY,
                key TEXT NOT NULL,
                sync_allowed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS host_worktrees (
                host TEXT NOT NULL,
                project TEXT NOT NULL,
                path TEXT NOT NULL,
                branch TEXT,
                PRIMARY KEY (host, path)
            );
            CREATE TABLE IF NOT EXISTS templates (
                id TEXT PRIMARY KEY,
                project TEXT NOT NULL,
                data TEXT NOT NULL
            )
            """)
        if try !columns(of: "projects").contains("organization") {
            // A path may now be in several organizations, once in each: rebuild the table
            // without the old uniqueness, with every project in the default organization.
            try execute("""
                BEGIN;
                CREATE TABLE projects_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL,
                    organization TEXT NOT NULL,
                    UNIQUE (organization, path)
                );
                INSERT INTO projects_new (id, name, path, organization)
                    SELECT id, name, path, '\(OrganizationHome.defaultID.uuidString)' FROM projects;
                DROP TABLE projects;
                ALTER TABLE projects_new RENAME TO projects;
                COMMIT;
                """)
        }
        try execute("""
            INSERT OR IGNORE INTO organizations (id, name, color) VALUES ('\(OrganizationHome.defaultID.uuidString)', 'Default', 0)
            """)
        try addColumn("browsers", "profile TEXT")
        // Nullable: rows an older build writes without it load in the default organization.
        try addColumn("browsers", "organization TEXT")
        // The host a card's worktree is on (see docs/hosts.md); null is this Mac.
        try addColumn("browsers", "host TEXT")
        try addColumn("file_trees", "host TEXT")
    }

    /// Adds a column unless it is there. Another process adding it at the same moment (both
    /// saw it missing) is fine; any other failure isn't.
    private func addColumn(_ table: String, _ definition: String) throws {
        let name = String(definition.split(separator: " ")[0])
        guard try !columns(of: table).contains(name) else { return }
        do {
            try execute("ALTER TABLE \(table) ADD COLUMN \(definition)")
        } catch DatabaseError.sqlite(let message) where message.contains("duplicate column name") {}
    }

    private func columns(of table: String) throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var result = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { result.insert(String(cString: sqlite3_column_text(stmt, 1))) }
        return result
    }

    deinit { sqlite3_close(db) }

    func projects(in organization: UUID) throws -> [Project] {
        let stmt = try prepare("SELECT id, name, path FROM projects WHERE organization = ? ORDER BY name COLLATE NOCASE")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, organization.uuidString)
        var result: [Project] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Project(
                id: sqlite3_column_int64(stmt, 0),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2))))
        }
        return result
    }

    func insertProject(name: String, path: String, organization: UUID) throws {
        let stmt = try prepare("INSERT OR IGNORE INTO projects (name, path, organization) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        bind(stmt, 2, path)
        bind(stmt, 3, organization.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteProject(id: Int64) throws {
        let stmt = try prepare("DELETE FROM projects WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func organizations() throws -> [Organization] {
        let stmt = try prepare("SELECT id, name, color, icon FROM organizations ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [Organization] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            result.append(Organization(id: id, name: String(cString: sqlite3_column_text(stmt, 1)),
                                       color: Int(sqlite3_column_int64(stmt, 2)),
                                       icon: sqlite3_column_text(stmt, 3).map { String(cString: $0) }))
        }
        return result
    }

    func saveOrganization(_ organization: Organization) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO organizations (id, name, color, icon) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, organization.id.uuidString)
        bind(stmt, 2, organization.name)
        sqlite3_bind_int64(stmt, 3, Int64(organization.color))
        if let icon = organization.icon { bind(stmt, 4, icon) } else { sqlite3_bind_null(stmt, 4) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    /// Removes the organization and its projects.
    func deleteOrganization(id: UUID) throws {
        for sql in ["DELETE FROM projects WHERE organization = ?", "DELETE FROM organizations WHERE id = ?"] {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
        }
    }

    func aliases() throws -> [String: String] {
        let stmt = try prepare("SELECT path, alias FROM worktree_aliases")
        defer { sqlite3_finalize(stmt) }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return result
    }

    /// Stores `alias` for the worktree at `path`; nil clears it.
    func setAlias(_ alias: String?, path: String) throws {
        let stmt = try prepare(alias == nil
            ? "DELETE FROM worktree_aliases WHERE path = ?"
            : "INSERT OR REPLACE INTO worktree_aliases (path, alias) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        if let alias { bind(stmt, 2, alias) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    /// Titles agents gave worktrees, keyed by worktree path. User-given names live in aliases.
    func worktreeTitles() throws -> [String: String] {
        let stmt = try prepare("SELECT path, title FROM worktree_titles")
        defer { sqlite3_finalize(stmt) }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return result
    }

    /// Drops the user's and agents' titles for the worktree at `path`.
    func forgetWorktreeNames(path: String) throws {
        for table in ["worktree_aliases", "worktree_titles"] {
            let stmt = try prepare("DELETE FROM \(table) WHERE path = ?")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
        }
    }

    /// What other hosts' clones of the projects held when last listed, by host then project
    /// path, in git's order: the clone itself first, then its worktrees. A host that isn't
    /// here has no clone of the project, as far as this Mac knows.
    func hostWorktrees() throws -> [UUID: [String: [Worktree]]] {
        let stmt = try prepare("SELECT host, project, path, branch FROM host_worktrees ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [UUID: [String: [Worktree]]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let host = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            let worktree = Worktree(path: String(cString: sqlite3_column_text(stmt, 2)),
                                    branch: sqlite3_column_text(stmt, 3).map { String(cString: $0) }, host: host)
            result[host, default: [:]][String(cString: sqlite3_column_text(stmt, 1)), default: []].append(worktree)
        }
        return result
    }

    /// Replaces what `host`'s clone of `project` holds; an empty list forgets the clone.
    func setHostWorktrees(_ worktrees: [Worktree], host: UUID, project: String) throws {
        try execute("BEGIN")
        do {
            let clear = try prepare("DELETE FROM host_worktrees WHERE host = ? AND project = ?")
            defer { sqlite3_finalize(clear) }
            bind(clear, 1, host.uuidString)
            bind(clear, 2, project)
            guard sqlite3_step(clear) == SQLITE_DONE else { throw error() }
            for worktree in worktrees {
                let stmt = try prepare("INSERT OR REPLACE INTO host_worktrees (host, project, path, branch) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, host.uuidString)
                bind(stmt, 2, project)
                bind(stmt, 3, worktree.path)
                if let branch = worktree.branch { bind(stmt, 4, branch) } else { sqlite3_bind_null(stmt, 4) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The identity key each host had when this Mac first saw it (or the user accepted since),
    /// whether the user allowed syncing to the host with that key, and whether the host with
    /// that key ever let this Mac in (bits 1 and 2 of `sync_allowed`: no new column for a flag).
    func hostPins() throws -> [UUID: (key: String, syncAllowed: Bool, trustedHere: Bool)] {
        let stmt = try prepare("SELECT host, key, sync_allowed FROM host_pins")
        defer { sqlite3_finalize(stmt) }
        var result: [UUID: (key: String, syncAllowed: Bool, trustedHere: Bool)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let host = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            let flags = sqlite3_column_int(stmt, 2)
            result[host] = (String(cString: sqlite3_column_text(stmt, 1)), flags & 1 != 0, flags & 2 != 0)
        }
        return result
    }

    /// Pins `host` to `key`; a nil key forgets the host.
    func setHostPin(_ key: String?, syncAllowed: Bool = false, trustedHere: Bool = false, host: UUID) throws {
        let stmt = try prepare(key == nil ? "DELETE FROM host_pins WHERE host = ?"
                                          : "INSERT OR REPLACE INTO host_pins (host, key, sync_allowed) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, host.uuidString)
        if let key {
            bind(stmt, 2, key)
            sqlite3_bind_int(stmt, 3, (syncAllowed ? 1 : 0) | (trustedHere ? 2 : 0))
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func setWorktreeTitle(_ title: String, path: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO worktree_titles (path, title) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        bind(stmt, 2, title)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func browsers() throws -> [BrowserRecord] {
        let stmt = try prepare("SELECT id, worktree, name, device, url, x, y, width, height, profile, organization, host FROM browsers ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [BrowserRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            let profile = sqlite3_column_text(stmt, 9).flatMap { UUID(uuidString: String(cString: $0)) }
            result.append(BrowserRecord(
                id: id,
                worktree: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                device: BrowserDevice(stored: String(cString: sqlite3_column_text(stmt, 3))) ?? .desktop,
                url: String(cString: sqlite3_column_text(stmt, 4)),
                frame: CGRect(x: sqlite3_column_double(stmt, 5), y: sqlite3_column_double(stmt, 6),
                              width: sqlite3_column_double(stmt, 7), height: sqlite3_column_double(stmt, 8)),
                profile: profile ?? BrowserProfile.defaultID,
                organization: sqlite3_column_text(stmt, 10).flatMap { UUID(uuidString: String(cString: $0)) } ?? OrganizationHome.defaultID,
                host: sqlite3_column_text(stmt, 11).flatMap { UUID(uuidString: String(cString: $0)) }))
        }
        return result
    }

    func saveBrowser(_ browser: BrowserRecord) throws {
        let stmt = try prepare("""
            INSERT OR REPLACE INTO browsers (id, worktree, name, device, url, x, y, width, height, profile, organization, host) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [browser.id.uuidString, browser.worktree, browser.name, browser.device.stored, browser.url].enumerated() {
            bind(stmt, Int32(index + 1), value)
        }
        for (index, value) in [browser.frame.minX, browser.frame.minY, browser.frame.width, browser.frame.height].enumerated() {
            sqlite3_bind_double(stmt, Int32(index + 6), value)
        }
        bind(stmt, 10, browser.profile.uuidString)
        bind(stmt, 11, browser.organization.uuidString)
        if let host = browser.host { bind(stmt, 12, host.uuidString) } else { sqlite3_bind_null(stmt, 12) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func fileTrees() throws -> [FileTreeRecord] {
        let stmt = try prepare("SELECT id, worktree, name, x, y, width, height, organization, host FROM file_trees ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [FileTreeRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            result.append(FileTreeRecord(
                id: id,
                worktree: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                frame: CGRect(x: sqlite3_column_double(stmt, 3), y: sqlite3_column_double(stmt, 4),
                              width: sqlite3_column_double(stmt, 5), height: sqlite3_column_double(stmt, 6)),
                organization: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 7))) ?? OrganizationHome.defaultID,
                host: sqlite3_column_text(stmt, 8).flatMap { UUID(uuidString: String(cString: $0)) }))
        }
        return result
    }

    func saveFileTree(_ tree: FileTreeRecord) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO file_trees (id, worktree, name, x, y, width, height, organization, host) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, tree.id.uuidString)
        bind(stmt, 2, tree.worktree)
        bind(stmt, 3, tree.name)
        for (index, value) in [tree.frame.minX, tree.frame.minY, tree.frame.width, tree.frame.height].enumerated() {
            sqlite3_bind_double(stmt, Int32(index + 4), value)
        }
        bind(stmt, 8, tree.organization.uuidString)
        if let host = tree.host { bind(stmt, 9, host.uuidString) } else { sqlite3_bind_null(stmt, 9) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteFileTree(id: UUID) throws {
        let stmt = try prepare("DELETE FROM file_trees WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteBrowser(id: UUID) throws {
        let stmt = try prepare("DELETE FROM browsers WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    /// The canvases memorized for the project at `project` (the board's own folder for the
    /// user's board), newest first. One a newer build wrote and this one can't read is skipped.
    func templates(project: String) throws -> [CanvasTemplate] {
        let stmt = try prepare("SELECT data FROM templates WHERE project = ? ORDER BY rowid DESC")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, project)
        var result: [CanvasTemplate] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let template = try? JSONDecoder().decode(CanvasTemplate.self, from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8)) {
                result.append(template)
            }
            step = sqlite3_step(stmt)
        }
        // A read cut short (the database busy) is a failure, not a project without templates.
        guard step == SQLITE_DONE else { throw error() }
        return result
    }

    func saveTemplate(_ template: CanvasTemplate, project: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO templates (id, project, data) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, template.id.uuidString)
        bind(stmt, 2, project)
        bind(stmt, 3, String(decoding: try JSONEncoder().encode(template), as: UTF8.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteTemplate(id: UUID) throws {
        let stmt = try prepare("DELETE FROM templates WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func browserProfiles() throws -> [BrowserProfile] {
        let stmt = try prepare("SELECT id, name FROM browser_profiles ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [BrowserProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            result.append(BrowserProfile(id: id, name: String(cString: sqlite3_column_text(stmt, 1))))
        }
        return result
    }

    func saveBrowserProfile(_ profile: BrowserProfile) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO browser_profiles (id, name) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, profile.id.uuidString)
        bind(stmt, 2, profile.name)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteBrowserProfile(id: UUID) throws {
        let stmt = try prepare("DELETE FROM browser_profiles WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func error() -> DatabaseError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
