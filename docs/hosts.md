# Hosts

A host is a machine that runs agents. This Mac is always one (the local host); others are
machines signed in to the same account, Linux first. A worktree lives on one host, chosen when it
is created; its agents, runners and browsers run there, headless, and the Mac board mirrors them.

Status: in progress. The Mac keeps the Swift core (`docs/core.md`) until the Rust core passes the
same gate (`GOAL.md`); the Rust core ships on Linux first.

## Behavior

- **Account**: sign in with GitHub (device flow: a code shown here, confirmed on any device). The
  Mac app and every host sign in to the same account.
- **Hosts**: the app lists this Mac plus every host of the account, with whether each is online.
  A second computer signed in to the account sees the same hosts.
- **Setting a host up**: over SSH, `curl -fsSL <install url> | sh`, then `agentboard login`.
  `agentboard setup` installs what agents need (git, Node, Docker, Chromium for Playwright, the
  agent CLIs). The host then runs as a user service and shows up in the app.
- **Worktrees**: creating one asks for the host (this Mac by default). Agents can create one too
  (`worktree_create`, with `host`; `host_list` says which exist and are online).
- **Opening a remote worktree**: its cards are the host's. The host's stats (CPU, memory, disk)
  show above the agent usage stats.
- **Browsers** on a remote worktree are WebKit pages on this Mac, like any browser card, whose
  loopback is the host's: `localhost:5173` there opens as `http://<host name>.localhost:5173` and
  reaches the host's port 5173 (through an HTTP proxy in the app, `HostProxy`, one channel per
  connection). Clicking a runner's `localhost` link opens it in the system browser on a port of
  this Mac that leads to the host's.
- **Files, pictures, pull**: a file tree card lists and reads the host's files; pictures and
  videos added here are copied to the host and ones agents make there are fetched when their
  card shows (64 MiB at most each way); Pull in a worktree's menu runs `git pull --ff-only` on
  its host.
- **Skills, MCP servers and the GitHub login** (`Vault`, `HostSync`): kept in the account's
  vault (see "The vault") and applied by each host itself. What this Mac contributes, from its
  default agent home: `~/.claude/skills`, `commands`, `agents`, the `*.md` instruction files at
  its top and `plugins` (while under 32 MiB); the user-scope MCP servers of `~/.claude.json`
  with their keys (a global npm command goes as `npx -y <package>`, a uv tool as `uvx` held to
  the versions it has here through a small `sh` that finds the host's `synced-pins`, a Mac
  binary stays here); its git identity; and `gh`'s login when `gh` is signed in. Not kept:
  `settings.json` (its hooks run programs of this Mac), project-scoped MCP servers, the other
  agent programs' own settings (`~/.codex`, `~/.copilot`), transcripts, history. The Mac
  writes when what it has changed (it remembers, sealed in `vault.base` of its data folder,
  its own entries at the last write, and merges its changes since into what the server
  holds), then hands each host it reaches the key and runs `agentboard vault pull` there; the
  host's report becomes its row's note. The first time, one question for the account says
  what is kept and where it lands; after a yes ("Keep and Sync", or "Sync now" in the account
  menu) it runs by itself when a host first answers after launch. A host's row opens "MCP
  servers": what that host ends with and why, and its own commands, additions and omissions
  ("Per host"). Other computers' additions reach the hosts, not this Mac's home.
  What is large on a host's connection (a picture, a file over 256 KB) goes over a second
  connection, opened for it and closed when idle, so keys and screens never wait behind it;
  and a request to a host is waited for 30 seconds plus one per 50 KB it sends, then given up on.
- **Whose host it is**: the Mac keeps the identity key each host had when first seen (in its
  database) and holds every channel to that key. When the account server gives another key for
  a host, nothing connects to it: its row in the account menu and its cards say its identity
  changed, and "Trust new identity" there accepts the new key (for a host that was reinstalled),
  showing its fingerprint to compare with `agentboard status` on the host: the first 10 bytes of
  the SHA-256 of the key, in hex, in five groups of 4 (see "Board identity").
  "Forget this host" removes it from the account.
- **The account token** is in the macOS Keychain (a generic password named after the data
  folder, this device only) when the app is signed with an identity. Builds signed with none,
  which is what `./run` and `./install` make today, keep it in `account.token` of the data
  folder (readable by its owner only): to the Keychain each rebuild is another program, which
  could not read what the one before saved. `account.json` holds only who is signed in. It is read without
  ever asking: a token the Keychain won't give without a dialog (saved by another build) opens
  the sign-in dialog saying so, to sign in again.
  This Mac's own key (see "Board identity") is kept the same way, in its own Keychain item
  or in `board.key` of the data folder, and stays after signing out.
- **Path**: a host's row in the account menu and its stats' tooltip say whether it is reached
  directly or relayed; while relayed, the direct path is tried again every minute.

- **Sandbox**: on a host, each worktree's agents and runners run in a sandbox of their own
  (bubblewrap): the system is read-only, and they see neither the other worktrees under
  `~/agentboard` nor the host's own data (the account token, the tools key). Home and `/tmp` stay
  writable, and the network is shared. It keeps worktrees out of each other's way; it is not a
  wall against a program that means harm. The host's own program and service, the shell's start
  files, `~/.ssh` and git's settings are read-only inside, and its programs can't signal or
  read the core. What a board runs about a project there (git, reading files) runs in the same
  kind of sandbox, seeing that project's clone and worktrees only, and is looked up in the
  system's folders and the host's private toolchain, never in a folder a worktree can write.
  One way out remains: Docker (a container can mount anything; `AGENTBOARD_SANDBOX_DOCKER=0` in
  the service's environment takes it away from worktrees). Home is shared: what is synced to a
  host (MCP servers with their keys), the agents' logins and `~/.ssh` are readable by every
  agent on it. So that nothing inside can make them, the host creates, empty, `~/.gitconfig`,
  `~/.config/git`, `~/.config/autostart` and `~/.local/share/systemd` when it has none.
  `AGENTBOARD_SANDBOX=0` turns the sandbox off.
- **Signing agents in**: an agent CLI on a host signs in there, once, in its card's terminal;
  this Mac's agent logins are not copied.

## Verified

- `cargo test` in `core/`, on macOS and on Ubuntu 24.04: every crate, the terminal against 65
  cases of the Swift one byte for byte.
- `HostPilotTests` (`AGENTBOARD_PILOT=<account.json> scripts/test-safe --filter HostPilotTests`; plain
  `swift test` stops at the data folder's guard), against a real Ubuntu host through the
  deployed account server: programs and git on the host, its stats, a runner mirrored here, a
  second board seeing the same screen, a sandboxed runner in a git worktree. A key's echo takes
  8 ms at the median on the direct path over a LAN, 350 to 380 ms through the relay from Brazil.
- Not yet: the app's own screens against a real host (nobody has looked at them), and anything
  on macOS as a host.

## How it is built

```
Mac board ──wss──▶ account server (Cloudflare Worker) ◀──wss── agentboard (host)
   CoreClient        relays bytes, sealed end to end             └─ unix socket ─▶ core
```

- `core/`: the Rust workspace, mirroring the Swift modules it ports:
  - `crates/terminal` ← `Sources/TerminalCore` (parser, screen, scrollback, snapshot).
  - `crates/connections` ← `Sources/Connections` (graph, bus, tool catalog, MCP tool server).
  - `crates/runtime` ← `Sources/AgentRuntime` (protocol, frames, PTY, sessions, server).
  - `crates/orchestration` ← `Sources/Orchestration` (cards, tools, runners, attention).
  - `crates/agentboard`: the binary: `core` (the daemon), `login`, `setup`, `status`.
- `server/`: the account server, a Cloudflare Worker (D1 for accounts and hosts, a Durable Object
  per host for the relay).
- The Rust core is plain threads and channels, as the Swift one is queues: no async runtime.

### Wire compatibility

The Rust core speaks `CoreProtocol` (`Sources/AgentRuntime/CoreProtocol.swift`) and
`BoardProtocol` (`Sources/Orchestration/BoardProtocol.swift`) exactly, so the board's
`CoreClient` can't tell it from the Swift core. The JSON is what Swift's `JSONEncoder` and
synthesized `Codable` produce:

- An enum case is an object with one key, the case name, holding its labelled values:
  `{"hello":{"version":7,"oldest":2}}`. Unlabelled values are `_0`, `_1`:
  `{"removeCard":{"_0":"<uuid>"}}`. A case without values is `{"shutdown":{}}`.
- `UUID` is its uppercase string. `Data` is base64. `Date` is seconds since 2001-01-01 UTC, a
  number. An absent optional is a missing key (never `null`) on encode; accept both on decode.
- A dictionary keyed by `UUID` is an array alternating key and value: `[key, value, key, value]`.
  Keyed by `String`, an object.
- `CGRect` is `[[x, y], [width, height]]`, `CGPoint` and `CGSize` are `[a, b]`.
- A raw-value enum is its raw value. Unknown cases and unknown keys are dropped, not errors.
- Terminal snapshots are byte for byte `Terminal.snapshot()` (`TerminalCore/Snapshot.swift`).

Golden files generated from the Swift code (`core/fixtures/`, written by the Swift tests named
`*Fixtures`) pin this down: the Rust tests decode, re-encode and compare them.

### Account server

All JSON; `Authorization: Bearer <token>` except the two login calls.

| Call | Does |
|---|---|
| `POST /v1/login/device` | Starts GitHub's device flow. → `{device_code, user_code, verification_uri, interval, expires_in}` |
| `POST /v1/login/poll` `{device_code, host?}` | → `{status: "pending" \| "slow_down" \| "expired" \| "denied"}` or `{token, account}` |
| `GET /v1/account` | → `{id, login, name, avatar_url}` |
| `POST /v1/logout` | Forgets the token. |
| `POST /v1/logout/boards` | Forgets every board's token of the account, the caller's included; hosts stay. |
| `GET /v1/hosts` | → `[{id, name, platform, version, public_key, online, last_seen}]` |
| `PUT /v1/hosts/:id` `{name, platform, version, public_key}` | A host registers itself (`id`: a UUID it made up and keeps). |
| `DELETE /v1/hosts/:id` | Forgets a host. |
| `POST /v1/hosts/:id/ticket` | A pass for one direct connection (see "The direct path"). |
| `GET /v1/hosts/:id/listen` (WebSocket) | The host's standing line; while open the host is online. The server sends `{"connect":"<channel>"}` when a board wants in, and answers `ping` with `pong`. |
| `GET /v1/hosts/:id/accept/:channel` (WebSocket) | The host's end of one board's channel. |
| `GET /v1/hosts/:id/spare/:channel` (WebSocket) | The host's end of a channel no board asked for yet (`channel`: a UUID it makes up). The next board to `connect` is paired with it at once, with no notice on `listen`; the host keeps two open, each replaced after two minutes, and the server hands out none older than 100 seconds. |
| `GET /v1/hosts/:id/connect` (WebSocket) | A board's end; binary messages are piped to the host's `accept` and back, in order. Closes with 4404 when the host is offline, and when the other end closes. |

Tokens are 32 random bytes, stored hashed. A board's lasts 90 days or until `logout`; a host's until `logout` or until the host is forgotten. A host signs in saying
which host it is (`host`), and its session serves that host only: it registers it, listens and
accepts for it, and can do nothing else (403 `wrong_session`), so a token read on one host
reaches no other. Only a host's session speaks as the host: a board's can't register a key or
take a host's line. A host belongs to the
account that registered it; every call on it from another account is 404.

- It is deployed at `https://agentboard-account.agentboard-account-server.workers.dev`
  (`server/README.md` says how); `AGENTBOARD_SERVER` points a build elsewhere.
- Errors are `{"error": "<code>"}` with the status: 400 `invalid_*`, 401 `unauthorized`, 403
  `too_many_hosts`, 404 `not_found`, 429 `rate_limited`, 502 `github`.
- An account's `id` is GitHub's numeric id; `name` and `avatar_url` may be null. `last_seen` is
  Unix seconds, null until the host first listens. Host and channel ids come back lowercase:
  compare them as UUIDs.
- After `slow_down`, poll 5 seconds slower (the reply carries no new interval).
- A host says `alive` (text) on its `listen` socket every minute: one silent for 150 seconds
  reads offline even if its socket's close never arrived.
- Close codes: 4404 host offline or forgotten, 4408 the host didn't accept within 15 seconds,
  4409 a newer `listen` replaced this one, 4429 the host already has 64 channels, 1000 the other
  end closed.
- Limits: 60 login calls a minute per address, 50 hosts per account, 1 MiB buffered before the
  host accepts.

### The channel

A channel carries one byte stream, sealed so the server only relays. After the handshake below,
the board's sealed message after its proof (see "Board identity") says which, as text: `core` for the core's own frame stream
(`CoreProtocol`), or `tcp:<port>` for a connection to that port on the host's loopback (how a
browser on the board reaches what a runner serves on the host). The host connects accordingly and
bridges; anything else, or a port it can't connect to, closes the channel.

1. Board → host: its ephemeral X25519 public key (32 bytes).
2. Host → board, in one message of 96 bytes: its ephemeral X25519 public key (32), then an
   Ed25519 signature (64) of `agentboard channel v1 ‖ board key ‖ host key` made with the host's identity key, whose
   public half is the `public_key` the host registered (base64).
3. Both derive two keys with HKDF-SHA256 (input: the X25519 shared secret; salt: `board key ‖
   host key`; info: `agentboard channel v1`; 64 bytes: first half board→host, second half
   host→board).
4. Every later WebSocket message is a chunk of the stream (at most 64 KiB) sealed with
   ChaCha20-Poly1305: ciphertext then the 16-byte tag, no associated data. The nonce is the
   message's number in its direction, from 0, as 12 bytes little-endian.

### Board identity

The server decides who may ask for a channel; the host decides who gets one, by a key the host
itself trusts. A lying server, or a stolen token, gets "pending" at most.

- Each board (a Mac) makes an Ed25519 key on first sign-in and keeps it where it keeps its
  token. A key's fingerprint, for people to compare, is the first 10 bytes of the SHA-256 of
  its 32 raw bytes, lowercase hex in five groups of four (`4604 7895 a6f2 8626 01ab`); a
  host's identity key is shown the same way.
- **Proof.** After the handshake of "The channel", the board's first sealed message is its
  proof: `board identity key (32) ‖ signature (64) ‖ its name (UTF-8, at most 64 bytes, for
  display only)`, the signature over `agentboard board v1 ‖ board ephemeral key ‖ host
  ephemeral key ‖ host identity key`. On the direct path the ticket still comes first, then
  the proof. There is no channel without a proof: a host that gets anything else (a signature that
  doesn't hold, fewer than 96 bytes, a name over 64) closes with no verdict and records
  nothing.
- **Verdict.** The host's first sealed message back is text: `trusted`, or `pending <n>` (`n`:
  how many boards this host trusts) after which it closes. A board needn't wait for it: it says what the channel
  carries right after its proof, and a host that isn't going to trust it reads that and
  drops it.
- **The host's list** is `boards.json` in its data folder (hidden from every sandbox):
  `{"trusted":[{key,name,added}],"pending":[{key,name,first_seen,last_seen}],"first_use_until"?}`,
  keys base64, times Unix seconds. An unknown key with a valid proof becomes pending: 8 at
  most; a known one only has `last_seen` refreshed; a new one replaces the least recently
  seen when full, and at most one new key is recorded every 10 seconds (others are refused
  unrecorded: they get `pending <n>` like the rest). Nothing is logged per attempt. A waiting board tries again every 30 seconds;
  one silent for 5 minutes leaves the list. A sender that keeps its own keys fresh can still
  crowd a real board off the list: `agentboard trust <key>` (below) is the way round it.
- **The name is only what a computer calls itself.** Whoever sends a proof picks it: the host
  stores it without control characters, and every prompt and listing leads with the
  fingerprint, says where the one to compare it with is ("the same fingerprint shows in that
  computer's account menu"), and labels the name as the computer's own word. The signature
  doesn't cover the name and needn't: it arrives sealed under the keys the signature covers,
  and nothing is ever decided by it.
- **The first board.** `agentboard login` at a terminal, once signed in, waits (15 minutes at
  most) for the first board to appear as pending and asks: `<fingerprint> wants to use this host (it
  calls itself "<name>"). The same fingerprint shows in that computer's account menu. Trust
  it? [y/N]`, about each board that is pending, not only the first; after a no it keeps
  waiting for another. Ctrl+C or the 15 minutes leave the list as it is. Without a terminal it sets `first_use_until` 15 minutes
  ahead and says so: while the list is empty and that time hasn't passed, the first valid
  proof is trusted. Otherwise an empty list means every board is pending.
- **Later boards**: `agentboard boards` on the host lists trusted and pending boards with
  fingerprints; `agentboard trust <fingerprint>` and `agentboard untrust <fingerprint>` (a trusted board or a waiting one) act on
  the full key stored under that fingerprint (all five groups; never a prefix). Two stored
  keys with one fingerprint: refused, both listed, never one picked. `agentboard trust <key>`
  takes a whole public key (base64) too, pending or not (and `untrust <key>` a trusted one): a waiting board shows its key to copy,
  so pairing can't be blocked by anyone who isn't at the host's terminal (a sender of endless
  new keys can keep a real board off the pending list). Or from a
  trusted board, over a channel carrying `boards`: one JSON line each way per request —
  `{"list":{}}` → `{"trusted":[…],"pending":[…]}`; `{"trust":{"key":"<base64>"}}` (a key that
  is pending) and `{"forget":{"key":"<base64>"}}` (any key on the list, trusted or waiting, its own and the last one
  included) → `{"ok":true}` or `{"error":"…"}` (`not_pending`, `not_trusted`,
  `invalid_request`); the entries of `list` are the file's. A forgotten board's `boards`
  channel ends at its next request; its other channels already open last until they close.
  The host handles this itself: the core never
  learns who a board is. `agentboard logout` empties the list. Forgetting the last board leaves
  the list empty, with no new first-use window.

### The vault

What every host of an account should have — skills, commands, subagents and instructions
(`~/.claude`), the user's MCP servers, the GitHub login, the git identity — is kept once, in
the account, sealed so the server can't read it. A board (a Mac) writes it; every host, with
or without a screen, reads it and applies it to its home, once per version. It replaces
copying from a Mac to each host.

- **The key.** 32 random bytes, made by the first board that finds no vault. Boards keep it
  where they keep their token; a host keeps it in `vault.key` (0600) in its data folder, as base64 on one line.
  It only ever travels over a channel, between a host and a board that host trusts: kind
  `vault`, one JSON line each way — `{"get":{}}` → `{"key":"<base64>"}` or
  `{"error":"no_key"}`; `{"set":{"key":"…"}}` → `{"ok":true}`, or `{"error":"different_key"}`
  when the host holds another (nothing is replaced); anything else → `{"error":"invalid_request"}`.
  A board forgotten meanwhile has its channel closed at its next request. A new board gets
  the key from any host that trusts it. `agentboard logout` forgets `vault.key` and
  `vault.applied`, not what the vault wrote.
- **Sealing.** ChaCha20-Poly1305 under HKDF-SHA256(key, no salt, info `agentboard vault v1`, 32 bytes), no
  associated data; a sealed
  thing is `nonce (12 random bytes) ‖ ciphertext ‖ tag`. A chunk's id is the lowercase hex
  HMAC-SHA256 keyed with the vault key itself (not the derived one) over `agentboard vault blob v1` ‖ its plain bytes: the same bytes always have
  the same id, and the id says nothing without the key. `core/fixtures/vault.json` pins this
  down with fixed keys and nonces.
- **Small on the wire.** A chunk is compressed before it is sealed (sealed bytes can't be):
  what is sealed is one byte saying how — `0` as it is, `1` zlib (RFC 1950) — then the bytes;
  a writer keeps `0` when compressing doesn't make it smaller. The id is still of the plain
  bytes. The manifest is sealed the same way. Chunks travel many per request:
  `POST /v1/vault/chunks` with a body of `id (64 hex bytes) ‖ length (4 bytes, big-endian) ‖
  sealed bytes`, repeated, 8 MiB at most → `{}`; `POST /v1/vault/chunks/get` `{ids:[…]}` (200
  at most) → the same framing back, in the order asked (an id asked twice comes once),
  leaving out ids it lacks and stopping before 8 MiB (ask again for the rest). The id is the
  chunk's 64 lowercase hex characters as ASCII; the length is of the sealed bytes, each at most
  1,100,000 (413 `too_large`, as is a body over 8 MiB; a cut frame is 400 `invalid_chunks`, a bad
  id 400 `invalid_id`). One request's chunks are stored together or not at all, within the 512
  MiB; a host's session gets 403 `wrong_session` on the `POST /v1/vault/chunks`. A host opens a
  chunk to at most 1,000,000 bytes and a manifest to at most 16 MiB: anything that inflates
  further, or another first byte, doesn't open.
- **The manifest** (sealed JSON): `{"files":[{"path", "mode", "size", "chunks":[id…]}],
  "mcp":{name: entry}, "pins":{tool: text}, "github":{"user","token"}?, "git":{"name",
  "email"}?, "updated": <Unix seconds>, "by": "<board fingerprint>"}`. `path` is relative to
  home and under `.claude/`; `mode` is the permission bits as a number (0o644 is 420); a file
  is cut in chunks of at most 1,000,000 plain bytes, in order. A `pins` tool is a plain name
  (letters, digits, `.`, `_`, `-`, not starting with `.`); a host keeps each pin in
  `synced-pins/<tool>.txt` in its data folder and deletes the ones no longer sent.
- **Per host.** The manifest may carry `"hosts": {"<host id>": {"mcp": {name: entry},
  "without": [name…]}}`: servers only that host gets (or its own version of one of the
  account's, by the same name: a program that is another binary there), and account servers
  that host leaves out. A host applies the account's `mcp`, minus its `without`, then its own
  `mcp` over them. The report's `servers` is what it ended with. Host ids compare as UUIDs.
- **The server** (any session of the account reads; only a board's writes):

  | Call | Does |
  |---|---|
  | `GET /v1/vault` | → `{version, manifest}` (base64), or 404 `no_vault`. |
  | `PUT /v1/vault` `{version, manifest, chunks:[id…]}` | Replaces the manifest when `version` is the current one (0: none yet) → `{version}` (one more); else 409 `stale`. Chunks not in `chunks` (at most 20000 ids) are deleted. The manifest is at most 1,500,000 bytes (413 `too_large`). |
  | `POST /v1/vault/have` `{ids:[…]}` | → `{missing:[…]}`: which of up to 5000 ids the server lacks. |
  | `PUT /v1/vault/chunks/:id` (body: sealed bytes, at most 1,100,000; over: 413 `too_large`) | Stores one chunk (the same id again replaces it) → `{}`. |
  | `GET /v1/vault/chunks/:id` | → its bytes, or 404. |

  512 MiB of chunks per account at most (413 `vault_full`). An id is exactly 64 lowercase hex
  (else 400 `invalid_id`, `invalid_ids`, `invalid_chunks`). A host's session gets 403
  `wrong_session` on the two `PUT`s. Another account's chunk is 404.
- **A host applies it** with `agentboard vault pull` (run when the service starts, and by a
  board when it connects or has written a new version): nothing to do when the version is
  the one in `vault.applied` (it still reports `servers` and `lacking`, with `files` and
  `removed` 0); no vault on the account reports version 0. Otherwise it checks every path
  first (only under `~/.claude/`; never `..`, an absolute path, or a symbolic link on the way,
  `~/.claude` itself included: any of them and nothing is written), fetches the chunks of the
  files that differ from what is on disk (it keeps no cache), checks each chunk's id once
  opened, writes each file aside and renames it into place with its `mode`, removes the files
  a previous version put there and this one dropped, and the folders that leaves empty
  (`vault.files` lists them; the host's own files are never touched), merges the MCP servers
  into `mcpServers` of `~/.claude.json` (taking out the names `vault.mcp` recorded, putting
  this version's in; a vault server wins over a host's of the same name; every other key
  stays; made when absent, written aside, 0600; left alone if it is a link or not JSON),
  writes the pins, signs `gh` in with the token
  (`gh auth login --hostname github.com --with-token`, the token on stdin, then
  `gh auth setup-git`, when `gh` is on the PATH: `~/.local/bin` first, then the system's) and
  sets `user.name` and `user.email` in the global git config when they are unset. `files`
  counts the files written this time, `removed` the ones removed, `github` whether `gh` took
  the token. `agentboard vault status` says which version is applied and whether the key is
  here (never the key). `agentboard setup` installs `gh` (the `gh` apt package with root, else
  conda-forge's in the private toolchain). It prints one JSON line: `{"version", "files", "removed", "servers":[…],
  "lacking":[{"server","command"}], "github": true|false}` — `lacking`: servers whose program
  (a bare name, looked up on that PATH) isn't on the host. What it writes lands in the home every agent on that host shares.
- **More than one writer.** Several boards (and other kinds of them, later) write the same
  vault, so no write may undo another's. The server refuses a manifest whose `version` isn't
  the current one (409 `stale`) and one that names a chunk it doesn't hold (409
  `missing_chunks`, with `{"missing":[id…]}`; `stale` when both hold): replacing the manifest and deleting the chunks
  it no longer names is one transaction. A board never sends "what I have": it sends the
  server's current manifest with its own changes applied — it remembers the manifest it last
  wrote or merged (its base), and what differs between its base and its home is what it
  changes: an entry (a file, a server, a pin, a host's section, the GitHub login) it added or
  edited is set, one it removed is removed, and every other entry stays as the server has
  it, whoever wrote it. On `stale` or `missing_chunks` it reads again and repeats.
- **A board writes it** when what it would send changed: it asks `have`, uploads the missing
  chunks, puts the manifest, and tells its connected hosts to pull. Entries that only work on
  a Mac are rewritten or left out there, before sealing (see `HostSync`).

### The direct path

The relay runs where the account server's provider puts it, which can be a continent away from
both ends (it adds about 220 ms to every key from Brazil). So a board first tries the host
itself, and uses the relay only when it can't reach it:

- The host listens on a TCP port (47470, or any free one) and registers where
  (`addresses` in `PUT /v1/hosts/:id`: up to 8 `address:port`, its LAN and global addresses).
- The board asks `POST /v1/hosts/:id/ticket` → `{ticket}`: 32 random bytes (base64) the server
  also tells the host on its `listen` socket (`{"ticket":"…"}`) and keeps no copy of. The host
  takes each ticket once, within 30 seconds of hearing it. The server adds the address it
  sees the host come from, at the host's port, to `addresses`.
- The board connects to every address at once, 400 ms at most, and uses the first that answers.
  Over TCP each message of the channel is a 4-byte big-endian length, then the message. The
  handshake is the channel's; the board's first sealed message is then the ticket's 32 bytes,
  its second its proof (see "Board identity"), and once trusted its third says what the
  channel carries. A wrong, used or late ticket closes the
  connection, as does a handshake not finished within 5 seconds.
- 404 `offline` from `ticket`, no address answering, or the host refusing: the relay. A board
  that just failed to reach a host directly goes straight to the relay for the next 45 seconds.

The server decides who may ask (it authenticates the account) and the host who gets in (see
"Board identity"): a server that lies gets a waiting entry at most.

### Protocol additions for hosts (version 8)

- `CoreRequest.run(call, executable, arguments, directory, input)` → `CoreEvent.ran(call,
  status, output, error)`: runs a program on the host, feeding it `input`, and returns what it
  printed. A name without a slash is looked up in the system's folders and the host's toolchain; the program ends after 15 minutes. The board
  runs `git` through it, lists and reads files, and copies files to the host (`tar`), so
  worktrees, file trees, pictures and the user's skills work the same on any host.
- `CoreRequest.subscribeHost` → `CoreEvent.host(HostStats)` every 2 s: CPU, memory, disk, load.
