# Benchmarks

Measurements of the terminal engine and the app, before (SwiftTerm, `legacy`) and after (the
shipped engine, `core`), on [package-benchmark](https://github.com/ordo-one/package-benchmark):
it runs every benchmark the same way (warm-up, samples, percentiles), measures with its
built-in metrics, and stores and compares baselines. Kept out of the app package, so the app
never links SwiftTerm or the benchmark runtime.

```sh
cd Benchmarks
brew install jemalloc                            # once: allocation metrics
alias bench='swift package --disable-sandbox benchmark'   # the suites start processes and the app

bench                                            # every suite, on core
bench --target Engine --filter 'parse/.*'        # a filter is a regex on the whole name
BENCH_ENGINE=legacy bench --target Engine        # the same benchmarks on SwiftTerm
bench baseline compare legacy core --target Engine   # before and after, from the stored baselines
swift test                                       # correctness: core shows what legacy shows
swift run -c release Inspect screen              # look at things: screen, snapshot, layers
```

## Layout

```
Engine/          suite: the engine alone, offscreen (parse, memory, frame, e2e)
Pacing/          suite: when frames are drawn (pacing policies simulated, FramePacer's cost)
App/             suite: the release app with 10 agents, in scenarios
Sources/
  ClaudeSim/     input: a Claude Code-like session, deterministic by seed
  FakeAgent/     input: ClaudeSim played on a PTY in real time, run as `claude`
  EngineKit/     the protocols an engine implements (TerminalUnderTest, BoardUnderTest), Offscreen
  Baseline/      engine `legacy`: a verbatim copy of the old SwiftTerm engine and board
  Current/       engine `core`: the shipped modules behind the same protocols
  BenchKit/      what suites, tests and tools share: corpora, the engines, BENCH_ENGINE
  SuiteKit/      the few metrics package-benchmark doesn't have
  Inspect/       tool: prints and renders things to look at; measures nothing
Tests/CorrectnessTests/   the same bytes through both engines
corpus/          captured input (a real Claude Code startup)
.benchmarkBaselines/      stored baselines: `core` for every suite, `legacy` for Engine
reports/         what the numbers mean, one file per question; data/ holds the first harness's records
```

Suites are the executable targets at the top level, where package-benchmark finds them.

## Writing a benchmark

A benchmark is a `Benchmark(...)` in a suite's `benchmarks` closure. Its name is
`group/case`, without commas; the name is what baselines are matched by, so renaming one
starts its history over.

```swift
let state = Box<TerminalUnderTest>()
Benchmark("scroll/100k lines",
          configuration: .init(metrics: [.throughput, .cpuTotal, .mallocCountTotal], warmupIterations: 2,
                               maxDuration: .seconds(5), maxIterations: 50),
          closure: { benchmark in
              // one sample: the work, and nothing else
          },
          setup: { state.value = engine.terminal.init(cols: Terminal.cols, rows: Terminal.rows, scrollback: Terminal.scrollback) },
          teardown: { state.value = nil })
```

The rules that keep benchmarks comparable:

- **Measure with built-in metrics.** CPU (`cpuTotal`), time (`wallClock`), rate (`throughput`),
  memory (`allocatedResidentMemory`, `peakMemoryResident`), allocations (`mallocCountTotal`),
  `contextSwitches`, `threads`. No clocks in a closure.
- **What no built-in covers is a metric in `SuiteKit`**, read from the system's own counter, and
  every benchmark that needs it uses that one: `Metrics.gpuTime` (Metal's timestamps),
  `Metrics.processCPU` and `processFootprint` (the kernel's accounting of another process),
  `Metrics.framesDrawn`.
- **Choose the sample so the metric reads plainly.** Parsing feeds 1 MiB per sample, so
  `throughput` is MiB/s; e2e and app samples last one second, so CPU per sample is CPU per
  second (10 ms or 10 000 µs is 1% of a core); a frame benchmark's sample is one frame.
- **Work outside the measurement goes in `setup`**, or before `benchmark.startMeasurement()`.
- **Engines are subjects, not branches.** A benchmark runs on `Engines.selected` through
  `TerminalUnderTest` or `BoardUnderTest`, never `if engine == ...`. A new engine is one line in
  `Engines.all` and runs every benchmark.
- **Inputs are deterministic**: seeded simulations, corpora generated from a fixed seed, real
  captures in `corpus/`.
- **Correctness is a test, looking is a tool**: neither goes in a suite.

## The app suite and `BENCH`

`App` builds the app in release with `-Xswiftc -DBENCH` (in `.build/bench`, apart from your
builds) and launches it per scenario on a temporary database, with a git repository of two
worktrees and `claude` resolving to FakeAgent. Its window sits behind yours and draws as if on
screen. Nothing of the user's is read or written.

What the app does for a scenario is in `Sources/AgentBoard/BenchScenario.swift` and a few
`#if BENCH` lines that call it (database path, showing and switching worktrees, focusing the
working card, drawing while covered). It reads its scenario from `AGENTBOARD_BENCH_*`
variables, set by `App/AppRun.swift`. None of it is compiled into the shipped app. A new
scenario is a `Scenario` in `App/App.swift`, and a `BenchScenario` setting if the app has to do
something new for it.

## Baselines

```sh
bench baseline update core                                   # every suite, after a change worth keeping
BENCH_ENGINE=legacy bench baseline update legacy --target Engine
bench baseline compare core                                  # this working copy against the stored core
bench baseline check core                                    # fails (exit 2) past the thresholds
```

Baselines are JSON in `.benchmarkBaselines/` and belong in the repository. They come from
this machine; compare runs from the same one.

## Reports

| Report | Question |
|---|---|
| [engine.md](reports/engine.md) | Is the new engine faster, smaller and correct next to SwiftTerm? |
| [app.md](reports/app.md) | What does rendering cost in the real app, and is it below the target? |

A report answers one question, says how it was measured, and ends with the commands that
reproduce it. A new question gets a new report instead of a new section in an old one.
