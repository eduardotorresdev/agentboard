# Goal: develop AgentBoard while using it

**No development action on AgentBoard interrupts an agent running in it.**

The board is disposable: it can crash, be rebuilt or be replaced, and the agents don't notice.
The core (`AgentBoardCore`, see `docs/core.md`) is the only process that must stay up, and even
it can be replaced by a newer build without losing anything.

Starting point: the core spike (branch `spike/core-daemon`). Sessions already live in the core
and survive the board being killed or rebuilt. The tool server, message bus, connection graph
and database still live in the board.

## Acceptance scenarios

Each one becomes an automated test.

| # | Scenario | Expected |
|---|---|---|
| 1 | `./run --watch` rebuilds the board while an agent is mid-turn | The agent carries on unaware. Its screen comes back identical, no input or output byte is lost or repeated, and its MCP tools keep working. |
| 2 | The board is killed with `kill -9` | Same as 1. |
| 3 | No board runs for 10 minutes | Agents keep working: `send_message`, `runner_start` and `runner_logs` answer, and messages between connected agents are delivered. |
| 4 | A core from a newer build starts | It takes over the old core's agents without ending them. `./run --restart-core` no longer ends agents. |
| 5 | The core restarts while a board runs | The board reconnects on its own; no card shows as failed. |
| 6 | Board and core come from different builds | They work together, with the protocol compatible at least one version back. When they can't, the board says plainly what to do. |
| 7 | A stable instance and a development instance run side by side | The agent runs in the stable one and edits the code; the development build runs isolated through `AGENTBOARD_HOME`. Breaking the development build doesn't affect the stable one. |

**Targets:**

- Reattaching 20 sessions takes under 300 ms.
- Zero bytes lost or repeated across any of the scenarios.
- Edit, rebuild and see the new board in under 10 s.

## Gate

A chaos test, scripted, using `FakeAgent` and `ClaudeSim` from `Benchmarks/`:

- Starts the core with N fake agents producing output and calling tools.
- Kills and relaunches the board and the core in a loop, at random moments.
- At the end, compares a checksum of every mirrored screen with a reference terminal fed the
  same bytes directly.
- Checks that every tool call and every message got its answer.

The goal is met when this passes repeatedly.

## Phases, in order of value

1. **Tools, bus, graph and database in the core.** Closes scenario 3, today's real gap: with no
   board running, agents' tool calls fail.
2. **Automatic reconnection of the board.** Closes scenario 5. Also make snapshots safe when
   taken in the middle of an escape sequence (carry the parser's state).
3. **Replacing the core without ending agents.** The old core hands the PTYs' file descriptors
   (`SCM_RIGHTS`) and the terminals' state to the new one over the socket. Closes scenario 4.
4. **Stable and development instances side by side,** and protocol compatibility across
   versions. Closes scenarios 6 and 7.
5. **The chaos test** as the gate for the whole goal.

## Decision: a crashing core

A core that crashes (rather than being replaced) takes its PTYs with it, and the agents end.

**Chosen: accept that risk and keep the core small and stable.** Logic that changes often stays
out of it, so a crash is rare and a new build replaces it through the handoff in phase 3. A
per-session process that only holds the PTY (as `dtach` does) is the fallback, adopted only if
core crashes show up in practice: it costs a process per agent and more moving parts.

## Out of scope

- Remote use or several machines.
- In-process Swift hot reload (InjectionIII). It can come later, on top of this.

## Status

| # | Covered by |
|---|---|
| 1, 2 | `Chaos --app 4` (Benchmarks): the real app under `./run --watch`, rebuilt four times (the last edit to the core's sources), then `kill -9` and relaunched three times, while 8 agents stream and an agent calls its tools; the app's terminals and the core's byte-identical to a reference, every call answered, every message once, same pids. `Chaos`: boards killed and replaced at random while 20 agents stream. `theBoardCarriesOnWhenTheCoreIsReplaced` drives the app's own `AgentStore`. |
| 3 | `Chaos --no-board 10`: ten minutes without a board; `send_message` both ways, `runner_start`, `runner_logs`, every message delivered once. `toolsWorkWithNoBoard`, `theCoreBinaryServesToolsAlone`. |
| 4 | `aNewerCoreTakesOverWithoutEndingPrograms` (same pid, every byte once, no failed tool call during the switch, same screen on a board); `Chaos` replaces the core at random. `./run --restart-core` and every build hand over. |
| 5 | `linkReconnectsToTheNextCore`, `theBoardCarriesOnWhenTheCoreIsReplaced` (the card never leaves `running`). |
| 6 | `talksToTheBoardBefore`, `talksToTheCoreBefore`, `buildsTooFarApartDontTalk`, `linkReportsACoreOfAnotherBuild`. |
| 7 | `Chaos --side-by-side 4`: a stable build (a copy) with agents and its app, beside a dev instance under `./run --watch` that is rebuilt, has its core replaced, gets garbage and its core killed; the stable board keeps its connection and core, its terminals stay identical. `instancesRunSideBySide`. |

Targets, as measured by `Chaos` with 20 agents: reattaching 20 sessions takes 40–80 ms (median,
p95 under 140 ms); a core handoff takes 80–140 ms from launch to serving. With the real app
(`Chaos --app`), edit to the new board showing every card takes 3.3–6.4 s over 16 rebuilds,
and a board relaunched after `kill -9` shows every card 0.4–0.9 s after launch. The gate passed 20 runs in a row (seeds 31–50; one earlier failure,
EMSGSIZE while passing descriptors, is fixed).
