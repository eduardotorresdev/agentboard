import AgentRuntime
import Foundation

/// Answers true once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// Files on another host, through its core's `run` (see docs/hosts.md). Paths go to programs as
/// arguments, never written into a script.
struct HostFiles: Sendable {
    /// Runs a program on the host, feeding it `input`; nil when the host can't be reached.
    let run: @Sendable (_ executable: String, _ arguments: [String], _ input: Data?) async -> CoreClient.Ran?
    /// The same, said how: `bulk` keeps it off the connection keys and screens travel on (what
    /// sends more than `bulkBytes` goes there anyway), and it is waited for `patience` seconds
    /// (nil: `patience(sending:)`). Without one (tests), `run` as it is.
    var carry: (@Sendable (_ executable: String, _ arguments: [String], _ input: Data?, _ bulk: Bool, _ patience: Double?) async -> CoreClient.Ran?)?

    /// Past this, bytes travel on a connection of their own.
    static let bulkBytes = 256 * 1024

    /// How long a program on a host is waited for, by what it is sent (or is to send back):
    /// 30 seconds and one more for every 50 KB, never past `GitHost.patience`.
    static func patience(sending bytes: Int) -> Double { min(30 + Double(bytes) / 50_000, GitHost.patience) }

    /// What a call that wasn't answered in time gives: as a program that failed, saying so.
    static var unanswered: CoreClient.Ran { CoreClient.Ran(status: 124, error: Data(L("The host didn't answer in time.").utf8)) }

    /// `work`'s result, or nil when it takes longer than `seconds` (it is then left to end by itself).
    static func within<Value: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> Value) async -> Value? {
        let once = Once()
        return await withCheckedContinuation { (answer: CheckedContinuation<Value?, Never>) in
            Task {
                let value = await work()
                if once.take() { answer.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.take() { answer.resume(returning: nil) }
            }
        }
    }

    func carried(_ executable: String, _ arguments: [String], _ input: Data? = nil, bulk: Bool = false, patience: Double? = nil) async -> CoreClient.Ran? {
        guard let carry else { return await run(executable, arguments, input) }
        return await carry(executable, arguments, input, bulk, patience)
    }

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
        guard let ran = await carried("head", ["-c", String(limit + 1), "--", path], bulk: limit > Self.bulkBytes, patience: Self.patience(sending: limit)),
              ran.status == 0 else { return nil }
        return ran.output
    }

    func exists(_ path: String) async -> Bool {
        await run("test", ["-f", path], nil)?.status == 0
    }

    func isFolder(_ path: String) async -> Bool {
        await run("test", ["-d", path], nil)?.status == 0
    }

    /// Writes `data` to `path`, making its folder first.
    func write(_ data: Data, to path: String) async -> Bool {
        await run("sh", ["-c", "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"", "sh", path], data)?.status == 0
    }

    /// Writes `data` to `path` in pieces no larger than `piece` bytes, so a large file never
    /// rides one `run`; it shows at `path` only once whole.
    /// `progress` hears the share written so far after each piece.
    func write(_ data: Data, to path: String, piece: Int, progress: (Double) -> Void = { _ in }) async -> Bool {
        guard data.count > piece else { return await write(data, to: path) }
        let partial = path + ".part"
        var offset = 0
        while offset < data.count {
            let end = min(offset + piece, data.count)
            let script = offset == 0 ? "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"" : "cat >> \"$1\""
            guard await carried("sh", ["-c", script, "sh", partial], data.subdata(in: offset..<end), bulk: true)?.status == 0 else {
                _ = await run("rm", ["-f", "--", partial], nil)
                return false
            }
            offset = end
            progress(Double(offset) / Double(data.count))
        }
        return await run("mv", ["-f", "--", partial, path], nil)?.status == 0
    }

    /// What a program printed, when it succeeded.
    func output(_ executable: String, _ arguments: [String]) async -> String? {
        guard let ran = await run(executable, arguments, nil), ran.status == 0 else { return nil }
        return String(decoding: ran.output, as: UTF8.self)
    }
}
