# Browser block cost

What a Playwright WebKit page costs to render on the board and to drive, measured before the
browser block was built. Read `../reports/browser.md` for what the numbers mean.

```sh
cd Benchmarks/Browser
npm install && npx playwright-core install webkit
node cost.mjs        # CPU and RSS per scenario (static, scrolling, animation, N contexts)
node cost2.mjs       # screencast idle overhead per fps, and the fps ceiling
node res.mjs         # screencast frame resolution versus viewport and device scale
node shot.mjs        # screenshot latency and size (jpeg/png, css/device scale)
swiftc -O decode.swift -o .decode && ./.decode frames   # app-side JPEG decode per frame
node fps.mjs         # screencast fps ceiling with fps 60/120/240
```

The zero-copy path: `embedder.m` is a minimal Playwright-compatible WebKit embedder (Playwright
drives it through `executablePath`); `host.m` shows another process's layer tree through
`CALayerHost`, the way the board would; `red.m` checks cross-process layer hosting alone.

```sh
W=~/Library/Caches/ms-playwright/webkit-2370
clang -fobjc-arc -F$W -framework Cocoa -framework WebKit -framework QuartzCore -Wno-deprecated-declarations embedder.m -o embedder
clang -fobjc-arc -framework Cocoa -framework QuartzCore host.m -o host
node drive.mjs       # Playwright on the embedder: navigate, AI snapshot, hover, screenshot
node zcbench.mjs     # frame rate (rAF gaps) and CPU while hosted: static, scrolling, canvas
node idle.mjs zc     # idle CPU and RSS, hosted on screen (without `zc`: stock headless)
```

The zero-copy scripts match processes by `zc/` in their path: run them from a folder named
`zc`, or edit the filters.

CPU is cumulative CPU time of this Node process plus every `ms-playwright/webkit` process,
divided by wall time (100% = one core). `cost.mjs` forwards every frame through a pipe, as the
sidecar will.
