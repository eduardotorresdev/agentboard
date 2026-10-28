import Benchmark
import BenchKit

/// Ten terminals after a long session. `claude` stays in the alternate screen; `ascii` scrolls
/// thousands of lines into the scrollback. `memoryLeaked` is what the sample allocated and still
/// holds at its end: the ten terminals' memory.
func memory(_ engine: Engine) {
    for corpus in [Corpus.claude, .ascii] {
        let bytes = Box<[UInt8]>()
        Benchmark("memory/\(corpus.rawValue) 10 terminals",
                  configuration: .init(metrics: [.allocatedResidentMemory, .mallocCountTotal, .peakMemoryResident], warmupIterations: 1,
                                       maxDuration: .seconds(10), maxIterations: 5),
                  closure: { benchmark in
                      let terminals = (0..<10).map { _ in
                          engine.terminal.init(cols: Terminal.cols, rows: Terminal.rows, scrollback: Terminal.scrollback)
                      }
                      for terminal in terminals { feedInChunks(bytes.value!) { terminal.feed($0) } }
                      benchmark.stopMeasurement()
                      blackHole(terminals)
                  },
                  setup: { bytes.value = corpus.bytes(corpusDirectory: Corpus.directory) },
                  teardown: { bytes.value = nil })
    }
}
