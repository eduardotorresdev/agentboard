import BenchKit
import Foundation
import SQLite3

/// One launch of the app for a scenario: a temporary directory with the database, a repository
/// with two worktrees (the agents live in the first, the second stays empty), and a fake login
/// shell whose PATH resolves `claude` to FakeAgent. Nothing of the user's is read or written.
final class AppRun {
    let pid: pid_t
    private let process: Process
    private let directory: URL

    init(_ scenario: Scenario) throws {
        let app = try Self.build()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let repo = directory.appendingPathComponent("repo"), other = directory.appendingPathComponent("other")
        try Self.run("/usr/bin/git", ["init", "-q", repo.path])
        try Self.run("/usr/bin/git", ["-C", repo.path, "-c", "user.name=bench", "-c", "user.email=bench@localhost",
                                      "commit", "-q", "--allow-empty", "-m", "init"])
        try Self.run("/usr/bin/git", ["-C", repo.path, "worktree", "add", "-q", other.path, "-b", "other"])
        // Paths as git reports them (/private/var/…, which Foundation's resolvingSymlinksInPath
        // turns back into /var/…), since that is how the app matches worktrees.
        let main = try Self.realPath(repo), empty = try Self.realPath(other)

        let database = directory.appendingPathComponent("bench.sqlite")
        try Self.seed(database, project: main)

        // `claude` takes the first free slot; past `working`, an agent waits at its start screen.
        let bin = directory.appendingPathComponent("bin"), slots = directory.appendingPathComponent("slots")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: slots, withIntermediateDirectories: true)
        try Self.script(bin.appendingPathComponent("claude"), """
            #!/bin/sh
            seed=$(printf %s "$*" | cksum | cut -d" " -f1)
            i=0; while ! mkdir "\(slots.path)/$i" 2>/dev/null; do i=$((i+1)); done
            mode=\(scenario.mode); [ "$i" -ge \(scenario.working) ] && mode=idle
            exec "\(FakeAgent.path)" --mode "$mode" --seed "$seed"
            """)
        // The app reads PATH from the login shell's output.
        let shell = directory.appendingPathComponent("shell")
        try Self.script(shell, "#!/bin/sh\nprintf '\\n%s' '\(bin.path):/usr/bin:/bin'\n")

        process = Process()
        process.executableURL = app
        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = shell.path
        environment["AGENTBOARD_BENCH_DB"] = database.path
        environment["AGENTBOARD_BENCH_WORKTREE"] = main
        environment["AGENTBOARD_BENCH_BACKGROUND"] = "1"
        if scenario.focusPrinting { environment["AGENTBOARD_BENCH_FOCUS"] = "printing" }
        if let after = scenario.switchAfter {
            environment["AGENTBOARD_BENCH_SWITCH_TO"] = empty
            environment["AGENTBOARD_BENCH_SWITCH_AFTER"] = String(after)
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        pid = process.processIdentifier
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        // The agents are the app's children's children: make sure none outlives the run.
        try? Self.run("/usr/bin/pkill", ["-f", FakeAgent.path], allowFailure: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The app's release build with `-DBENCH`, built once per suite run in its own build
    /// directory; the user's builds are untouched.
    private static func build() throws -> URL {
        if let built { return built }
        let root = Corpus.directory.deletingLastPathComponent().deletingLastPathComponent()
        let scratch = root.appendingPathComponent(".build/bench")
        try run("/usr/bin/env", ["swift", "build", "-c", "release", "--package-path", root.path,
                                 "--scratch-path", scratch.path, "--product", "AgentBoard", "-Xswiftc", "-DBENCH"])
        let app = scratch.appendingPathComponent("release/AgentBoard")
        built = app
        return app
    }

    private static var built: URL?

    /// One project and ten cards in a 5x2 grid, through the same tables the app creates.
    private static func seed(_ url: URL, project: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure("can't open \(url.path)") }
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE projects (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE);
            CREATE TABLE agents (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, kind TEXT NOT NULL,
                                 x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL);
            INSERT INTO projects (name, path) VALUES ('bench', '\(project)');
            """
        for card in 0..<10 {
            sql += "INSERT INTO agents VALUES ('\(UUID().uuidString)', '\(project)', 'claude', "
                + "\(8 + (card % 5) * 292), \(60 + (card / 5) * 356), 286, 350);"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(String(cString: sqlite3_errmsg(db))) }
    }

    private static func realPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw Failure("can't resolve \(url.path)") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func script(_ url: URL, _ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else {
            throw Failure("\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
