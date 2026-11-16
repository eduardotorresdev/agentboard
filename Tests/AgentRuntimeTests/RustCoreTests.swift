import Foundation
import Testing
@testable import AgentRuntime

/// The Rust core (`core/`, docs/hosts.md) serving this build's board. Needs its binary:
/// `AGENTBOARD_RUST_CORE=core/target/debug/agentboard swift test --filter RustCoreTests`.
struct RustCoreTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_RUST_CORE"] != nil))
    func aSwiftBoardMirrorsAProgramOnTheRustCore() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["AGENTBOARD_RUST_CORE"])
        let path = NSTemporaryDirectory() + "abrust-\(UUID().uuidString.prefix(8)).sock"
        let core = Process()
        core.executableURL = URL(fileURLWithPath: binary)
        core.arguments = ["core", "--socket", path]
        try core.run()
        defer {
            if core.isRunning { core.terminate() }
            unlink(path)
            unlink(path + ".lock")
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }

        var connected: CoreClient?
        try await waitUntil {
            connected = try? CoreClient.open(socketPath: path, timeout: 3).get()
            return connected != nil
        }
        let board = try #require(connected)
        #expect(board.version == CoreProtocol.version)

        let session = AgentSession(cols: 40, rows: 6)
        session.host(on: board, id: UUID())
        session.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf 'ready\\n'; read line; printf 'got %s\\n' \"$line\"; exit 3"],
                                 environment: ["PATH": "/usr/bin:/bin"], directory: NSTemporaryDirectory()))
        func screen() -> String { session.withTerminal { $0.screenText().joined(separator: "\n") } }
        try await waitUntil { screen().contains("ready") }
        #expect(session.state == .running)
        #expect(session.processID != nil)
        session.send(Array("hello\r".utf8))
        try await waitUntil { session.state == .exited }
        #expect(screen().contains("got hello"), "\(screen())")
        #expect(session.state == .exited)
        #expect(session.exitCode == 3)
        #expect(session.processID == nil)

        // Protocol 8: a program run on the core's machine.
        let ran = try #require(await board.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 4"]))
        #expect(ran.status == 4)
        #expect(String(decoding: ran.output, as: UTF8.self) == "out")
        #expect(String(decoding: ran.error, as: UTF8.self) == "err")

        board.shutdown()
        try await waitUntil { !core.isRunning }
        #expect(!core.isRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
