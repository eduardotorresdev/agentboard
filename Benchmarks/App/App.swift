import Benchmark
import BenchKit
import SuiteKit
import Foundation

// The release app, built with `-DBENCH`, on its own temporary database: 10 cards running
// FakeAgent as `claude`, the window behind yours (it draws as if on screen). A sample is one
// second of the app's CPU and footprint, read from the kernel; the first one is taken once the
// agents have started and the scenario has settled.

let benchmarks = {
    // One unit for every time metric, so tables and comparisons read alike.
    Benchmark.defaultConfiguration.timeUnits = .microseconds
    for scenario in Scenario.all {
        let run = Box<AppRun>()
        Benchmark("app/\(scenario.name)",
                  configuration: .init(metrics: [Metrics.processCPU, Metrics.processFootprint], warmupIterations: 0,
                                       maxDuration: .seconds(40), maxIterations: 30),
                  closure: { benchmark in
                      let pid = run.value!.pid
                      guard let start = ProcessUsage(pid: pid) else { return benchmark.error("the app quit") }
                      let started = Date()
                      Thread.sleep(forTimeInterval: 1)
                      guard let end = ProcessUsage(pid: pid) else { return benchmark.error("the app quit") }
                      benchmark.measureProcess(from: start, to: end, seconds: Date().timeIntervalSince(started))
                  },
                  setup: {
                      run.value = try AppRun(scenario)
                      try await Task.sleep(for: .seconds(scenario.settle))
                  },
                  teardown: {
                      run.value?.stop()
                      run.value = nil
                  })
    }
}

struct Scenario {
    let name: String
    /// Agents working; the others wait at their start screen, like a usual board.
    var working = 10
    /// What the working agents do (FakeAgent's `--mode`).
    var mode = "stream"
    /// Focus the working agent's card once it prints, so it draws at the focused pace.
    var focusPrinting = false
    /// Switch to the other, empty worktree this many seconds after launch.
    var switchAfter: Double?
    /// Seconds from launch to the first sample.
    var settle = 12.0

    static let all = [
        Scenario(name: "10 agents idle", working: 0),
        Scenario(name: "1 of 10 working", working: 1),
        Scenario(name: "1 of 10 working focused", working: 1, focusPrinting: true),
        Scenario(name: "10 working"),
        Scenario(name: "10 working mixed", mode: "mixed"),
        Scenario(name: "10 working switched away", switchAfter: 8, settle: 14),
    ]
}
