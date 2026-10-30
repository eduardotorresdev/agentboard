import AgentRuntime
import Connections
import Foundation
import SQLite3

enum CardDatabaseError: Error {
    case sqlite(String)
}

/// The cards and the lines between elements, in the board's SQLite file. Only the core writes
/// these tables; the board keeps the rest of the file (projects, browsers…).
final class CardDatabase {
    private var db: OpaquePointer?

    /// `agentboard.sqlite` in the data folder.
    static var defaultURL: URL { DataFolder.url.appendingPathComponent("agentboard.sqlite") }

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw error() }
        // The board has the same file open.
        sqlite3_busy_timeout(db, 3000)
        try execute("""
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
            CREATE TABLE IF NOT EXISTS postits (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                name TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL,
                text TEXT NOT NULL,
                editor TEXT,
                editor_name TEXT NOT NULL,
                edited REAL
            )
            """)
        try migrateNotesBlocks()
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

    deinit { sqlite3_close(db) }

    private func columns(of table: String) throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var result = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { result.insert(String(cString: sqlite3_column_text(stmt, 1))) }
        return result
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

    /// Post-its, in the order they were added.
    func postIts() throws -> [PostItRecord] {
        let stmt = try prepare("SELECT id, worktree, name, x, y, width, height, text, editor, editor_name, edited FROM postits ORDER BY rowid")
        defer { sqlite3_finalize(stmt) }
        var result: [PostItRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            result.append(PostItRecord(
                id: id,
                worktree: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                frame: CGRect(x: sqlite3_column_double(stmt, 3), y: sqlite3_column_double(stmt, 4),
                              width: sqlite3_column_double(stmt, 5), height: sqlite3_column_double(stmt, 6)),
                text: String(cString: sqlite3_column_text(stmt, 7)),
                editor: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : UUID(uuidString: String(cString: sqlite3_column_text(stmt, 8))),
                editorName: String(cString: sqlite3_column_text(stmt, 9)),
                edited: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))))
        }
        return result
    }

    func savePostIt(_ postIt: PostItRecord) throws {
        let stmt = try prepare("""
            INSERT OR REPLACE INTO postits (id, worktree, name, x, y, width, height, text, editor, editor_name, edited)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, postIt.id.uuidString)
        bind(stmt, 2, postIt.worktree)
        bind(stmt, 3, postIt.name)
        for (index, value) in [postIt.frame.minX, postIt.frame.minY, postIt.frame.width, postIt.frame.height].enumerated() {
            sqlite3_bind_double(stmt, Int32(index + 4), value)
        }
        bind(stmt, 8, postIt.text)
        if let editor = postIt.editor { bind(stmt, 9, editor.uuidString) } else { sqlite3_bind_null(stmt, 9) }
        bind(stmt, 10, postIt.editorName)
        if let edited = postIt.edited { sqlite3_bind_double(stmt, 11, edited.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 11) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func deletePostIt(id: UUID) throws {
        let stmt = try prepare("DELETE FROM postits WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    /// The notes blocks of the build before become post-its with the same ids (so their lines
    /// hold), their notes as a markdown list; their statuses are dropped.
    private func migrateNotesBlocks() throws {
        guard try !columns(of: "notes").isEmpty else { return }
        struct Entry: Decodable {
            let kind: String
            let text: String
        }
        let stmt = try prepare("SELECT id, worktree, name, x, y, width, height, entries FROM notes ORDER BY rowid")
        var blocks: [PostItRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            let entries = (try? JSONDecoder().decode([Entry].self, from: Data(String(cString: sqlite3_column_text(stmt, 7)).utf8))) ?? []
            let text = entries.filter { $0.kind == "note" }.map { "- " + $0.text.replacingOccurrences(of: "\n", with: "\n  ") }
            blocks.append(PostItRecord(
                id: id,
                worktree: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                frame: CGRect(x: sqlite3_column_double(stmt, 3), y: sqlite3_column_double(stmt, 4),
                              width: sqlite3_column_double(stmt, 5), height: sqlite3_column_double(stmt, 6)),
                text: text.joined(separator: "\n")))
        }
        sqlite3_finalize(stmt)
        for block in blocks { try savePostIt(block) }
        try execute("DROP TABLE notes")
    }

    /// Ids of the browser cards the board stored, so lines to them survive loading before any
    /// board has said which elements it has.
    func browserIDs() -> Set<UUID> {
        guard let stmt = try? prepare("SELECT id FROM browsers") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result = Set<UUID>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) { result.insert(id) }
        }
        return result
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
        try execute("BEGIN IMMEDIATE")
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

    private func error() -> CardDatabaseError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
