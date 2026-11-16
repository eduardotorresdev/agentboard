import Foundation
import SQLite3
import Testing
@testable import AgentBoard
import AgentRuntime

/// Browsers and file trees belong to the organization they were added in; rows without one
/// (from builds before organizations, or written by one now) load in the default organization.
/// Always on a temporary database, never the user's.
struct CardOrganizationTests {
    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("abcards-\(UUID().uuidString).sqlite")
    }

    private func sql(_ url: URL, _ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw DatabaseError.sqlite("open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    @Test func openingTwiceMigratesOnce() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try Database(url: url)
        _ = try Database(url: url)
    }

    /// A database from before organizations: its browser comes through, in the default one.
    @Test func oldRowsLoadInTheDefaultOrganization() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try sql(url, """
            CREATE TABLE browsers (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, name TEXT NOT NULL, device TEXT NOT NULL,
                url TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL);
            INSERT INTO browsers VALUES ('\(UUID().uuidString)', '/w', 'Old', 'desktop', 'about:blank', 0, 0, 100, 100);
            """)
        let browsers = try Database(url: url).browsers()
        #expect(browsers.map(\.name) == ["Old"])
        #expect(browsers.first?.organization == OrganizationHome.defaultID)
    }

    /// An older build writing a row after the migration leaves the column empty: the card stays,
    /// in the default organization, and the other rows keep theirs.
    @Test func anOldBuildsWriteIsNeverLost() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try Database(url: url)
        let other = UUID()
        let id = UUID()
        try sql(url, "INSERT INTO browsers (id, worktree, name, device, url, x, y, width, height, organization) VALUES ('\(UUID().uuidString)', '/w', 'New', 'desktop', 'about:blank', 0, 0, 100, 100, '\(other.uuidString)')")
        try sql(url, "INSERT OR REPLACE INTO browsers (id, worktree, name, device, url, x, y, width, height) VALUES ('\(id.uuidString)', '/w', 'Written by old', 'desktop', 'about:blank', 0, 0, 100, 100)")
        let browsers = try Database(url: url).browsers()
        #expect(browsers.first { $0.id == id }?.organization == OrganizationHome.defaultID)
        #expect(browsers.first { $0.name == "New" }?.organization == other)
    }
}
