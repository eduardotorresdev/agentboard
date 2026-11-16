import AgentRuntime
import Foundation

/// Files on another host, through its core's `run` (see docs/hosts.md). Paths go to programs as
/// arguments, never written into a script.
struct HostFiles: Sendable {
    /// Runs a program on the host, feeding it `input`; nil when the host can't be reached.
    let run: @Sendable (_ executable: String, _ arguments: [String], _ input: Data?) async -> CoreClient.Ran?

    /// The folder's entries, hidden ones too, and whether each is a folder (links followed, as
    /// on this Mac); nil when it can't be listed. One program per folder, however many entries.
    func list(_ folder: String) async -> [(name: String, isFolder: Bool)]? {
        // -p ends a folder's name with a slash. A dangling link fails ls but still lists the rest.
        guard let ran = await run("ls", ["-1ApL", "--", folder], nil), ran.status == 0 || !ran.output.isEmpty else { return nil }
        // shortcut: a name with a line break in it reads as two entries; list with `find -print0` if that ever matters.
        return String(decoding: ran.output, as: UTF8.self).split(separator: "\n").map {
            $0.hasSuffix("/") ? (String($0.dropLast()), true) : (String($0), false)
        }
    }

    /// The file's first `limit` + 1 bytes at most, as they are: more than `limit` back means the
    /// file is larger. Nil when it can't be read.
    func read(_ path: String, limit: Int) async -> Data? {
        guard let ran = await run("head", ["-c", String(limit + 1), "--", path], nil), ran.status == 0 else { return nil }
        return ran.output
    }

    func isFolder(_ path: String) async -> Bool {
        await run("test", ["-d", path], nil)?.status == 0
    }

    /// Writes `data` to `path`, making its folder first.
    func write(_ data: Data, to path: String) async -> Bool {
        await run("sh", ["-c", "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"", "sh", path], data)?.status == 0
    }

    /// What a program printed, when it succeeded.
    func output(_ executable: String, _ arguments: [String]) async -> String? {
        guard let ran = await run(executable, arguments, nil), ran.status == 0 else { return nil }
        return String(decoding: ran.output, as: UTF8.self)
    }
}
