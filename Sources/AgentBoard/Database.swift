import Connections
import Foundation
import SQLite3

struct Project: Identifiable, Hashable {
    let id: Int64
    var name: String
    var path: String
}

enum DatabaseError: Error {
    case sqlite(String)
}

/// Thin wrapper over the system SQLite library.
final class Database {
    private var db: OpaquePointer?

    static func defaultURL() throws -> URL {
        #if BENCH
        if let url = BenchScenario.database { return url }
        #endif
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AgentBoard", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agentboard.sqlite")
    }

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw error() }
        try execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS worktree_aliases (
                path TEXT PRIMARY KEY,
                alias TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                kind TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS connections (
                id TEXT PRIMARY KEY,
                a TEXT NOT NULL,
                b TEXT NOT NULL
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
            )
            """)
        if try !columns(of: "browsers").contains("profile") {
            try execute("ALTER TABLE browsers ADD COLUMN profile TEXT")
        }
        if try !columns(of: "agents").contains("name") {
            try execute("ALTER TABLE agents ADD COLUMN name TEXT")
        }
        if try !columns(of: "agents").contains("command") {
            // Runner cards: what they run, where, and the agent that started them.
            try execute("ALTER TABLE agents ADD COLUMN command TEXT; ALTER TABLE agents ADD COLUMN directory TEXT; ALTER TABLE agents ADD COLUMN owner TEXT")
        }
        if try !columns(of: "connections").contains("a_side") {
            try execute("ALTER TABLE connections ADD COLUMN a_side INTEGER; ALTER TABLE connections ADD COLUMN b_side INTEGER")
        }
    }

    private func columns(of table: String) throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var result = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { result.insert(String(cString: sqlite3_column_text(stmt, 1))) }
        return result
    }

    deinit { sqlite3_close(db) }

    func projects() throws -> [Project] {
        let stmt = try prepare("SELECT id, name, path FROM projects ORDER BY name COLLATE NOCASE")
        defer { sqlite3_finalize(stmt) }
        var result: [Project] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Project(
                id: sqlite3_column_int64(stmt, 0),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2))))
        }
        return result
    }

    func insertProject(name: String, path: String) throws {
        let stmt = try prepare("INSERT OR IGNORE INTO projects (name, path) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        bind(stmt, 2, path)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteProject(id: Int64) throws {
        let stmt = try prepare("DELETE FROM projects WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
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

    func agents() throws -> [AgentRecord] {
        let stmt = try prepare("SELECT id, worktree, kind, x, y, width, height, name, command, directory, owner FROM agents ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [AgentRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
                  let providerID = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else { continue }
            let worktree = String(cString: sqlite3_column_text(stmt, 1))
            let runner = sqlite3_column_text(stmt, 8).map { command in
                RunnerSpec(command: String(cString: command),
                           directory: sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? worktree,
                           owner: sqlite3_column_text(stmt, 10).flatMap { UUID(uuidString: String(cString: $0)) })
            }
            result.append(AgentRecord(
                id: id,
                worktree: worktree,
                providerID: providerID,
                name: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
                frame: CGRect(x: sqlite3_column_double(stmt, 3), y: sqlite3_column_double(stmt, 4),
                              width: sqlite3_column_double(stmt, 5), height: sqlite3_column_double(stmt, 6)),
                runner: runner))
        }
        return result
    }

    func saveAgent(_ agent: AgentRecord) throws {
        let stmt = try prepare("""
            INSERT OR REPLACE INTO agents (id, worktree, kind, x, y, width, height, name, command, directory, owner)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, agent.id.uuidString)
        bind(stmt, 2, agent.worktree)
        bind(stmt, 3, agent.providerID)
        for (index, value) in [agent.frame.minX, agent.frame.minY, agent.frame.width, agent.frame.height].enumerated() {
            sqlite3_bind_double(stmt, Int32(index + 4), value)
        }
        bind(stmt, 8, agent.name)
        for (column, value) in [(Int32(9), agent.runner?.command), (10, agent.runner?.directory), (11, agent.runner?.owner?.uuidString)] {
            if let value { bind(stmt, column, value) } else { sqlite3_bind_null(stmt, column) }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteAgent(id: UUID) throws {
        let stmt = try prepare("DELETE FROM agents WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func browsers() throws -> [BrowserRecord] {
        let stmt = try prepare("SELECT id, worktree, name, device, url, x, y, width, height, profile FROM browsers ORDER BY rowid")
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
                profile: profile ?? BrowserProfile.defaultID))
        }
        return result
    }

    func saveBrowser(_ browser: BrowserRecord) throws {
        let stmt = try prepare("""
            INSERT OR REPLACE INTO browsers (id, worktree, name, device, url, x, y, width, height, profile) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [browser.id.uuidString, browser.worktree, browser.name, browser.device.stored, browser.url].enumerated() {
            bind(stmt, Int32(index + 1), value)
        }
        for (index, value) in [browser.frame.minX, browser.frame.minY, browser.frame.width, browser.frame.height].enumerated() {
            sqlite3_bind_double(stmt, Int32(index + 6), value)
        }
        bind(stmt, 10, browser.profile.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deleteBrowser(id: UUID) throws {
        let stmt = try prepare("DELETE FROM browsers WHERE id = ?")
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

    /// Lines between cards, in the order they were drawn.
    func connections() throws -> [Connection] {
        let stmt = try prepare("SELECT id, a, b, a_side, b_side FROM connections ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        func side(_ column: Int32) -> Side? {
            sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : Side(rawValue: Int(sqlite3_column_int(stmt, column)))
        }
        var result: [Connection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ids = (0..<3).map { UUID(uuidString: String(cString: sqlite3_column_text(stmt, $0))) }
            guard let id = ids[0], let a = ids[1], let b = ids[2] else { continue }
            result.append(Connection(id: id, a: a, b: b, aSide: side(3), bSide: side(4)))
        }
        return result
    }

    /// Replaces the stored lines with `connections`, keeping their order.
    func saveConnections(_ connections: [Connection]) throws {
        try execute("BEGIN")
        do {
            try execute("DELETE FROM connections")
            let stmt = try prepare("INSERT INTO connections (id, a, b, a_side, b_side) VALUES (?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(stmt) }
            for connection in connections {
                sqlite3_reset(stmt)
                bind(stmt, 1, connection.id.uuidString)
                bind(stmt, 2, connection.a.uuidString)
                bind(stmt, 3, connection.b.uuidString)
                for (column, side) in [(Int32(4), connection.aSide), (5, connection.bSide)] {
                    if let side { sqlite3_bind_int(stmt, column, Int32(side.rawValue)) } else { sqlite3_bind_null(stmt, column) }
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
