import Benchmark
import BenchKit

/// Parser and screen model alone, 120x40 with 5000 lines of scrollback, fed in 1 KB reads like
/// a PTY. One sample feeds 1 MiB of the corpus, so `throughput` reads as MiB/s.
func parse(_ engine: Engine) {
    for corpus in Corpus.allCases {
        let state = Box<(terminal: TerminalUnderTest, bytes: [UInt8], offset: Int)>()
        Benchmark("parse/\(corpus.rawValue)",
                  configuration: .init(metrics: [.throughput, .cpuTotal, .mallocCountTotal], warmupIterations: 2,
                                       maxDuration: .seconds(5), maxIterations: 50),
                  closure: { benchmark in
                      let megabyte = 1 << 20
                      let (terminal, bytes, start) = state.value!
                      let offset = start + megabyte > bytes.count ? 0 : start
                      bytes.withUnsafeBytes { all in
                          feedInChunks(UnsafeRawBufferPointer(rebasing: all[offset..<offset + megabyte])) { terminal.feed($0) }
                      }
                      state.value!.offset = offset + megabyte
                      blackHole(terminal)
                  },
                  setup: {
                      let terminal = engine.terminal.init(cols: Terminal.cols, rows: Terminal.rows, scrollback: Terminal.scrollback)
                      state.value = (terminal, corpus.bytes(corpusDirectory: Corpus.directory), 0)
                  },
                  teardown: { state.value = nil })
    }
}
