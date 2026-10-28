import Benchmark
import BenchKit
import SuiteKit
import Foundation

/// Ten FakeAgent processes on real PTYs, one per card, the board redrawing at most 60 times a
/// second when something changed, like the app. This process only, not the agents. A sample is
/// one second, so `cpuTotal` in ms divided by 10 is the percentage of one core. The first three
/// let the agents boot and draw their start screens.
func endToEnd(_ engine: Engine) {
    for (mode, visible) in [("mixed", true), ("stream", true), ("stream", false)] {
        let state = Box<(board: BoardUnderTest, frames: Box<Int>)>()
        Benchmark("e2e/\(mode) 10 agents\(visible ? "" : " switched away")",
                  configuration: .init(metrics: [.cpuTotal, .peakMemoryResident, .contextSwitches, Metrics.framesDrawn],
                                       warmupIterations: 3, maxDuration: .seconds(25), maxIterations: 20),
                  closure: { benchmark in
                      let (board, frames) = (state.value!.board, state.value!.frames)
                      let before = frames.value!
                      // Like the app's display link: at most 60 frames a second, only when
                      // something changed. Frames are drawn on the main queue, where the sessions
                      // report changes; the runner calls this closure off the main thread.
                      let start = Date()
                      for tick in 1...60 {
                          Thread.sleep(until: start.addingTimeInterval(Double(tick) / 60))
                          DispatchQueue.main.sync {
                              guard board.needsDisplay else { return }
                              board.render()
                              frames.value! += 1
                          }
                      }
                      benchmark.measurement(Metrics.framesDrawn, frames.value! - before)
                  },
                  setup: {
                      let board = engine.board.init(offscreen: Offscreen(width: 2 * 2720, height: 2 * 1400), cards: cardFrames(count: 10),
                                                    scale: 2, scrollback: Terminal.scrollback)
                      board.cardsVisible = visible
                      for card in 0..<10 {
                          board.launch(card: card, executable: FakeAgent.path, arguments: ["--mode", mode, "--seed", "\(card + 1)"])
                      }
                      state.value = (board, Box(0))
                  },
                  teardown: {
                      state.value?.board.stop()
                      state.value = nil
                  })
    }
}
