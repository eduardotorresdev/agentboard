# Terminal engine: before and after

The app used to parse agent output with SwiftTerm 1.99.1 and rebuild every card's quads on the
CPU each frame. It now runs its own engine, split into four modules:

| Module | Responsibility |
|---|---|
| `TerminalCore` | VT parser, screen model (12-byte cells, row map, per-row damage), packed scrollback, input encoders. No UI, no Metal. |
| `TerminalRenderer` | `GlyphCache` (cell-sized atlas slots, procedural box/block glyphs), `TerminalLayer` (a terminal's cells on the GPU, 16 B/cell, uploads only damaged rows; a scroll uploads only the row map), `TerminalPipeline` (one instanced draw per terminal), `TerminalPresenter` (draws the terminals that changed in one command buffer, one render pass per target), `SharedSurface` (one double-buffered IOSurface holding every visible terminal), `FramePacer` (how often to draw, and which changed terminals go in each frame). |
| `AgentRuntime` | `AgentProvider` (what to launch; `ClaudeCode` is the only one today), `PseudoTerminal`, `AgentSession` (feeds the terminal; notifies the board only while *observed*). |
| `BoardView` (app) | Core Animation board: grid (replicator layers), one layer tree per card (shadow, title, status, cursor), and a layer per visible terminal showing its region of one shared surface. A display link, paced by `FramePacer`, redraws only the terminals that changed, all in one render pass. |

The chrome is never redrawn by the app: the window server composites the card layers, and
moving or animating a card only changes a layer's position. A spinner in one card redraws that
card's region of the shared surface and nothing else.

Only cards on screen hold a `TerminalLayer` and a region of the shared surface, and are observed. Switching worktree or project,
scrolling a card off the viewport, hiding or occluding the window drops the layers and stops
notifications; the programs keep running and their terminals keep parsing (without the main
thread), ready to be shown again with a single full upload.

## Method

Everything runs on this Mac (Apple Silicon, Metal) with `swift build -c release`.
`legacy` is a verbatim copy of the previous engine and board (`Sources/Baseline`); `core` is the
shipped code imported from the app package (`Sources/Current`), so both go through the same
harness. Raw results of that first run: `data/<bench>.jsonl`.

- **parse**: bytes/s through parser + screen model, fed in 1 KB reads, 120×40, 5000-line
  scrollback, best of 5. Corpora: `ascii` (scrolling plain text), `sgr` (colored code), `unicode`
  (CJK, emoji, combining marks), `claude` (simulated Claude Code session), `claude-real`
  (a real Claude Code v2.1.312 capture, repeated).
- **memory**: footprint of 10 terminals after a long session.
- **frame**: one board frame with 10 cards (640×420) at 2x, while `--active K` of the cards'
  simulated Claude sessions update (default: all 10). The legacy board renders the whole board
  into one 5440×2800 target; the core renders each changed terminal into its own surface, as the
  app does. GPU time is the command buffer's `gpuEndTime − gpuStartTime`.
- **e2e**: 10 real processes (`FakeAgent`, a Claude Code-like TUI on a PTY) on one board, redrawn
  at most 60 times a second when something changed, like the app; 20 s; this process only.
- **diff**: the same bytes through both engines, comparing text, colors, bold and cursor every
  32 KB.

## Results

### Parsing (MB/s, higher is better)

| Corpus | legacy | core | |
|---|---:|---:|---|
| claude (simulated) | 224 | **386** | 1.7× |
| claude-real | 134 | **299** | 2.2× |
| sgr | 160 | **232** | 1.4× |
| unicode | 149 | **215** | 1.4× |
| ascii (scroll-heavy) | **601** | 418 | 0.7× |

Plain scrolling text is the one regression, and it is deliberate: every line that leaves the
screen is packed (trailing blanks trimmed, styles run-length encoded, characters as varints),
which costs about 1.5 ns/byte and buys the memory below. Without scrollback the core parses
ASCII at 1142 MB/s vs 655 MB/s. 418 MB/s is still far above what an agent writes to a PTY.

### Memory per terminal (MB, lower is better)

| Session | legacy (empty → after) | core (empty → after) |
|---|---|---|
| Claude Code (alternate screen) | 0.125 → 0.177 | **0.003 → 0.005** |
| 5000 lines of scrollback | 0.205 → 0.738 | **0.067 → 0.425** |

Visible cards also hold a GPU copy: 16 bytes per cell (≈27 KB for a 640×420 card) plus one
shared glyph atlas (≈0.5–1 MB). Hidden cards hold none.

### Board frame, 10 cards (ms, lower is better)

The usual board: one or a few agents working, the others waiting for input.

| Agents updating | | legacy | core | |
|---|---|---:|---:|---|
| 1 (spinner) | CPU | 0.35–1.38 | **0.011–0.014** | ≈60× |
| | GPU median | 1.39–6.0 | **0.075–0.165** | ≈18× |
| | GPU min | 1.38 | **0.070–0.089** | ≈18× |
| 1 (streaming) | CPU | 1.07–1.29 | **0.021** | ≈55× |
| | GPU median | 5.98 | **0.18–0.22** | ≈30× |
| 3 (spinner) | CPU | 0.87–1.00 | **0.016–0.038** | ≈30× |
| | GPU median | 1.38–1.54 | **0.10–0.17** | ≈10× |
| 10 (spinner) | CPU | 1.72–1.98 | **0.135–0.148** | ≈13× |
| | GPU median | 1.39–1.40 | **1.16** | 1.2× |
| | GPU min | 1.37 | **0.64–1.14** | |

The legacy board redraws everything on any change, so its cost is flat (≈1.4 ms of GPU at
full clock; 2–6 ms when the GPU clock is low). The core pays per changed terminal: about
0.07 ms of GPU and 0.01 ms of CPU each. Even with all ten updating, it is still cheaper,
because it no longer draws the chrome and the empty canvas.

Caveats, stated plainly:

- The GPU clock follows load, so absolute GPU times swing between runs; the ranges above are
  from several runs each. The ratios hold in every run.
- The core numbers don't include the window server compositing the layers (the chrome and
  each terminal's drawable). That work is done for every window by every app and only happens
  when a layer changes, but it is outside this process and not measured here.

### End to end: 10 agents on PTYs, this process (lower is better)

| Scenario | legacy CPU | core CPU | legacy fps | core fps |
|---|---:|---:|---:|---:|
| Mixed (thinking, tools, streaming) | 11.2% | **2.3%** | 35 | 31 |
| Streaming | 14.6% | **3.1%** | 38 | 35 |
| Worktree switched away | 3.3% | **0.7%** | 38 (wasted) | **0** |

About the same frame rate, about 5× less CPU. Memory of the whole process (footprint):

| | legacy | core |
|---|---:|---:|
| Board visible | 155 MB | **104 MB** |
| Worktree switched away | 142 MB | **48 MB** |

Switching away releases every drawable and GPU cell buffer; the legacy board kept it all. With the agents' worktree not on screen, the legacy board
kept redrawing 38 times a second; the core draws nothing and only parses.

### Correctness

The differential check matches the legacy engine on 10 of 12 sources exactly: every simulated mixed and spinner
session, the real Claude capture, and the SGR and Unicode corpora. In two streaming sessions, 39
cells differ, all in the last column. A diff line exactly as wide as the screen is followed by
`ESC[K`: xterm erases the last cell (the cursor sits on it with a wrap pending); SwiftTerm
keeps it. The core follows xterm, and a unit test pins it down; `swift test` (CorrectnessTests)
leaves the last column out and fails on any other difference.

`swift test`: 45 tests covering printing, editing, attributes, Unicode, screens, replies,
input, damage, scrollback, and the real capture.

## What moved the numbers

Profiling (`sample`) during development found three costs:

1. **Swift's dynamic exclusivity checks** were 46% of parse time: the parser was advanced in
   place as a stored property, so every property access in the callbacks was checked against
   it. The parser now advances a local copy, and the hot class properties of the terminal,
   grid, scrollback, glyph cache and layer are `@exclusivity(unchecked)`; each terminal is only
   touched under its session's lock. Unicode 103 → 219 MB/s, Claude 283 → 397 MB/s.
2. **Interning grapheme clusters by `String`**: hashing a `String` normalizes it to NFC.
   Clusters are now keyed by their raw scalars.
3. **Scrollback packing** allocated a run array and appended byte by byte per line. It now
   writes runs and characters in one pass into reused raw buffers: ASCII 134 → 418 MB/s.

## Reproduce

The tables above came from the first harness (records in `data/`); the same benchmarks now run on
package-benchmark, and their stored baselines are `legacy` and `core` in `.benchmarkBaselines/`.

```sh
cd Benchmarks
alias bench='swift package --disable-sandbox benchmark'
BENCH_ENGINE=legacy bench baseline update legacy --target Engine
bench baseline update core --target Engine
bench baseline compare legacy core --target Engine     # the before and after
swift test                                              # correctness against SwiftTerm
swift run -c release Inspect snapshot --source real     # look at the rendering
```
