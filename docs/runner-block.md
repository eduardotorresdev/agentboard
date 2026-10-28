# Runner block

A board element that keeps a command running (a dev server, a watcher, a worker, a local
database) in a terminal card, shows what it serves and costs, and lets both the developer and
the agents connected to it manage its lifecycle.

Status: built (2026-10-28).

## What it does

### For the developer

- **Add a runner** from the canvas toolbar (▶ button). The dialog asks, in order: a name
  (optional, derived from the command), a script from the folder's `package.json` (a pop-up that
  shows five at a time and scrolls), the command (which the script fills in and stays editable),
  and the folder (the worktree's, unless changed; the folder panel opens on the worktree). Scripts
  run with the project's package manager, from the nearest lockfile up to the repository root.
- **The card** is a terminal: the developer reads the output and can type into it (Ctrl+C
  included). Under the title, a strip shows the command, one chip per listening port
  (`localhost:5173`, violet) plus the network address when the port is open to other devices
  (`192.168.1.4:5173`, orange), and CPU and memory on the right. A chip opens the address in
  the default browser.
- **Lifecycle**: stop/start and restart sit in the title bar next to close. Stop sends SIGTERM to
  the process group, then SIGKILL after 3 s. Close stops it and removes the card. A runner that
  exits on its own shows its exit code (orange when nonzero). After a relaunch, runners come back
  stopped ("Click to start"): restarting servers is the developer's call.

### For agents (MCP tools on the board's server)

| Tool | What it does |
|---|---|
| `runner_start` | Starts `command` as a new card next to the caller, connected to it. Waits (`wait`, `timeout`, 15 s) until it listens on a port or exits, then answers with state, URLs and first output. The name of a runner already connected restarts that one with the new command. |
| `runner_list` | Connected runners: command, folder, state, pid, uptime, URLs, CPU, memory, processes |
| `runner_logs` | Latest output (`lines`, `match`) |
| `runner_stop` | Stops it and what it started; the card stays |
| `runner_restart` | Stop if running, start again, optionally with a new `command` |
| `runner_input` | Types text (and Enter) into its terminal |
| `runner_close` | Stops and removes a runner the caller started; the developer's own runners can only be stopped |

Agents reach only runners connected to them, like browsers. The tools' instructions ask agents
to start long-running commands as runners rather than in their own shell.

## How it is built

- Runners are terminal cards in `AgentStore` (`AgentRecord.runner: RunnerSpec`): they share the
  PTY, terminal, renderer, focus, input and lines with agent cards. They register on the bus as
  `RunnerElement` (`ElementKind.runner`), not as message endpoints.
- `AgentStore+Runners.swift`: add/start/stop/restart, placement next to the calling agent, and
  sampling every 2 s while any runner runs (none otherwise).
- `ProcessInspector.swift`: descendants from one `sysctl(KERN_PROC_UID)`, CPU time and physical
  footprint from `proc_pid_rusage` (Mach ticks converted with the timebase), listening TCP ports
  from `proc_pidinfo`/`proc_pidfdinfo`, the LAN address from `getifaddrs`. No `ps`/`lsof`
  processes; a sample takes under 1 ms.
- `RunnerTools.swift`: the `ToolProvider`. `RunnerChrome.swift`: the strip and buttons.
  `RunnerDialog.swift`: the Add runner sheet.
- `AgentSession` gained `.stopped`, `processID`, `exitCode` and `terminate(grace:then:)`; ended,
  failed and stopped states always notify the board, even before it drew the last output.
- Persistence: `command`, `directory`, `owner` columns on `agents`.

## Not yet

- Opening a runner's address in a board browser card (today: the default browser).
- Attention: a runner that crashes could mark its card like an agent waiting for input.
- Auto-start per runner after relaunch, for runners the developer always wants up.
