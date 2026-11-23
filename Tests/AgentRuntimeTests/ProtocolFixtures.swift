import Foundation
import Testing
@testable import AgentRuntime

/// Writes the JSON of every `CoreProtocol` message to `core/fixtures/runtime`, where the Rust
/// core's tests check that it decodes and encodes them the same way (docs/hosts.md).
struct ProtocolFixtures {
    private static let ids = (1...3).map { UUID(uuidString: "0000000\($0)-ABCD-4EF0-8A1B-00000000000\($0)")! }

    /// The JSON with every `[uuid, value, uuid, value]` array sorted by its keys, for comparing.
    static func canonical(_ data: Data) -> NSObject? {
        func sorted(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.mapValues(sorted) }
            guard let array = value as? [Any] else { return value }
            let items = array.map(sorted)
            let keys = stride(from: 0, to: items.count, by: 2).compactMap { items[$0] as? String }
            guard items.count % 2 == 0, keys.count == items.count / 2, keys.allSatisfy({ UUID(uuidString: $0) != nil }) else { return items }
            let pairs: [(String, Any)] = keys.indices.map { (keys[$0], items[$0 * 2 + 1]) }
            var out: [Any] = []
            for (key, item) in pairs.sorted(by: { $0.0 < $1.0 }) { out.append(key); out.append(item) }
            return out
        }
        return (try? JSONSerialization.jsonObject(with: data)).map(sorted) as? NSObject
    }

    @Test func writesWireSamples() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/fixtures/runtime")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        func write(_ value: some Encodable, _ name: String) throws {
            let url = folder.appendingPathComponent(name + ".json")
            let data = try encoder.encode(value)
            // A UUID-keyed dictionary encodes in hash order, which changes every run: keep the file when only that order differs.
            if let old = try? Data(contentsOf: url), let before: NSObject = Self.canonical(old), before.isEqual(Self.canonical(data)) { return }
            try data.write(to: url)
        }
        let ids = Self.ids
        let spec = LaunchSpec(executable: "/bin/sh", arguments: ["-c", "echo \"hi\""], environment: ["TERM": "xterm-256color"], directory: "/tmp")

        // Doubles are never whole here: Swift writes 2.0 as `2`, serde_json as `2.0`, and the
        // Rust tests compare what they re-encode to these files.
        let requests: [(String, CoreRequest)] = [
            ("hello", .hello(version: 8, oldest: 2)),
            ("hello_without_oldest", .hello(version: 2, oldest: nil)),
            ("hello_answering_questions", .hello(version: 10, oldest: 2, answersQuestions: true)),
            ("start", .start(id: ids[0], spec: spec, cols: 120, rows: 40)),
            ("attach", .attach(id: ids[0])),
            ("resize", .resize(id: ids[0], cols: 80, rows: 24)),
            ("observe", .observe(id: ids[0], observed: true)),
            ("subscribeStatuses", .subscribeStatuses),
            ("terminate", .terminate(id: ids[0], grace: 1.5)),
            ("stop", .stop(id: ids[0])),
            ("annotate", .annotate(id: ids[0], text: "-- restarted --\r\n", freshLine: true)),
            ("close", .close(id: ids[0], grace: 0.5)),
            ("close_hanging_up", .close(id: ids[0], grace: nil)),
            ("shutdown", .shutdown),
            ("takeOver", .takeOver),
            ("run", .run(call: ids[1], executable: "git", arguments: ["status", "--porcelain"], directory: "/tmp", input: Data("typed\n".utf8))),
            ("run_without_directory", .run(call: ids[1], executable: "/usr/bin/true", arguments: [], directory: nil, input: nil)),
            ("subscribeHost", .subscribeHost),
        ]
        for (name, request) in requests { try write(request, "request_" + name) }

        func status(_ state: AgentSession.State, pid: Int32? = nil, code: Int32? = nil) -> SessionStatus {
            SessionStatus(state: state, processID: pid, exitCode: code)
        }
        let events: [(String, CoreEvent)] = [
            ("welcome", .welcome(version: 8, oldest: 2, sessions: [ids[0]: status(.running, pid: 4242)], service: Data([0, 1, 2, 250, 255]))),
            ("welcome_incompatible", .welcome(version: 11, oldest: 10, sessions: [:], service: nil)),
            ("status_starting", .status(id: ids[0], status: status(.starting))),
            ("status_running", .status(id: ids[0], status: status(.running, pid: 4242))),
            ("status_exited", .status(id: ids[0], status: status(.exited, code: 3))),
            ("status_failed", .status(id: ids[0], status: status(.failed("No such file or directory")))),
            ("status_stopped", .status(id: ids[0], status: status(.stopped, code: 143))),
            ("ran", .ran(call: ids[1], status: 1, output: Data("out\n".utf8), error: Data("fatal: not a git repository\n".utf8))),
            ("host", .host(HostStats(cpu: 0.25, memoryUsed: 6_000_000_000, memoryTotal: 16_000_000_000, diskUsed: 200_000_000_000,
                                     diskTotal: 500_000_000_000, load: 1.75, cores: 8))),
        ]
        for (name, event) in events { try write(event, "event_" + name) }

        // Several sessions: the array alternates ids and statuses, in the dictionary's order.
        try write(CoreEvent.welcome(version: 8, oldest: 2, sessions: [ids[0]: status(.running, pid: 1), ids[1]: status(.exited, code: 0),
                                                                     ids[2]: status(.stopped)], service: nil), "event_welcome_sessions")
    }
}
