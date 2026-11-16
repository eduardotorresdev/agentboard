import Foundation
import Testing
@testable import AgentRuntime

/// What a launched program gets from the process that starts it: its environment, and none of
/// that process's open descriptors (a pipe left open there would never reach end-of-file).
struct LaunchInheritanceTests {
    @Test func programsGetTheirEnvironmentButNotOurDescriptors() async throws {
        var pipe: [Int32] = [0, 0]
        #expect(Darwin.pipe(&pipe) == 0)
        // Far above what the program opens itself, so the check can't confuse the two.
        let probe = fcntl(pipe[1], F_DUPFD, 200)
        #expect(probe >= 200)
        defer { close(pipe[0]); close(pipe[1]); close(probe) }
        let session = AgentSession(cols: 120, rows: 6)
        session.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf 'v=%s fds=' \"$F1_PROBE\"; ls /dev/fd | tr '\\n' ' '; printf 'end'; sleep 5"],
                                 environment: ["PATH": "/usr/bin:/bin", "F1_PROBE": "here"], directory: NSTemporaryDirectory()))
        let deadline = Date().addingTimeInterval(10)
        var screen = ""
        while !screen.contains("end"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            screen = session.withTerminal { $0.screenText().joined(separator: "\n") }
        }
        session.stop()
        #expect(screen.contains("v=here"), "\(screen)")
        let listed = screen.components(separatedBy: "fds=").last?.components(separatedBy: "end").first?
            .split(separator: " ").compactMap { Int32($0) } ?? []
        #expect(listed.contains(2), "\(screen)")
        #expect(!listed.contains(probe), "\(screen)")
    }
}
