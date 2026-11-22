# Card streams

A board on another device (an iPhone) shows this Mac's simulator and browser cards as live
video and drives them. They are the same cards the agents drive: input goes through the same
calls as the Mac board's own.

The app serves them on its loopback (`StreamServer`, in `Sources/AgentBoard/Streams`), one TCP
connection per card. A remote board reaches it through a channel's `tcp:<port>` (see
[hosts.md](hosts.md), "The channel"); nothing listens beyond `127.0.0.1`.

## Finding it

The port and token are only ever handed out over the core's own protocol, never written to disk:

1. Once its server listens, the Mac app tells its core `servesStreams {port, token}`
   (`BoardRequest`), again on every reconnection. The core keeps them in memory while that board
   stays connected.
2. A remote board, connected to the core through a `core` channel, asks
   `streamTicket {card}`. The core answers that board alone with `streamTicket {card, port,
   token}` (`BoardEvent`); `port` and `token` are null while no board serves streams.
3. The remote board opens a second channel carrying `tcp:<port>` and says the hello below.

Only boards reach the core: a remote one through a channel its host trusted (hosts.md, "Board
identity"). An untrusted board gets `pending <n>` and no channel, so it can't ask. The token is
32 random bytes, new each launch.

## Protocol

1. **Hello.** The client's first bytes are one JSON line ending in `\n` (at most 4096 bytes):
   `{"token":"<token>","card":"<card uuid>"}`. A wrong token, an unknown card, or anything else
   closes the connection; nothing after the hello is read until it is accepted.
2. **Server → client.** Messages, each a 4-byte big-endian length then the payload. The
   payload's first byte is its type:
   - `H` (0x48): a JSON header, `{"kind","width","height","units"}`. `kind` is `h264` or
     `jpeg`; `width`×`height` is the space input is in, in `units` (`points` for iOS and
     browsers, `pixels` for Android). Sent first, and again when it changes. The video's own
     size comes from its SPS (H.264) or the image (JPEG) and may differ: scale.
   - `V` (0x56): one H.264 access unit, Annex B (start codes). The first one a connection gets
     is a keyframe with SPS and PPS in front, and every keyframe carries them (Android's come
     as their own unit just before, as scrcpy sends them). Display each as soon as it's
     decoded: there is no reordering and no timing to follow.
   - `J` (0x4a): one JPEG frame (browsers).

   A client that falls behind (about 1 MiB waiting unsent) loses frames rather than lag: JPEG
   frames until it catches up; H.264 units until the next keyframe once caught up, which the
   server asks the source for at once (and again if one comes while still behind).
3. **Client → server.** Messages framed the same way (4-byte length), each a JSON input event
   in the header's units:
   - `{"type":"touch","phase":"down"|"move"|"up","x","y"}`
   - `{"type":"scroll","x","y","dx","dy"}`: `dx`, `dy` are how far the content moves (a finger
     dragging up gives a negative `dy`).
   - `{"type":"key","usage":<HID usage>,"down":bool,"characters"?}` for simulators;
     `{"type":"key","key":"Enter"}` (a Playwright key name, or a simulator key name for
     `simulator_press`) for a press.
   - `{"type":"text","text"}`
   - `{"type":"button","name":"home"|"lock"|...}`, simulators only.
   Unknown events are ignored. Messages over 16 MiB close the connection.

Closing the connection stops the card's encoding once nobody else watches it. If a card's
sidecar (simulator-host, the browser sidecar) restarts, its streams resume by themselves once the
card's screen or page is back: the client gets a fresh `H`, then a keyframe.

## Where frames come from

- **Android**: scrcpy's H.264, passed through as it comes off adb. A new watcher gets a reset,
  which makes scrcpy send its configuration and a keyframe. The video keeps running while the
  Mac board hides the card if a stream watches it.
- **iOS Simulator**: `simulator-host` encodes the screen's IOSurface with VideoToolbox (real
  time, no frame reordering, low-latency rate control, a keyframe at least every 4 s) on every
  frame the simulator draws, while `stream {card, on}` is on, and sends each unit to the app as
  a `video` event over its stdout. A still screen sends nothing; a new watcher forces a keyframe.
  The encoder session is made off the main queue as soon as the card's screen is up and kept
  while the card is open: making one takes 2–3 s, which a first viewer would otherwise wait.
  Warm, the first keyframe comes about 0.2 s after a viewer joins, later frames 3 ms after the
  screen draws them (320×240 test frames, load average ~170). A live iPhone 17 simulator gave
  63 fps while a finger dragged, the first frame 118 ms after the finger went down; its first
  picture took 14 s after the hello, at load average 549 (provisional: retake at low load).
- **Browsers**: Playwright's `page.screencast` (WebKit), JPEG at quality 70, at the viewport's
  size. Through the real sidecar and the loopback server (desktop card, page animating every
  frame): 19.4 fps; a click sent on the stream shows 32–126 ms later (median 79). Killed, the
  sidecar is back streaming in 12 s. Load average 84–136: provisional.

## Recovery

- A rotation (a new screen size) gets a new encoder session made off the main queue; until it is
  ready no frames go out and clients keep the last picture. The screen and input never wait.
- A watched browser card whose page fails (the sidecar stopped, the page crashed) reopens by
  itself every 2 s while someone watches, whether or not a board shows the card; once open, its
  stream starts over with a fresh `H`.
- A watched iOS card is streamed again once a restarted `simulator-host` shows its screen.

## Testing

`StreamTests` covers framing, the token, input, a slow client, the iOS restart and an H.264
round trip through the real encoder. Two live tests run only when asked, through
`scripts/test-safe --filter`:

- `AGENTBOARD_PLAYWRIGHT_MODULES=<a node_modules with this build's Playwright>` and
  `PLAYWRIGHT_BROWSERS_PATH=<its WebKit cache>`: a real browser card through the real sidecar
  (reused, so the isolated home downloads nothing), with fps, click-to-frame latency, and a
  killed sidecar that must come back.
- `AGENTBOARD_SIMULATOR_HOST=<.build/…/debug/simulator-host>`: a device made for the test,
  booted headless, streamed, then shut down and deleted.

Both print `stream-live …` lines with the load average they ran under.
