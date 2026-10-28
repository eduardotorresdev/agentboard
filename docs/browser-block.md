# Browser block: plan

A board element that is a real web page: Playwright WebKit underneath, shown live on the canvas
at the display's frame rate, usable by the developer with mouse and keyboard, and driven by any
agent connected to it by a line, through the board's MCP tools.

Status: planned. Measurements this plan rests on: `Benchmarks/reports/browser.md` (scripts in
`Benchmarks/Browser/`). Messaging, tools and lines come from the bridge in `Sources/Connections`
(`ToolCatalog`, `ToolProvider`, `MessageBus`, `BoardElement`, `ConnectorRouter`).

## 1. What it does

### For the developer

- **Add a browser** from the canvas toolbar, next to Add agent. The menu offers devices, each
  with one line on what it is:
  - Phone: iPhone 17, 402×681 at 3×, touch, mobile Safari.
  - Tablet: iPad Pro 11, 834×1194, touch.
  - Desktop: 1440×900 at 2×, desktop Safari (Playwright's Desktop Safari is 1280×720).
  - Responsive: the page is as wide as the card; resize the card to test breakpoints.
  - Other device…: any Playwright WebKit preset (iPhone, iPad, Pixel and Galaxy emulated in
    WebKit, Desktop Safari) or a custom width, height, scale, mobile, and touch.
- **The card** shows the page live. Its title bar shows the page's title and address, back,
  forward, reload, and a chip with the device ("iPhone 17 · 402×681"). Clicking the address
  makes it an editable field (the only bordered control on the card).
- **The page keeps its device size.** Resizing a card scales the page with a locked aspect
  ratio. The viewport only changes through the device chip (or Responsive). Rotate is in the
  chip's menu for devices that have a landscape variant.
- **Using it**: click the card to focus it. Mouse, trackpad scroll (with momentum), keyboard,
  IME, and copy/paste then go to the page. Escape or a click on the canvas gives focus back to
  the board. Zooming the board never re-renders the page; it is a layer transform.
- **Connecting**: draw a line from an agent to the browser, as between agents. A connected agent
  gets the browser tools; it can only reach browsers it has a line to.
- **Watching an agent work**: while an agent acts, the title bar shows who and what ("Claude ·
  click "Sign in"") and a violet pulse marks the point on the page (drawn by the board, never
  into the page, so screenshots stay clean).
- **Attention**: a browser asks for the developer only when a JavaScript dialog waits with no
  agent to answer it, when the page crashed, or when a site asks for HTTP credentials. The
  card's title dot turns orange, like an agent waiting for input. Nothing else draws attention.
- **Data**: each browser has its own profile (cookies, storage, IndexedDB), kept across launches
  so a login survives. The card menu has Clear site data and Open trace (when one was
  recorded).

### For agents (MCP tools on the board's server)

All tools are listed for every agent, so the tool list never changes. A call from an agent with
no line to a browser fails with "No browser is connected to you…". When an agent is connected to
several browsers, `browser` (the name `browser_list` shows) picks one; it is optional when only
one is connected.

Targets: `target` is a ref from the latest snapshot (`e12`, `f1e3` inside an iframe) or a
Playwright selector (`role=button[name="Save"]`, `text=Sign in`, `css=.cta`, `xpath=//a`,
`data-testid=save`, or plain CSS). Refs are the default path: snapshot, then act on a ref.
Coordinates are CSS pixels of the viewport, the same space as snapshot boxes.

Every action answers with a short state report instead of a full snapshot:

```
Clicked button "Sign in".
Page: https://app.local/dashboard · "Dashboard" (tab 1 of 2)
Since your last call: 1 console error, 1 failed request (GET /api/me 401),
download "report.csv" saved to /…/Browsers/<id>/downloads/report.csv.
A confirm dialog is waiting: "Discard changes?". Answer it with browser_dialog.
```

`snapshot: true` on any action appends the page's snapshot after it settles.

| Tool | What it does | Playwright underneath |
|---|---|---|
| `browser_list` | Browsers connected to you: name, device, viewport, address, state | — |
| `browser_open` | Opens a new browser next to you and connects it: `device` (preset name or phone/tablet/desktop/responsive), or `width`, `height`, `scale`, `mobile`, `touch`; `url`, `name` | `browser.newContext(devices[…])` |
| `browser_close` | Closes a browser you opened | `context.close()` |
| `browser_navigate` | `url`, or `action: back/forward/reload`; `waitUntil` | `goto`, `goBack`, `goForward`, `reload` |
| `browser_snapshot` | The page as an accessibility tree with refs, iframes included; `target` to scope, `depth`, `boxes` | `ariaSnapshot({ mode: "ai" })` |
| `browser_screenshot` | Image in the result plus a saved file. `fullPage`, `target` (element), `clip` (region), `mask` (targets), `animations: "disabled"`, `caret: "hide"`, `scale: css/device`, `format`, `quality`, `path`. `compareTo` + `threshold` diff against a saved image | `page/locator.screenshot`, pixel diff in the sidecar |
| `browser_click` | `target` or `x, y`; `button`, `clickCount`, `modifiers`, `position` | `locator.click`, `mouse.click` |
| `browser_tap` | Touch tap on `target` or `x, y` (touch devices) | `locator.tap`, `touchscreen.tap` |
| `browser_hover` | `target` or `x, y` | `locator.hover` |
| `browser_drag` | `from` → `to` (targets or points) | `locator.dragTo`, `mouse` |
| `browser_type` | `target`, `text`; `mode: fill/keys`, `submit`, `clear` | `fill`, `pressSequentially` |
| `browser_press` | Key or chord (`Meta+A`, `Enter`), optionally on `target` | `keyboard.press` |
| `browser_select` | Options of a `<select>` | `selectOption` |
| `browser_upload` | `files` into a file input, or into the chooser a click on `target` opens | `setInputFiles`, `filechooser` |
| `browser_scroll` | Scroll the page or `target` by `dx, dy`, or bring `target` into view | `mouse.wheel`; `scrollBy` on mobile presets |
| `browser_mouse` | Raw `move/down/up/wheel` at `x, y` | `mouse.*` |
| `browser_wait` | For `text`, `textGone`, `target` state, `url`, load state, or `ms` | auto-wait, `waitFor*` |
| `browser_evaluate` | Runs a function in the page (or on `target`) and returns its JSON | `evaluate` |
| `browser_tabs` | `list/select/new/close`. Popups open as tabs | `context.pages()`, `popup` |
| `browser_dialog` | Answers the waiting dialog (`accept`, `promptText`), or sets a policy (`ask/accept/dismiss`) | `dialog` event |
| `browser_console` | Console messages and uncaught errors since a cursor; `level`, `limit` | `console`, `pageerror` |
| `browser_network` | Requests since a cursor: method, URL, status, type, timing, failure; `id` for headers and body; `websockets` for frames | `request*`, `response`, `websocket` events |
| `browser_route` | Mock, change, delay, or block requests by URL pattern: `fulfill` (status, headers, body/json/path), `abort`, `modify` (headers, method, postData), `delayMs`, `times`; `list`, `remove`, `clear` | `context.route` |
| `browser_har` | `record_start/record_stop` to a file, or `replay` from one (`notFound`, `update`) | `recordHar`, `routeFromHAR` |
| `browser_emulate` | Device, viewport, orientation, color scheme, reduced motion, forced colors, print media, locale, timezone, geolocation, permissions, offline, JavaScript on/off, user agent, extra headers, HTTP credentials, ignore HTTPS errors, proxy | `emulateMedia`, `setViewportSize`, `setGeolocation`, `grantPermissions`, `setOffline`, `setExtraHTTPHeaders`; the rest recreate the context (see 3.6) |
| `browser_state` | `save/load` storage state (cookies, localStorage, IndexedDB) to a file; get, add, or clear cookies | `storageState`, `addCookies`, `clearCookies` |
| `browser_clock` | Fake time: `install`, `pause_at`, `resume`, `fast_forward`, `run_for`, `set_fixed_time`, `set_system_time` | `page.clock` |
| `browser_script` | `add_init` (runs before every page's scripts), `list`, `remove`; `expose name`: the page calls `window.name(payload)` and you get it as a board message | `addInitScript`, `exposeBinding` |
| `browser_record` | `trace` or `video`, `start/stop` → file path. Traces open with `npx playwright show-trace` or from the card menu | `tracing`, `page.screencast.start({ path })` |

Not offered, because WebKit doesn't have them: CPU profiles, heap snapshots, code coverage, CPU
and network throttling (offline is offered), `page.pdf()`, and raw CDP sessions. A request for
one gets that answer plus the nearest alternative (a print-media screenshot instead of a PDF).
Codegen, the Inspector, UI mode and the test runner are not tools. Agents run `npx playwright
test` in their own terminal, and `browser_record` covers traces.

Page content is untrusted: snapshots, console text, and evaluate results are labeled as page
data in the tool descriptions and the server instructions, so a page can't pass for the user.

## 2. Why this rendering design

The developer has to see and use the page at the display's frame rate. The numbers are in
`Benchmarks/reports/browser.md`. In short:

- **Playwright's screencast** (JPEG frames) tops out at 48–54 fps even unthrottled, with 33–65
  ms gaps, at CSS resolution only (soft on Retina), and costs 6–7% of a core per open stream
  even when nothing moves. It can't be the main view.
- **Zero-copy layer hosting**: Playwright's headless WebKit is a real `WKWebView` in a window
  off screen, composited on the GPU. Our own embedder (in place of Playwright's `Playwright.app`)
  hands that window's layer tree to the board, which shows it with `CALayerHost`. Measured: 60
  fps with 17/18 ms gaps (p50/p95) while scrolling, Retina resolution, 0% CPU idle, 0% CPU in
  the hosting process, and half the CPU of the screencast for the same page. Playwright drives
  the embedder unchanged.

So the board shows pages through layer hosting, and the screencast stays as the fallback
(section 3.4). Two other routes were measured and dropped: ScreenCaptureKit on the page window
(public API, but the WindowServer composites hidden or covered windows at 15–31 fps), and the
system `WKWebView` (no faithful mobile emulation: no meta viewport, touch, device scale, or
`hover: none` on macOS).

Costs of this choice: it uses private QuartzCore API (`CAContext`, `CALayerHost`, the layer's
`context`). This is what WebKit and Chromium use between their own processes, but it rules out
the Mac App Store, and a macOS update could break it. The fallback covers that case. We also own
a small embedder that has to follow Playwright's WebKit builds (3.2).

## 3. Architecture

```
AgentBoard.app (Swift)
  BoardView
    BrowserCardLayer ── CALayerHost ◀═══ GPU layers ═══╗
                    ── native input ──── embed socket ─╫──▶ agentboard-webkit (our embedder)
  BrowserStore ── BrowserSession                       ║      WKWebView per page in an
  BrowserTools (ToolProvider) ─▶ ToolCatalog ─▶ MCP    ║      off-screen window; reports each
  BrowserHost ── stdio, framed JSON ─▶ browser-host    ║      window's CAContext id
                                       (Node,          ║           ▲
                                       playwright-core)╚═══════════╝ Playwright pipe (fd 3/4)
```

Three processes besides WebKit's own (WebContent, Networking, GPU):

1. **The app** owns cards, persistence, input focus, and the tools agents call.
2. **`browser-host`**, a Node sidecar running playwright-core. It owns the Playwright objects
   (one `Browser`, one `BrowserContext` per browser block, its pages), turns tool calls into
   Playwright calls, keeps the event logs (console, network, downloads, dialogs), and records
   traces, HARs and videos. One sidecar serves every block.
3. **`agentboard-webkit`**, our embedder, launched by Playwright (`webkit.launch({
   executablePath, env: { DYLD_FRAMEWORK_PATH } })`) over its inspector pipe. It creates the
   `WKWebView`s Playwright asks for, exports their layers, and receives the developer's input.

### 3.1 The sidecar (`Sources/BrowserRuntime/Host/`)

- Plain ESM JavaScript with `// @ts-check`, no build step: `host.mjs` (process entry and
  dispatch), `wire.mjs` (framing), `session.mjs` (one block: context, pages, logs, mode),
  `tools/*.mjs` (one file per tool group), `targets.mjs` (ref vs selector), `devices.mjs`
  (presets), `test/` (`node --test`).
- `package.json` pins `playwright-core` to an exact version (1.64.1 today). Shipped as a
  resource of the `BrowserRuntime` target (`.copy("Host")`). On first use the app copies it to
  `~/Library/Application Support/AgentBoard/BrowserHost/<version>/` and runs `npm ci`
  there, then `node node_modules/playwright-core/cli.js install webkit`. WebKit goes into the
  shared `~/Library/Caches/ms-playwright` (299 MB, reused by any other Playwright on the
  machine).
- Node is the user's, found in the login-shell PATH the same way agents are (`AgentStore`
  resolves it). It needs Node 18 or newer. Without it, the card says so and links to
  nodejs.org. Bundling a Node binary (~100 MB) is postponed until wider distribution.
- **Wire protocol** on stdin/stdout. Each frame is `[u32 BE length][u8 type][payload]`. Type 1
  is a UTF-8 JSON message. Type 2 is binary (fallback frames, screenshot bytes):
  `[u16 BE header length][JSON header][bytes]`. stderr is the log. Messages:
  - request `{ "id": 7, "method": "click", "params": { "block": "<uuid>", "target": "e12" } }`
  - response `{ "id": 7, "result": { … } }` or `{ "id": 7, "error": { "message": "…", "code": "timeout" } }`
  - event `{ "event": "dialog", "params": { "block": "<uuid>", "type": "confirm", "message": "…" } }`
  Methods are the tool names without the `browser_` prefix, plus internal ones: `hello`
  (versions), `openBlock` / `suspendBlock` / `resumeBlock` / `closeBlock`, `setRenderMode`,
  `input` (fallback path only), `shutdown`.
- **Per-block action queue**: actions on one block run one at a time, in arrival order, so two
  agents sharing a browser never interleave a click inside a type. Reads (`list`, `console`,
  `network`) skip the queue. Default timeout 30 s, at most 120 s. An MCP cancellation aborts
  the running action (`AbortSignal` where Playwright takes one, otherwise the timeout).
- **Logs** are ring buffers per block (console 2,000 entries, network 5,000 requests, with
  bodies only fetched on demand). Each agent has its own cursor, so "since your last call" is
  per agent.
- **Artifacts** go to `~/Library/Application Support/AgentBoard/Browsers/<block>/` (`shots/`,
  `downloads/`, `traces/`, `videos/`, `har/`). Any tool that writes a file also takes a `path`
  (for example inside the worktree, for tests). The folder is capped at 1 GB, oldest first, and
  deleted with the block.

### 3.2 The embedder (`Sources/BrowserEmbedder/`, Objective-C target)

> **Spike status (2026-10-28):** instead of porting the embedder, the spike keeps Playwright's
> stock `Playwright.app` (so its mobile emulation stays exact) and loads a small library into it
> with `DYLD_INSERT_LIBRARIES` (`Sources/BrowserInjection`, built as
> `libBrowserInjection.dylib`). The sidecar launches `Playwright.app` directly as
> `executablePath` because `pw_run.sh` (bash) loses `DYLD_*` variables. The library finds each
> page's `WKWebView` by the `about:blank#agentboard=<id>` marker of its first URL and appends
> `{page, contextID, width, height}` lines to `AGENTBOARD_EVENTS`; the card hosts that context.
> Input goes through Playwright (`mouse`, `keyboard`, `scrollBy` on mobile), not native events.
> The full port below stays the plan for native input (momentum scrolling, IME, cursors).

A port of Playwright's whole macOS embedder (`browser_patches/webkit/embedder/Playwright/mac`,
BSD-licensed, headless path), not only its delegate methods: the minimal spike embedder lost
Playwright's mobile emulation (`devicePixelRatio` 1.2 instead of 3 on iPhone 15). Plus:

- **Builds without Playwright's headers.** It declares the four `_WKBrowserInspectorDelegate`
  methods and the few private selectors it uses itself, and looks up `_WKBrowserInspector` with
  `NSClassFromString`. It links against the system WebKit at build time. At runtime
  `DYLD_FRAMEWORK_PATH` points it at Playwright's WebKit build. It is built by SwiftPM like any
  other target and copied next to the sidecar.
- **Page windows**: borderless windows at x = −10000 with occlusion detection off (what Playwright
  does), sized to the viewport, on the screen the board's window is on, so the page's display
  link runs at that screen's refresh rate (60 or 120 Hz).
- **Export**: once a page's window has a layer tree, the embedder reports `{ page, session,
  contextId }` over the embed socket. `contextId` comes from the window's own `CAContext`. It
  never takes a layer away from AppKit (the spike showed a blank result when it does).
- **Embed socket**: a Unix socket at a path the app passes down through the sidecar's
  environment (`AGENTBOARD_EMBED_SOCKET`). The embedder connects to the app. Messages: page
  created/closed (with session, view id, opener), context id changed, cursor changed, and, from
  the app, input events.
- **Native input**: the app sends compact input events (kind, location in view points,
  modifiers, buttons, click count, scroll deltas with phase and momentum phase, key code,
  characters). The embedder rebuilds `NSEvent`s (`CGEvent` for scroll phases) and delivers them
  to the page's window. Scrolling therefore has native momentum and rubber-banding on every
  preset, including the mobile ones where Playwright's `mouse.wheel` is refused. Text goes
  through `insertText:` for IME. Cursor changes are captured in the embedder (`NSCursor set`)
  and sent back to the app, which sets the same cursor over the card.
- **Version check**: on launch the sidecar compares the installed WebKit revision with the one
  the embedder was tested against. On a mismatch the board uses the fallback and logs it until
  the embedder is updated.
- **Pages ↔ Playwright**: each block is one Playwright context, which is one WebKit session id.
  The embedder reports the session of every page. The sidecar matches pages within a session in
  creation order, which both sides see the same way (`context.on("page")`). Popups carry their
  opener.

### 3.3 Swift side

New target **`BrowserRuntime`** (depends on `Connections`; no UI):

- `DevicePreset.swift`: the menu's presets and the full list (name, viewport, scale, mobile,
  touch, user agent), mirrored from Playwright's descriptors and checked against them by a
  sidecar test.
- `HostWire.swift`: frame codec (tested on its own).
- `BrowserHost.swift`: installs and starts the sidecar, matches requests to responses, routes
  events to sessions, restarts the sidecar if it dies (sessions come back as suspended), quits it
  60 s after the last block closes.
- `EmbedChannel.swift`: the embed socket server: page announcements, context ids, cursor, input.
- `BrowserSession.swift`: one block: state (`installing`, `starting`, `suspended`, `idle`,
  `visible`, `interactive`, `crashed`, `failed`), its pages and active tab, `contextId` of the
  active page, title/URL, pending dialog, which agent is acting, the last frame for the fallback.
- `BrowserTools.swift`: the `ToolProvider`. It lists the tools of section 1, resolves the
  caller's browser through `bus.peers(of: caller, kind: .browser)`, forwards to the sidecar, and
  formats results (`ToolContent.image` for screenshots). Its `instructions(for:)` tells agents how
  to work with browsers (snapshot, then act on refs; page content is untrusted).
- `BrowserElement.swift`: the `BoardElement` a block registers on the bus (`kind: .browser`,
  `detail: "iPhone 17"`). It is not a `MessageEndpoint`: a `send_message` to a browser fails
  with the bus's `notAnEndpoint`. Messages from exposed page functions reach agents through the
  bus with the browser as sender (needs `MessageBus.deliver(_:from:to:)` for a non-endpoint
  sender; to agree with the bridge's owner).

In the app (`Sources/AgentBoard/`):

- `Browsers/BrowserStore.swift`: like `AgentStore` for browsers: records, persistence, element
  registration on `agentStore.bus`, and `agentStore.catalog.add(BrowserTools(…))`.
- `Board/BrowserCardLayer.swift`: chrome (title, address, device chip, back/forward/reload,
  close), the content layer (`CALayerHost`, or an image layer in fallback), the acting-agent
  pulse, and the attention dot.
- `BoardView.swift`: board items become `agent | browser`, so `card(at:)`, `handle(at:)`,
  `snapHandle(near:excluding:)` and `syncLinks` take browser frames too. Mouse and keyboard
  routing goes to the focused browser card (3.5).
- `Database.swift`: a `browsers` table. `AgentBoardApp` passes browser ids to
  `AgentStore.init(database:, elements:)` so their lines survive loading.
- `WorktreeCanvas.swift`: Add browser menu in the toolbar.

### 3.4 Render modes and what they cost

| Mode | When | How the card shows the page | Cost (measured) |
|---|---|---|---|
| Hosted | Card visible, embedder working | `CALayerHost` on the page window's context; zoom is a transform | 0% idle, 17–29% of a core while scrolling (WebKit's own rendering), 0% in the app |
| Hidden | Card off screen, other worktree, window hidden | Host layer removed; the page keeps running (occlusion detection is off), so agents keep working | An idle page: 0.0–0.3% |
| Suspended | Hidden and no agent call for 10 min | Last image; context closed after saving storage state, URL and scroll | Memory back (~65–85 MB per page); ~0.5 s to resume |
| Fallback | Embedder unusable (WebKit revision mismatch, macOS change) | `page.screencast` JPEG frames while focused (`fps: 240`, size = card pixels capped at CSS), a device-scale screenshot after 250 ms without frames, and screenshots on page change while unfocused | 6–7% open stream, 35–50% while active, 48–54 fps |

At most the pages on screen are hosted, and hosting costs nothing while they don't paint. The
expensive moments are the ones where the page itself works (scroll, animation), and those cost
the same as in Safari.

### 3.5 Input mapping

- Board point → card content rect → page point: subtract the card's content origin, divide by
  the card's scale (card width / viewport width), at any board zoom. Letterboxing is impossible
  because the aspect ratio is locked.
- Mouse: down/up/drag/move go to the embedder as native events. Moves are coalesced to one per
  display frame. Hover only goes through while the pointer is over the card.
- Touch presets: the developer's clicks go in as mouse events; whether pages that only listen
  to touch events react to them is a Phase 0 check (if not, the embedder turns clicks into taps).
  `browser_tap` is for agents.
- Scroll: trackpad phases and momentum are forwarded as is.
- Keyboard: while a browser card has focus, every key goes to the page except Escape (back to
  the board). Cmd+C/V/X/A work through the page's own editing commands. Board shortcuts (zoom)
  need the canvas focused.
- Fallback mode uses Playwright input (`mouse.*`, `keyboard.*`, `scrollBy` on mobile), with
  the latencies measured in the report (25–60 ms click to frame).

### 3.6 Emulation changes that need a new context

Playwright fixes viewport-independent device traits (`isMobile`, `hasTouch`, `deviceScaleFactor`,
`userAgent`, `locale`, `timezoneId`, `javaScriptEnabled`, `proxy`, `httpCredentials`,
`ignoreHTTPSErrors`) when it creates a context. Changing one recreates the context: save
storage state, close, create with the new options, restore storage, go back to the URL. The
tool's answer says this happened, so the agent knows in-memory page state is gone. Everything
else (`emulateMedia`, viewport, geolocation, permissions, offline, headers) applies live.

### 3.7 Persistence

`browsers` table: `id`, `worktree`, `name`, `preset` (JSON: device name or custom traits),
`url`, `x`, `y`, `width`, `height`. Storage state lives in
`Browsers/<id>/state.json`, saved on suspend, quit, and every 60 s while a block is open.
Connections need no change: they store element ids. Routes, init scripts, exposed functions,
HAR replay, and the fake clock belong to the running session and are not restored. The tool
descriptions say so.

### 3.8 Security

- MCP stays on 127.0.0.1 with per-element tokens (the bridge's `ToolServer`). The embed socket
  lives in `~/Library/Application Support/AgentBoard/`, mode 0600, and accepts one connection per embedder
  launch with a token from the environment.
- Agents can only touch browsers they are connected to. `browser_close` only closes browsers
  the caller opened. Closing anything else is the developer's call.
- `browser_evaluate` runs in the page, not in the sidecar. `browser_route` takes data, not
  functions, so no agent code runs in Node.
- Downloads are saved, never opened.

## 4. Coordination with the bridge

The bridge already provides what the block needs: `ToolProvider` with async calls (a slow
browser call doesn't block other requests), image results, a stable tool list, `ElementKind.browser`,
`BoardElement`, `peers(of:kind:)`, sides on connections, and a router that takes any card's frame.
Done on the bridge side since:

1. `MessageBus.deliver(_ text:, from:, to:) throws -> Message`: any registered `BoardElement`
   can send, including a browser. The target must be connected to it and be a
   `MessageEndpoint`. Exposed page functions use it.
2. `AgentStore.init(database:, elements:)`: stored connections survive when their ends are
   in `elements`. `AgentBoardApp` loads `BrowserStore` first and passes its ids.

Ours, in Phase 1 (the files are free):

3. A `BoardItem` model in `BoardView` (`agent(AgentRecord)` / `browser(BrowserRecord)`, with
   id and frame). `card(at:)`, `handle(at:)`, `snapHandle(near:excluding:)`, `record(_:)`,
   and `syncLinks`' `frames` iterate it. `AgentStore.connections(in:)` keeps lines whose ends
   are any item of the worktree. The router input stays in connection-creation order so
   existing lines don't move (covered by `Tests/ConnectionsTests`). Browser cards host their
   `CALayerHost` inside `cardsLayer`, above `linksLayer`.

## 5. Phases

Each phase ends with something the developer can use, tests green, and the cost re-measured
with `Benchmarks/Browser`.

**Phase 0: harden the spike (1–2 days).** The embedder target builds with SwiftPM against the
system SDK. Playwright drives it, including popups, dialogs, downloads, and context recreation.
A test app hosts two pages at once. Checks: mobile emulation identical to stock Playwright (dpr, touch, `hover: none`, meta
viewport) and the frame rate re-measured with the iPhone and iPad presets; 120 Hz on a ProMotion display (or an external
120 Hz monitor); native scroll with momentum on a mobile preset; keyboard, IME, and Cmd+C/V;
clicks on touch-only pages; cursor; the page window following the board's screen. Exit: same numbers as the spike, plus these checks
passing, or the fallback promoted to the main view with the trade-off written down.

**Phase 1: the block on the board.** Install flow (with progress on the card), sidecar,
`BrowserRuntime`, `BrowserStore`, `browsers` table, Add browser menu with the five choices,
hosted rendering, focus and input, address bar, back/forward/reload, device chip, lines to
agents, persistence and relaunch. Tools: `list`, `open`, `close`, `navigate`, `snapshot`,
`screenshot`, `click`, `type`, `press`, `wait`, `evaluate`, `console`, `tabs`, `dialog`. Exit:
a Claude agent connected by a line opens a local dev server on a phone and a desktop browser,
signs in, and returns screenshots of both, while the developer scrolls one of them at 60 fps.

**Phase 2: complete automation.** `tap`, `hover`, `drag`, `select`, `upload`, `scroll`, `mouse`,
`network` (with websockets), `route`, `emulate`, `state`, `clock`, `script` (init scripts, and
exposed functions as board messages), downloads in reports, iframes through refs, the acting-agent
pulse, attention states, suspend/resume, fallback mode.

**Phase 3: recording and comparison.** `record` (trace, video), `har`, `screenshot.compareTo`,
Open trace from the card, the cursor mirrored over cards.

## 6. Tests

- **Sidecar** (`node --test`, no browser): framing, ref vs selector parsing, per-agent cursors,
  queueing and timeouts, preset table. With WebKit (`AGENTBOARD_BROWSER_TESTS=1`): every tool
  against local fixture pages (forms, iframes, popups, dialogs, downloads, websockets), in both
  the embedder and stock headless.
- **Swift** (`BrowserRuntimeTests`): wire codec; `BrowserHost` against a fake sidecar (a
  script speaking the protocol): request/response matching, events, restart after a crash;
  `BrowserSession` state machine (visible/hidden/suspended/fallback transitions);
  `BrowserTools`: only connected browsers, choosing among several, errors for none or an
  unknown name, `browser_close` limited to the opener, image results; card point ↔ page point
  mapping at several zooms and card sizes.
- **Board**: connections between agents and browsers survive a relaunch; hit testing and
  handles on browser cards.
- **Cost**: `Benchmarks/Browser/zcbench.mjs` and `idle.mjs` become the regression check for
  rendering; the budget is the numbers in section 3.4.

## 7. Decisions to confirm

1. ~~Rendering~~ **Decided (2026-10-28): zero-copy layer hosting (`CAContext`/`CALayerHost`)
   from our own embedder, with the screencast as the automatic fallback.** Considered and
   rejected: the screencast as the main view (18–54 fps, stutters), ScreenCaptureKit on the page
   window (public, but the WindowServer drops hidden windows to 15–31 fps), and the system
   `WKWebView` (no faithful mobile emulation, a must-have). The private API is the one Chromium,
   and so every Electron app, relies on; outside the Mac App Store nothing blocks it, and the
   fallback covers a macOS change.
2. ~~Node~~ **Decided (2026-10-28): the app provisions it.** Node 18+ from the user's login-shell
   PATH if there is one, otherwise the official Node 24 build downloaded (checked against
   `SHASUMS256.txt`) into `~/Library/Application Support/AgentBoard/Browsers/Node`. Playwright
   (`playwright-core`, pinned) is installed with that Node's npm into `Browsers/Host`, and
   WebKit into the shared Playwright cache (`BrowserHost.swift`).
3. **Profiles persist per browser** (logins survive relaunches); Clear site data on the card.
4. **Agents may close only the browsers they opened.**
