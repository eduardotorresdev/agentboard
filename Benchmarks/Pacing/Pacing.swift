import Benchmark
import BenchKit
import ClaudeSim
import Foundation
import TerminalRenderer

// When frames are drawn. Pacing policies run in simulated time on a 60 Hz display with 10
// agents writing at ClaudeSim's pace (the timing FakeAgent plays), so each run gives the same
// numbers: one sample each. And the cost of one FramePacer decision, as the app calls it.

let benchmarks = {
    // One unit for every time metric, so tables and comparisons read alike.
    Benchmark.defaultConfiguration.timeUnits = .microseconds
    for focused in [false, true] {
        for policy in Policy.allCases {
            Benchmark("pacing/\(policy.rawValue)\(focused ? " focused" : "")",
                      configuration: .init(metrics: Simulation.metrics, warmupIterations: 0, maxIterations: 1)) { benchmark in
                Simulation(policy: policy, focused: focused).run(into: benchmark)
            }
        }
    }

    Benchmark("pacer/select 10 cards", configuration: .init(metrics: [.throughput, .wallClock], scalingFactor: .kilo)) { benchmark in
        var pacer = FramePacer<Int>()
        pacer.focused = 0
        let dirty: Set<Int> = [0, 3]
        for call in benchmark.scaledIterations { blackHole(pacer.select(dirty, at: Double(call) / 60)) }
    }
}

enum Policy: String, CaseIterable {
    /// Every change drawn on the next vsync: the board before pacing.
    case everyChange = "every-change"
    /// The focused card at its pace, the others together on a 15 Hz beat.
    case beat
    /// The beat, and cards that changed recently ride along with the focused card's frames.
    case beatRideAlong = "beat-ride-along"
}

/// Two minutes of 10 agents streaming, frame by frame.
struct Simulation {
    static let framesPerMinute = BenchmarkMetric.custom("Frames (per min)", useScalingFactor: false)
    static let cardDrawsPerMinute = BenchmarkMetric.custom("Card draws (per min)", useScalingFactor: false)
    static let waitMean = BenchmarkMetric.custom("Wait to be drawn, mean (µs)", useScalingFactor: false)
    static let waitP95 = BenchmarkMetric.custom("Wait to be drawn, p95 (µs)", useScalingFactor: false)
    static let metrics = [framesPerMinute, cardDrawsPerMinute, waitMean, waitP95]

    let policy: Policy
    let focused: Bool
    let agents = 10, seconds = 120.0

    func run(into benchmark: Benchmark) {
        var pacer = FramePacer<Int>(rideAlong: policy == .beat ? 1 : 0.4)
        pacer.focused = focused ? 0 : nil
        var sims = (0..<agents).map { ClaudeSim(cols: 80, rows: 24, mode: .stream, seed: UInt64($0 + 1)) }
        var nextWrite = sims.indices.map { sims[$0].next().delay }
        var dirtySince: [Int: Double] = [:]
        var frames = 0, draws = 0
        var waits: [Double] = []
        for vsync in 0..<Int(seconds * 60) {
            let now = Double(vsync) / 60
            for agent in 0..<agents {
                while nextWrite[agent] <= now {
                    if dirtySince[agent] == nil { dirtySince[agent] = nextWrite[agent] }
                    nextWrite[agent] += sims[agent].next().delay
                }
            }
            guard !dirtySince.isEmpty else { continue }
            let due: [Int]
            if policy == .everyChange {
                due = Array(dirtySince.keys)
            } else {
                // The display link fires on every n-th vsync at the pace's rate.
                let divisor = max(1, Int(60 / pacer.pace(at: now).frameRate.preferred))
                guard vsync % divisor == 0 else { continue }
                due = pacer.select(Set(dirtySince.keys), at: now).draw
            }
            guard !due.isEmpty else { continue }
            frames += 1
            draws += due.count
            for agent in due { waits.append(now - dirtySince.removeValue(forKey: agent)!) }
        }
        waits.sort()
        let minutes = seconds / 60
        benchmark.measurement(Self.framesPerMinute, Int(Double(frames) / minutes))
        benchmark.measurement(Self.cardDrawsPerMinute, Int(Double(draws) / minutes))
        benchmark.measurement(Self.waitMean, Int(waits.reduce(0, +) / Double(max(1, waits.count)) * 1e6))
        benchmark.measurement(Self.waitP95, Int(waits.isEmpty ? 0 : waits[waits.count * 95 / 100] * 1e6))
    }
}
