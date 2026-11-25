import Foundation
@testable import Orchestration
import Testing

/// A host that answers as the app's does: the caller blocks until a task replies.
private let waitingHost = GitHost(name: "builder", home: "/home/dev") { _, _ in
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        try? await Task.sleep(for: .milliseconds(50))
        done.signal()
    }
    guard done.wait(timeout: .now() + 20) == .success else { return (1, Data(), Data("gave up".utf8)) }
    return (0, Data("ok".utf8), Data())
}

@Test func hostGitFromManyTasksAtOnceDoesNotStarveThePool() async throws {
    // More waiting callers than the cooperative pool has threads: on the pool they deadlock.
    let callers = ProcessInfo.processInfo.activeProcessorCount * 3
    let started = Date()
    let answers = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<callers {
            group.addTask { try await Git.blocking { try Git.$host.withValue(waitingHost) { try Git.run(["status"]) } } }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(answers == Array(repeating: "ok", count: callers))
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test func cancellingTheCallerStopsBlockingGit() async {
    let work = Task {
        try await Git.blocking {
            try Git.$host.withValue(waitingHost) { while true { try Git.run(["status"]) } }
        }
    }
    try? await Task.sleep(for: .milliseconds(200))
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
}
