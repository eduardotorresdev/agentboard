import Benchmark
import BenchKit

// The terminal engine alone, offscreen: parsing, memory, a board frame, a board fed by real
// processes. Every benchmark runs on `Engines.selected`, so the same names measure both
// engines and `swift package benchmark baseline compare legacy core` is the before and after.

let benchmarks = {
    // One unit for every time metric, so tables and comparisons read alike.
    Benchmark.defaultConfiguration.timeUnits = .microseconds
    let engine = Engines.selected
    parse(engine)
    memory(engine)
    frame(engine)
    endToEnd(engine)
}
