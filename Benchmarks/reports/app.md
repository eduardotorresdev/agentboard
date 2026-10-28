# The real app: 10 agents on one canvas, then a worktree switch

> The experiments below ran on the first harness: `app/run.sh`, which patched a copy of the app
> with frame counters and A/B switches (`FRAMES`, `SKIP`, `PRESENT`, `TRACE`). It has been
> replaced by the `App` suite and the app's `-DBENCH` scenario; those switches are gone, and
> this is their record. See Reproduce for how the scenarios run now.

`app/run.sh`: a release build of the app on its own temporary database, 10 cards
running `FakeAgent` on PTYs (each writes every 50–160 ms, like Claude Code's spinner and
streaming), sampled for 30 s with the board visible, then 30 s after switching to an empty
worktree. Whole app process: SwiftUI, PTY reads, parsing, rendering. MacBook Air, 60 Hz display.

| | legacy | core, first version | core, paced | core, shared surface |
|---|---:|---:|---:|---:|
| Streaming, visible: CPU | 11.5% | 8.2% | 4.3% | **2.5–2.6%** |
| Streaming, one card focused: CPU | | | 5.8% | **2.2–3.5%** |
| Streaming, switched away: CPU | 6.0% | 1.2% | 0.5% | **0.4%** |
| Mixed, visible: CPU | 9.3% | 7.1% | 3.9% | **2.1–2.4%** |
| Mixed, one card focused: CPU | | | 4.4% | **2.4–2.8%** |
| Mixed, switched away: CPU | 5.6% | 0.4% | 0.3% | **0.3%** |
| Memory, visible | 181 MB | 116–122 MB | 122–126 MB | **115–129 MB** |
| Memory, switched away | 182–200 MB | 35–45 MB | 44 MB | **35–45 MB** |

Ranges are separate runs; the same run repeated spreads by up to about a point (the machine
is in use, and other apps' load moves the CPU clock). "Shared surface" is the
shipped board: paced frames with ride-along, no completion handler,
and every changed terminal drawn into one shared surface. With ten agents writing at once,
the whole app (reading ten PTYs, parsing, SwiftUI, rendering) uses about 2.1–2.5% of one
core, a quarter of the legacy app's, and the same memory as with a drawable per card.

Switching worktree drops the app to almost nothing: the agents keep running and their
terminals keep parsing, but nothing is drawn, and memory falls by about 80 MB as drawables and
GPU buffers are released. The legacy app kept rendering and kept (even grew) its memory.

## A usual board: ten agents open, few of them working

`ACTIVE=K` keeps K agents working and the others at their start screen, waiting for a prompt
(`FakeAgent --mode idle`). Background window, one card focused, streaming:

| Ten agents open | CPU visible | Memory visible |
|---|---:|---:|
| None working | **0.02%** (no samples in a 10 s profile) | 68 MB |
| One working | 1.3–1.9% | 123–127 MB |
| Two working | 1.5% | 129 MB |
| All ten working | 2.2–3.5% | ≈125 MB |

A board of waiting agents costs nothing: nothing changes, so nothing is drawn and no thread
wakes. With one agent streaming, `FRAMES=<path>` counts 17 frames a second, one card each, for
≈1 ms of CPU per frame across the app. Drawing the card's cells is ≈0.01 ms of that; the rest is
what any on-screen update costs on macOS: threads waking for the PTY read, the display link, the
Core Animation commit to the window server (≈0.12 ms) and Metal submission (≈0.15 ms). So the
cost of a working agent follows how often it writes (FakeAgent: 20 times a second while
streaming), and the frame rate caps in `FramePacer` are the knob that trades smoothness for it.

A run takes over the screen, and a window covered by another stops drawing (by design), which
spoils the run. `BACKGROUND=1` opens the bench app's window behind the others with clicks
passing through, and lets its board draw while covered, so the user can keep working. It reads
within the front-window spread (streaming, focused: 3.2–3.5% vs 2.2–3.5%; mixed: 2.3% vs
2.1–2.4%; same memory); the table above uses front-window runs.

A Time Profiler trace of the shipped board (streaming, one card focused, profiler attached)
puts rendering at ≈1.5% of a core for ten agents at once: the refresh on the main thread, most
of it the Core Animation commit that hands the new pixels to the window server (≈0.2 ms a
frame), plus Metal submission. The rest is reading ten PTYs and the app's run loop.

## Where the visible CPU went, and what paced it down

A Time Profiler trace (`TRACE=… app/run.sh core stream`, 10 s) of the first version
showed that drawing a card was cheap but *each frame* was not. Out of 788 ms of CPU, 165 ms were
the board's refresh, 121 ms Metal submission and completion, 119 ms GCD threads waking and
parking, 96 ms PTY reads and parsing, 36 ms present callbacks. Nearly all of it scales with
frames per second and thread wakeups, not with cells drawn. So:

- **Pacing.** The board draws at 120 Hz for half a second after the user types, clicks or
  scrolls; at up to 60 Hz while the focused card prints (30 Hz when more than three cards are
  printing at once); and cards in the background update together on a 15 Hz beat, so one frame
  (one wakeup, one submission) carries all of them.
- **One queue for all sessions.** The sessions' queues drain on one shared serial queue, so
  output from several agents is handled by one thread instead of waking one per agent.
- **Notifications per drawn frame.** A session tells the board about a change once, then stays
  quiet until the board has drawn it.
- **Read pacing.** A program writing faster than every 8 ms (on screen) or 50 ms (hidden) has its
  output gathered into one read. A slower one, like these agents, costs no timer.

After: 403 ms of CPU in the same 10 s, with rendering (refresh, submission, completion,
presenting) at ≈160 ms, that is ≈1.6% of one core for ten agents updating at once, ≈0.16% per
agent.

With one card focused (`FOCUS=1 app/run.sh`), that card draws at 30 Hz and the board
makes twice as many frames:

| One card focused | CPU visible | CPU switched away | Memory visible / away |
|---|---:|---:|---:|
| Streaming | 5.8% | 0.5% | 122 / 44 MB |
| Mixed | 4.4% | 0.75% | 122 / 45 MB |

Fifteen more frames a second for one card cost ≈1.5% of a core, so a frame carries a fixed
cost near 1 ms of CPU across threads (display link, submission, completion, presenting), far
above the ≈0.01 ms of drawing a card's cells.

## Fewer frames with a card focused

The pacing policy now lives in `FramePacer` (TerminalRenderer, unit-tested). `bench pacing`
replays the agents' timing (ClaudeSim, the same FakeAgent plays) on a simulated 60 Hz display
and counts frames and how long a change waits to be drawn:

| Stream, 10 agents | frames/s | card draws/s | wait mean | wait p95 |
|---|---:|---:|---:|---:|
| Every change at 60 Hz (first version) | 57.1 | 182 | 8 ms | 16 ms |
| Beat, no card focused | 15.0 | 137 | 42 ms | 64 ms |
| Beat, one card focused | 23.9 | 142 | 38 ms | 64 ms |
| Beat + ride-along, one card focused | **19.5** | 156 | **30 ms** | 62 ms |

The focused card and the 15 Hz background beat were out of phase, so they made separate
frames. Now background cards at least 40% into their interval ride along on the focused
card's frame: 19% fewer frames, and changes show sooner. The presenter also no longer wakes a
thread per frame to learn the GPU finished; it checks the previous frame's status at the next.
Measured with the shared surface below.

Measured in the paced app trace, the rest of a frame's render cost is per card, not per frame:
one render pass (≈0.03 ms) and one `nextDrawable` per changed card on the main thread, plus a
present callback each.

## One shared surface instead of a drawable per card

`SharedSurface` (TerminalRenderer, tested on the GPU) holds every visible terminal in one
IOSurface, double-buffered: a terminal is drawn into the buffer it isn't showing, so the window
server never reads pixels the GPU is writing. A frame draws every changed terminal in one
render pass; each card's layer shows its region (`contents` + `contentsRect`). No drawables, no
presents: the layers switch to the new pixels in one transaction once the GPU is done.

`bench layers` renders the same layer structure (flipped root, cards, regions of the shared
surface) offscreen with Core Animation's `CARenderer`, to check placement and orientation
without a window. Frame cost on the main thread, offscreen (`--surface own|shared`, 3 runs):

| Stream, cards changing | own surface per card | shared surface |
|---|---:|---:|
| 1 | 0.025–0.028 ms | 0.021–0.032 ms |
| 3 | 0.043–0.110 ms | **0.033–0.050 ms** |
| 10 | 0.192–0.224 ms | **0.076–0.149 ms** |

GPU time is within noise either way (0.2–2 ms).

Memory: two buffers of 10 terminals at 2x are ≈73 MB. The bench's "own" mode keeps one texture
per card, so there the shared surface costs ≈48 MB more (152 vs 104 MB in the e2e run). In the
app each `CAMetalLayer` kept two drawables, the same double buffering, and the app run shows
the same footprint either way (115–129 MB visible), with the CPU nearly halved.

## Showing a frame: flip a layer instead of handing over the surface

Thread CPU time per stage of the board's refresh (`FRAMES=<path>`, `CLOCK_THREAD_CPUTIME_ID`)
and the process total, with stages left out (`SKIP=metal`) to see what each costs on every
thread. One agent streaming, ≈14–17 frames a second, one card each:

| Per frame | before | flip |
|---|---:|---:|
| Pacer decision + pace | 0.03 ms | 0.02 ms |
| Updating the card's cells | 0.05 ms | 0.04 ms |
| GPU pass: encode, submit, wait (main thread) | 0.16 ms | 0.11 ms |
| Core Animation commit | 0.18 ms | **0.09 ms** |
| GPU work on Metal's own threads | ≈0.3 ms | ≈0.2 ms |

Drawing is not where the CPU goes; handing the frame to the system is. Setting a layer's
`contents` to the IOSurface on every frame made Core Animation pass the surface to the window
server again on every commit. Now each card has one layer per buffer, each keeping its
surface, and a frame only flips which one is hidden (`SharedSurface.show(_:from:on:)`). Two
screenshots 3 s apart (`SHOT=…`) show the cards updating, with no stale or torn frames.

Interleaved A/B in the same build (`PRESENT=swap` is the earlier way), background window, one
card focused, streaming:

| | before (swap) | flip |
|---|---:|---:|
| One agent working | 1.11%, 1.62% | 1.52%, 1.19% |
| Ten agents working | 3.05%, 3.46% | **2.75%, 2.88%** |
| Ten agents, CPU per frame (whole process) | 1.75–1.86 ms | **1.48–1.56 ms** |

With one agent the difference is inside the noise; with ten it holds on every run, ≈13% less.
Retaining no references in the command buffer was also tried and made no measurable
difference, so it was left out.

What a frame still costs is the system's: waking a thread, Metal's driver submitting and
completing the command buffer, and the commit to the window server. Below that, the only knob
left is how many frames are drawn, which is the pacing policy.

## The focused card at 60 Hz

Only one card is focused at a time, so it reads along at 60 Hz; with more than three cards
printing within the last second (`FramePacer.crowdLimit`), it drops to 30 Hz. A card draws
when it changes, so the cap only matters for output faster than the cap: the streaming agent
writes ≈17 times a second and gets ≈17 frames either way. Focusing the printing card
(`FOCUS=printing ACTIVE=1`) costs **1.7–2.0%** against 1.2–1.5% for the same agent in the
background, where the 15 Hz beat holds it to ≈14 frames: that is the price of following it at
its own pace.

## Target

The goal for "rendering costs next to nothing" in numbers, all measured on the release app
(10 agents open, background window):

| Board | Target | Measured |
|---|---:|---:|
| Ten agents open, none working | ≤ 0.1% | **0.02%** |
| Switched to another worktree | ≤ 0.5% | **0.1–0.6%** |
| One agent working, in the background | ≤ 1.5% | **1.1–1.5%** |
| One agent working, focused at 60 Hz | (chosen smoothness) | 1.7–2.0% |
| Ten agents working at once | ≤ 3% (≥ 4x below legacy's 11.5%) | **2.75–2.88%** |
| Memory, visible / switched away | ≤ 130 / 50 MB | **112–128 / 34–47 MB** |
| Typing echo | next frame (60–120 Hz) | 120 Hz for 0.5 s after input |

Accepted by the user as the definition of done for "rendering costs next to nothing". After
a switch nothing is drawn: what remains there is reading and parsing the agents' output (one
run with ten agents streaming read 0.57%). Percentages are of one core; this MacBook Air has 8. One agent streaming flat out costs about
1% of one core, a tenth of a percent of the machine.

## Reproduce

The tables above came from the first harness (a shell script patching a copy of the app;
records in `data/app.jsonl`). The scenarios now run as the `App` suite on package-benchmark,
the app built with `-DBENCH`, each sample one second of the app's CPU and footprint; the
stored baseline is `core` in `.benchmarkBaselines/`.

```sh
cd Benchmarks
alias bench='swift package --disable-sandbox benchmark'
bench --target App                                     # every scenario, about 5 minutes
bench --target App --filter 'app/1 of 10 working.*'    # one or a few
bench baseline compare core --target App               # this working copy against the baseline
```
