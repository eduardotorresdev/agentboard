# What a browser block costs

Measured 2026-10-28 on this Mac (Apple Silicon, macOS 26.5), Playwright 1.64.1, WebKit build
2370, headless. Scripts and how to rerun them: `Benchmarks/Browser/`. Raw records:
`Benchmarks/Browser/results-2026-10-28.json`.

CPU is the whole WebKit process tree plus the Node process that drives it (the future sidecar),
as a share of one core. RSS is the same set of processes.

## Rendering on the board

The board shows a page through `page.screencast` (JPEG frames pushed by WebKit when the page
paints). Frames arrive only when something changed: a static page sends none.

| Scenario (Desktop Safari, 1280×720 CSS px) | CPU | Frames/s | KB/frame |
|---|---|---|---|
| Static page, no screencast | 0.2% | — | — |
| Static page, screencast on | **6–7%** (any `fps`) | 0 | — |
| User scrolling at 60 Hz, no screencast | 37% | — | — |
| User scrolling at 60 Hz, screencast default fps | 35–38% | 13–17 | 47 (640×360) – 138 (1280×720) |
| Real site (Wikipedia) scrolling, screencast | 42% | 16 | 229 |
| CSS spinner, no screencast / screencast | 1.5% / 11.6% | 19 | 21 |
| Full-repaint canvas, screencast default fps | 31% | 18 | 65 |
| Full-repaint canvas, `fps: 30` | 38% | 34 | 65 |
| Full-repaint canvas, `fps: 60` | 44% | 42 | 65 |
| iPhone 15, scrolling (via `scrollBy`), screencast | 36–39% | 18–20 | 28–33 |

- **Rendering a page that moves costs the same with or without the board watching it.** Scrolling
  costs ~37% of a core with no screencast at all. The screencast adds little on top, except
  its idle overhead.
- **An open screencast costs 6–7% of a core even when nothing paints.** It goes back to 0 the
  moment it stops. A screencast per visible card is therefore not affordable; only the card
  being used may have one.
- **The default frame rate tops out at ~18 fps.** With `fps: 60` it reaches ~42 fps (the page
  itself runs at 61 Hz), for ~+13% of a core on a full repaint.
- **Latency is fine.** Click to next frame: 25–60 ms. Wheel to next frame: p50 40–54 ms, p95
  56–93 ms on desktop; p50 14–20 ms, p95 45 ms on iPhone.
- **Frames never exceed CSS pixels.** A 1280×720 viewport at device scale 2 streams at most
  1280×720 (default size: 800 px on the long side). An iPhone 15 (393×659, scale 3) streams
  393×659 even when asked for 786×1318. On a Retina screen a card shown at its page's size
  looks soft while live; a device-scale screenshot after the page settles makes it sharp.
- Node (the sidecar) spends 2–5% of a core forwarding 40 frames/s.

## Screencast frame rate ceiling

The WebKit screencast is flow-controlled by acks: WebKit sends the next frame only after the
previous one is acknowledged, and Playwright's `fps` option throttles on the client side. WebKit
reads each frame back from the GPU and encodes JPEG on its side, so even unthrottled it never
reaches the display's rate:

| `fps` option | Delivered (desktop / iPhone) | Gap p95 | CPU |
|---|---|---|---|
| 60 | 18–33 fps | 55–65 ms | 27–39% |
| 120 | 35–44 fps | 50–54 ms | 39–48% |
| 240 | 48–54 fps | 33–42 ms | 51–54% |

**A screencast cannot show a page at the display's frame rate.** On a 60 Hz screen the gaps
are visible as stutter while scrolling.

## Zero-copy: hosting the page's layers

Playwright's "headless" WebKit on macOS is a real `WKWebView` in a borderless window placed at
x = −10000, rendered and composited on the GPU like any window. A minimal embedder of our own
(`Benchmarks/Browser/embedder.m`, launched by Playwright through `executablePath`) exposes that
window's `CAContext` id. Another process shows it with a `CALayerHost` (private QuartzCore API,
the same mechanism WebKit and Chromium use between their own processes). Playwright drives the
embedder unchanged: navigation, AI snapshots, refs, hover, and screenshots all work.

| Scenario (Desktop Safari, hosted at 0.5×) | Page fps | Gap p50 / p95 | CPU WebKit | CPU in the hosting process |
|---|---|---|---|---|
| Idle page, hosted on screen | — | — | **0.0%** | 0% |
| Heavy page, scrolling 60 Hz (wheel through Playwright) | **60** | 17 / 18 ms | 17% | 0% |
| Wikipedia, scrolling | **60** | 17 / 18 ms | 27–29% | 0% |
| Full-repaint canvas | **60** | 17 / 18 ms | 29–32% | 0% |

- **The page runs at the display's rate**, with the same gaps as a native window. The test
  Mac has a 60 Hz screen. 120 Hz (ProMotion) is not measured yet: the offscreen window has to
  sit on, or be told about, the screen the board is on.
- **Hosting is free for the app**: compositing happens in the WindowServer on the GPU, and
  zooming the board is a layer transform, with no re-render.
- **It is cheaper than the screencast for the same page** (17% vs 35–38% scrolling, 29–32% vs
  44–51% on a canvas) because nothing is read back, encoded, sent, or decoded.
- The 8–11% Node CPU while scrolling is the test sending a wheel event every 16 ms through
  Playwright; native input forwarded straight to the embedder would not go through Node.
- Memory is the same as stock headless: 287 MB for one page, 483 MB for three.
- The offscreen window takes the main screen's backing scale (2× here), so the hosted page is
  rendered at Retina resolution, unlike screencast frames (CSS pixels at most).

## ScreenCaptureKit (public API) on the page window

`Benchmarks/Browser/sck.swift` captures another process's window with ScreenCaptureKit (needs
the Screen Recording permission) and counts complete frames. The page animated at 60 fps the
whole time (measured with rAF inside the page), so every gap below comes from the capture.

| Page window | Delivered | Gap p50 / p95 | CPU of the capture |
|---|---|---|---|
| Stock headless, off screen (x = −10000) | 15–31 fps | 17–80 / 88–128 ms | 0.6–1.8% |
| Our embedder, on screen but covered by another window | 26–31 fps | 18–30 / 85 ms | 0.9–1.3% |
| Our embedder, on screen, alpha 0 / 0.01 | 0 / 26 fps | — / 86 ms | 0.8% |
| Stock headed, frontmost and visible | **57–60 fps** | 17 / 19–20 ms | 2.2% |

- **The WindowServer only composites a window at full rate when the user can see it.** Off
  screen, covered, or transparent, it drops to 15–31 fps. A hidden page window captured with
  ScreenCaptureKit therefore stutters like the screencast does.
- Frames are sharp (786×1318 for a 393×659 window) and the capture is cheap.
- Stock headless keeps Playwright's mobile emulation (`innerWidth 393 · dpr 3 · touch true ·
  hover:none true`). The minimal spike embedder does not yet: it reported dpr 1.2, so a real
  embedder must port all of Playwright's embedder, not only the delegate methods.

## In the app

| Work | Cost |
|---|---|
| ImageIO decode, 1280×720 JPEG | 1.05 ms/frame: 4.4% of a core at 42 fps |
| ImageIO decode, 640×360 / 393×659 | 0.4–0.5 ms/frame |
| Screenshot, JPEG q70 at CSS scale (Wikipedia, 1280×720) | 41 ms, 196 KB |
| Screenshot, JPEG q70 at device scale (2560×1440) | 57 ms, 526 KB |
| Screenshot, PNG at device scale | 75 ms, 652 KB |

## Memory

| State | RSS |
|---|---|
| WebKit launched, no context | 136–167 MB |
| 1 / 3 / 6 contexts, each with a heavy page | 297 / 425 / 678 MB |
| All contexts closed again | 136 MB |

That is roughly 65–85 MB per open page on top of ~150 MB for the browser itself. Closing a
context gives its memory back.

The first `webkit.launch()` after installing took 5.3 s (Gatekeeper checks the new binary).
After that, a launch takes 0.2–0.55 s, a new context and page 0.27–0.53 s, and suspending a
page (save `storageState`, close the context) then bringing it back on a simple page takes
~0.5 s.

## Disk

WebKit 299 MB and FFmpeg 3 MB in `~/Library/Caches/ms-playwright` (shared with any other
Playwright on the machine), plus playwright-core 13 MB.

## Not supported on mobile emulation

`mouse.wheel` throws on contexts created with `isMobile: true` (every iPhone and iPad
preset): "Mouse wheel is not supported in mobile WebKit". Scrolling those pages has to go
through `scrollBy` on the scrollable element under the pointer (measured above).
