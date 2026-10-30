# Core

A separate process, `AgentBoardCore`, that owns the cards' programs (agents and runners) and
their PTYs, the cards themselves, the lines between elements, and the agents' tools. The board
mirrors all of it. Programs keep running while the board is killed, crashes or is rebuilt, the
agents keep messaging each other and driving runners, and the next board picks everything up
with the screens as they were. This is what makes it possible to work on AgentBoard from inside
AgentBoard: `./run --watch` replaces the app and the agent editing it keeps running.

Status: in progress, see `GOAL.md`.

## Behavior

- **Launch**: the board connects to the core's socket and launches the core when nothing
  answers. The core runs in its own session (`setsid`), so it isn't hit by signals sent to the
  board or to the terminal that started it (Ctrl+C).
- **Board killed or rebuilt** (SIGTERM, crash): programs keep running. On the next launch every
  card the core still has attaches, shown or not, with its screen, scrollback, modes and status.
  Running runners come back running instead of "Click to start".
- **Board quit** (Cmd+Q): the board asks the core to end every program and exit, as quitting
  did before the core existed.
- **Core replaced** (`AgentBoardCore --take-over`, which `./run` uses): the new core takes every
  program over from the running one without ending it. The old core stops reading the PTYs,
  snapshots each terminal and passes the PTY masters, the input not yet written, its lock and
  both listening sockets (boards' and tools') to the new one, which carries on exactly where it
  left off; boards reconnect by themselves. Tool calls being answered finish first, and the
  ones that come meanwhile wait in the kernel: no agent sees a refused call.
- **Core gone while a board runs** (replaced, or crashed): the board reconnects on its own,
  queueing what the user changes meanwhile, and re-attaches every card. A card says it lost the
  core only if none answers for 10 seconds.
- **Card removed**: its program ends and the core forgets it. Sessions of cards that no longer
  exist (removed while the core ran alone) end when a board connects.
- **Idle**: a core with no board connected and nothing running exits after about a minute.
- **No board**: agents' tools keep answering. `send_message` and `list_peers`, every runner
  tool, and messages between connected agents work as with a board open. The browser tools say
  the board isn't open: the pages live in it.
- **Another build's core**: board and core speak the newest protocol version both know, and
  every build speaks the previous version too, so neighbouring builds work together. With no
  version in common, a board newer than the core replaces it (handing the programs over); an
  older board says the agents run on a newer build, to open that one.
- **No core** (the binary is missing, the socket can't be used, `AGENTBOARD_LOCAL=1`, or a
  bench build): the board runs a core inside its own process, on a socket of its own, and
  talks to it the same way. Programs then end with the board.
- **Agents' tools across relaunches**: the tool server takes the port it had before
  (`tools.port`) and derives each agent's token from a key on disk (`tools.key`), so an agent
  keeps the URL and token it was launched with.
- **Tools changed** (a new build adds a tool, or changes one's description or arguments):
  agents running pick them up without restarting. Each agent keeps an event stream open (MCP's
  GET), handed over with the rest; the new core tells every stream the tools changed
  (`notifications/tools/list_changed`) and the agent lists them again. A changed tool's code
  runs from its next call either way.

## Developing

- `./install` builds a release and installs it as `/Applications/AgentBoard.app` (or
  `INSTALL_DIR`), on the main data folder. Run again, it updates the installed app in place:
  the new core takes the agents over and the app relaunches onto them, so an agent working in
  the installed app can run it to update the app it runs in. The settings of the builds before
  (project folder, open worktree) carry over at the first install.
- `./run` builds of the checkout use a data folder of their own (`AgentBoard Dev`; its window's
  toolbar is violet), so trying a change never touches the installed app's agents. Programs the core
  starts get no `AGENTBOARD_*` settings: a `./run` in one of them never reaches its core.

- `./run --watch` builds on every change and only then swaps the app (a failed build leaves
  the running one up); the new board reopens the worktree that was open. When the core's own sources change
  (`AgentBoardCore`, `AgentRuntime`, `TerminalCore`, `Orchestration`, `Connections`) also
  replaces the core with the new build's, which takes the programs over. `./run --restart-core`
  does that once. `./run --kill-core` stops this data folder's core instead (the one listening
  on its socket, `AgentBoardCore --socket-path`), ending its programs: for a core too old to
  hand over.
- `AGENTBOARD_HOME=<folder>` gives an instance its own data folder: database, core, socket, log
  and tool key. A build under test then runs beside the main one without touching its agents.
- The core logs to `core.log` in the data folder: boards connecting and leaving, handoffs.
  `AGENTBOARD_CORE_VERBOSE=1` logs each session a board attaches to as well.
- For tests, the app takes `AGENTBOARD_BACKGROUND=1` (stays behind other windows) and
  `AGENTBOARD_SCREENS=<path>` (on SIGUSR1, writes every card's terminal there).

## How it is built

- `AgentBoardCore/main.swift`: takes a lock (`core.sock.lock`, one core per socket), listens and
  serves until told to exit, on the main run loop.
- `Orchestration/Orchestrator.swift`: the core's service. Owns the cards and lines (the
  `agents` and `connections` tables; the board keeps the rest of the file), the message bus,
  the tool server and its tools (`RunnerTools`, `MessagingTools`, `BrowserRelay`), launching
  agents and runners, and measuring runners. Boards get its state with their welcome, then every
  change (`BoardEvent`), and send theirs (`BoardRequest`, in `BoardProtocol.swift`). Browser
  tool calls go to a connected board, which runs them (`BrowserTools`).
- `Orchestration/InProcessCore.swift`: the same server and service inside the board, when no
  real core can run.
- `AgentRuntime/CoreServer.swift`: the sessions (each a local `AgentSession`) and the boards
  mirroring each one; frames for the service go to it in order with the sessions' requests. Output is fanned out from the session's queue while its terminal is
  locked, and an attach takes the snapshot and subscribes in that same step, so a mirror never
  misses or repeats a chunk.
- `AgentRuntime/CoreClient.swift`: the board's connection; launches the core, routes output,
  snapshots and status to the sessions that mirror them.
- `AgentRuntime/AgentSession.swift`: after `host(on:id:)` a session mirrors the core's instead of
  owning a PTY. Its terminal parses the same bytes, so drawing, input encoding, `runner_logs` and
  message delivery work as before. Replies to the program's queries come from the core's
  terminal; the mirror's are dropped. Text the board writes into a terminal (the runner restart
  marker) goes through the core (`annotate`) so every mirror shows it.
- `AgentRuntime/CoreProtocol.swift`, `CoreSocket.swift`: length-prefixed frames over a Unix
  socket (user-only permissions): JSON requests and events, raw output and input, snapshots,
  and the service's own frames. `CoreProtocol.version` and `oldest`: a change only adds
  (optional fields, messages an older peer drops) so the build before keeps working.
- `AgentRuntime/CoreHandoff.swift`: one core handing everything to the next, over the socket
  with `SCM_RIGHTS`; `CoreServer.handOff` and `adopt` on either side, `CoreService` hooks for
  the service's part (the tool server's socket and idle connections, when runners started).
  An adopted program isn't the new core's child, so its exit is noticed with kqueue and its
  status is lost.
- `Connections/ToolServer.swift`: HTTP on BSD sockets, so its listening socket, idle
  keep-alive connections and event streams can be handed over (`drain`, `release`,
  `start(inheriting:)`). Streams get a comment every 25 s, or clients time them out.
- `TerminalCore/Snapshot.swift`: a terminal's whole state as bytes and back (screens,
  scrollback, cursor, pen, scroll region, tab stops, charsets, saved cursors, modes, clusters).
- `AgentRuntime/DataFolder.swift`: the data folder and `AGENTBOARD_HOME`.

## Verified

- `swift test`: the takeover keeps the programs, every byte of their output once, the tool
  calls made throughout, and a board's screen (`aNewerCoreTakesOverWithoutEndingPrograms`);
  builds one version apart talk, builds further apart are told apart (`CoreTests`,
  `linkReportsACoreOfAnotherBuild`); two data folders side by side (`instancesRunSideBySide`).
- `Benchmarks`: `swift run Chaos` is the gate. Twenty Claude Code-like agents (FakeAgent) run
  on the real core while boards are killed and replaced and the core is replaced at random
  moments, and an agent keeps calling tools and typing into a program. Afterwards the core's
  and the board's terminals must equal, byte for byte, a reference terminal fed the agents' own
  copy of their output; every message must have arrived once and every call been answered.
  `swift run Chaos --no-board 10` runs ten minutes with no board: agents message each other,
  start a runner and read its logs.
- `swift run Chaos --app 4` does it with the real app: eight agents run while `./run --watch`
  rebuilds the board four times (the last edit is to the core's sources, so the core is
  replaced too), then the app is killed with `kill -9` and launched again three times. The
  app's own terminals (its SIGUSR1 dump) and the core's must equal the reference. It times
  edit to new board showing every card: 3–6 s.
- `swift run Chaos --mcp-live <folder Claude Code trusts>` with the real Claude Code: the
  agent opens its stream, the core is replaced, and the agent must list the tools again from
  the new core. Nothing is typed into it.
- `swift run Chaos --latency 500` times a keystroke's echo with the PTY in the board and on
  the core: the core adds about 0.15 ms at the median and under 1 ms at p95.
- `swift run Chaos --side-by-side 4` runs a stable build (a copy of this one) with agents on
  its data folder while a dev instance under `./run --watch` is rebuilt, has its core
  replaced, gets garbage on its socket and its core killed with `kill -9`. The stable board
  must keep its connection and its core throughout, and its terminals must equal the reference.

## Not yet

- The core crashing (or `kill -9` of it) ends every program: the PTYs close with it. Accepted,
  so the core stays small.
- A tool call still unanswered 5 seconds into a core replacement (a slow browser action) is
  cut off: the agent sees it fail and can call again.
- Two boards on one core (two instances on one data folder) both mirror and type into the same
  programs; nothing coordinates their sizes.
