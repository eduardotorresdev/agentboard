# Card streams

A board on another device (an iPhone) shows this Mac's simulator and browser cards as live
video and drives them. They are the same cards the agents drive: input goes through the same
calls as the Mac board's own.

The app serves them on its loopback (`StreamServer`, in `Sources/AgentBoard/Streams`), one TCP
connection per card. A remote board reaches it through a channel's `tcp:<port>` (see
[hosts.md](hosts.md), "The channel"); nothing listens beyond `127.0.0.1`.

## Finding it

`streams.json` in the data folder, mode 0600, rewritten at every launch:

```json
{"port": 52731, "token": "<base64 of 32 random bytes>"}
```

The token is new each launch and is meant to reach the phone only through the sealed channel.

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
   - `J` (0x4a): one JPEG frame (browsers). Once about 1 MiB waits unsent, new JPEG frames are
     dropped, so a slow client sees fewer frames rather than falling behind.
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

Closing the connection stops the card's encoding once nobody else watches it.

## Where frames come from

- **Android**: scrcpy's H.264, passed through as it comes off adb. A new watcher gets a reset,
  which makes scrcpy send its configuration and a keyframe. The video keeps running while the
  Mac board hides the card if a stream watches it.
- **iOS Simulator**: `simulator-host` encodes the screen's IOSurface with VideoToolbox (real
  time, no frame reordering, low-latency rate control, a keyframe at least every 4 s) on every
  frame the simulator draws, while `stream {card, on}` is on, and sends each unit to the app as
  a `video` event over its stdout. A still screen sends nothing; a new watcher forces a keyframe.
- **Browsers**: Playwright's `page.screencast` (WebKit), JPEG at quality 70, at the viewport's
  size. Measured on an M-series Mac with a page animating every frame, 390×844: about 19 fps,
  11 KB a frame, frames delivered within ~10 ms of capture; a click shows in the next frame
  23–86 ms later.
