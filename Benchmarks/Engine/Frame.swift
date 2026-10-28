import Benchmark
import BenchKit
import SuiteKit
import ClaudeSim

/// One board frame with 10 cards (640x420) at 2x while the cards' simulated sessions update.
/// A sample is one frame: the sessions' output goes in first (not measured), then the frame is
/// encoded and the GPU finishes it.
func frame(_ engine: Engine) {
    let cases: [(mode: ClaudeSim.Mode, active: Int)] = [(.spinner, 10), (.stream, 10), (.spinner, 1)]
    for (mode, active) in cases {
        let state = Box<(board: BoardUnderTest, sims: [ClaudeSim])>()
        Benchmark("frame/\(mode.rawValue) \(active) of 10 cards",
                  configuration: .init(metrics: [.cpuTotal, .wallClock, Metrics.gpuTime], warmupIterations: 30,
                                       maxDuration: .seconds(10), maxIterations: 300),
                  closure: { benchmark in
                      let board = state.value!.board
                      for card in 0..<active {
                          let bytes = state.value!.sims[card].next().bytes
                          bytes.withUnsafeBytes { board.feed(card: card, $0) }
                      }
                      benchmark.startMeasurement()
                      let commands = board.render()
                      commands.waitUntilCompleted()
                      benchmark.stopMeasurement()
                      benchmark.measureGPU(commands)
                  },
                  setup: {
                      let board = engine.board.init(offscreen: Offscreen(width: 2 * 2720, height: 2 * 1400), cards: cardFrames(count: 10),
                                                    scale: 2, scrollback: Terminal.scrollback)
                      state.value = (board, (0..<10).map { ClaudeSim(cols: 101, rows: 21, mode: mode, seed: UInt64($0 + 1)) })
                  },
                  teardown: {
                      state.value?.board.stop()
                      state.value = nil
                  })
    }
}
