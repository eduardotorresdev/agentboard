import Foundation
import Testing
import AgentRuntime

/// Starts `script` under `/bin/sh` and waits until the session reports `state`.
private func run(_ script: String, cols: Int = 400, observed: Bool, until state: AgentSession.State = .exited) async throws -> AgentSession {
    let session = AgentSession(cols: cols, rows: 4)
    session.isObserved = observed
    session.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
                             directory: NSTemporaryDirectory()))
    // Generous: each `sleep` the scripts run is a process, slow to spawn on a loaded machine.
    let deadline = Date().addingTimeInterval(30)
    while session.state != state, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(session.state == state)
    return session
}

private func firstRow(_ session: AgentSession) -> String {
    session.withTerminal { $0.screenText()[0] }.trimmingCharacters(in: .whitespaces)
}

struct AgentSessionTests {
    /// Output written in many small pieces, read with pauses in between, arrives whole, and
    /// the last piece (written right before exiting) is not lost.
    @Test(arguments: [true, false])
    func smallWritesAllArrive(observed: Bool) async throws {
        let session = try await run("i=0; while [ $i -lt 120 ]; do printf x; i=$((i+1)); sleep 0.001; done; printf END",
                                    observed: observed)
        #expect(firstRow(session) == String(repeating: "x", count: 120) + "END")
    }

    /// A large burst is read without being held back.
    @Test func heavyOutputArrives() async throws {
        let session = try await run("i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done; printf DONE", observed: true)
        #expect(session.withTerminal { $0.screenText() }.last?.hasPrefix("DONE") == true)
    }

    /// Releasing a session whose reader is paused between reads must not crash.
    @Test func releaseWhileReaderPaused() async throws {
        var session: AgentSession? = try await run("printf ready; sleep 5", observed: false, until: .running)
        session?.stop()
        session = nil
        try await Task.sleep(for: .milliseconds(100))
    }

    /// An observed session notifies once per change the board hasn't drawn yet.
    @Test func notifiesOncePerDrawnChange() async throws {
        let session = AgentSession(cols: 80, rows: 4)
        let counter = Counter()
        session.onChange = { counter.increment() }
        session.isObserved = true
        session.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 50 ]; do printf x; i=$((i+1)); sleep 0.002; done; sleep 1"],
                                 environment: ["PATH": "/usr/bin:/bin"], directory: NSTemporaryDirectory()))
        // Until every write arrived (a fixed wait is too short on a loaded machine).
        let deadline = Date().addingTimeInterval(30)
        while firstRow(session).count < 50, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(firstRow(session) == String(repeating: "x", count: 50))
        // Nobody drew: the first notification is the only one.
        #expect(await MainActor.run { counter.value } == 1)
        session.withTerminalForDisplay { _ in }
        try await Task.sleep(for: .milliseconds(50))
        session.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await MainActor.run { counter.value } == 2)
    }

    /// Stopping ends the program and what it started (same process group), counts as a stop
    /// rather than an exit, and runs the completion afterwards.
    @Test func terminateStopsTheWholeGroup() async throws {
        let marker = "agentboard-terminate-\(UUID().uuidString.prefix(8))"
        let session = try await run("sleep 30 & sleep 31 & echo started; wait # \(marker)", observed: false, until: .running)
        let pid = try #require(session.processID)
        var deadline = Date().addingTimeInterval(5)
        while childCount(of: pid) < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(childCount(of: pid) == 2)
        let done = Counter()
        session.terminate { done.increment() }
        // The completion runs on the main queue, which other suites keep busy.
        deadline = Date().addingTimeInterval(5)
        while session.state != .stopped || done.value == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state == .stopped)
        #expect(session.processID == nil)
        #expect(session.exitCode == 128 + SIGTERM)
        #expect(done.value == 1)
        #expect(childCount(of: pid) == 0, "the sleeps went with their parent")
    }

    /// A program that ends on its own reports its exit code.
    @Test func reportsExitCode() async throws {
        let session = try await run("exit 3", observed: false)
        #expect(session.exitCode == 3)
        #expect(session.processID == nil)
    }

    /// A session never started can be marked stopped, and stopping it then completes at once.
    @Test func stopWithoutProcess() async throws {
        let session = AgentSession(cols: 20, rows: 2)
        session.markStopped()
        #expect(session.state == .stopped)
        let done = Counter()
        session.terminate { done.increment() }
        // The completion runs on the main queue, which other suites keep busy.
        let deadline = Date().addingTimeInterval(5)
        while done.value == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done.value == 1)
    }
}

extension AgentSessionTests {
    /// A program that prints and exits before the board draws still tells the board it ended.
    @Test func exitNotifiesWithAChangePending() async throws {
        let session = AgentSession(cols: 20, rows: 2)
        let counter = Counter()
        session.onChange = { counter.increment() }
        session.isObserved = true
        session.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", "echo boom; exit 2"], environment: ["PATH": "/usr/bin:/bin"],
                                 directory: NSTemporaryDirectory()))
        let deadline = Date().addingTimeInterval(5)
        while session.state != .exited, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        // Nothing was drawn: the start's notification, then the exit's.
        #expect(await MainActor.run { counter.value } == 2)
    }
}

/// How many live processes have `parent` as their parent. Asks libproc: waiting on a `Process`
/// (pgrep) from a test's thread can hang.
private func childCount(of parent: pid_t) -> Int {
    var pids = [pid_t](repeating: 0, count: 64)
    let count = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return max(0, Int(count))
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

struct SessionCloseTests {
    /// A session closed and let go of right away still hangs up its program and reaps it.
    @Test func closedSessionReapsItsProgram() async throws {
        var session: AgentSession? = AgentSession(cols: 20, rows: 2)
        session!.start(LaunchSpec(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: ["PATH": "/usr/bin:/bin"],
                                  directory: NSTemporaryDirectory()))
        let deadline = Date().addingTimeInterval(5)
        while session!.processID == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(session!.processID)
        session!.close(grace: nil)
        session = nil
        // Reaped: the pid no longer exists, not even as a zombie.
        let end = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) != 0)
    }
}
