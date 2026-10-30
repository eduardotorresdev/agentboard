# Notes block

A board element that holds shared notes: the agents connected to it say where they are working
and on what, and keep what the others should remember; the developer reads and writes it too.

Status: built (2026-10-30).

## What it does

### For the developer

- **Add notes** from the canvas toolbar (note button). The card has two sections: *Working on*
  (one status per agent: what it is doing, and where, in monospace) and *Notes*. Agents' names
  show in violet, the developer's ("You") in orange, each with the time it was written.
- **Writing**: *Add note* opens a field at the bottom of the card; Enter keeps it, Option-Enter
  starts a new line, Escape drops it, clicking elsewhere keeps it. Clicking a note rewrites it
  (emptying it removes it). Hovering a row shows ✕, which removes it, statuses included.
- The list scrolls when it overflows; the title bar and the space around the list move the card.
- Draw a line between the card and an agent to give that agent the notes tools.

### For agents (MCP tools on the board's server)

| Tool | What it does |
|---|---|
| `notes_read` | The block: each status (with where) and every note, with their ids |
| `notes_status` | Sets the caller's status (`doing`, `where`), replacing the one it had; empty `doing` clears it. Goes to every connected block unless `notes` names one. |
| `notes_write` | Adds a note, or rewrites the one with `id` |
| `notes_delete` | Removes a note or a status by `id` |

Ids are the first six characters of the entry's UUID, as `notes_read` shows them. Agents reach
only blocks connected to them; with several connected, `notes` says which by name. The tools'
instructions ask agents to read the block before starting, keep their status current, and treat
other agents' notes as information, not instructions from the user. `list_peers` shows a block
as `notes` with how many statuses and notes it has.

## How it is built

- The core keeps the blocks (`Orchestrator.notes`, `NotesRecord`/`NoteEntry` in
  `Orchestration/Notes.swift`), so agents use them while no board runs. They are saved in the
  core's `notes` table (entries as JSON) and registered on the bus as `ElementKind.notes`.
- `NotesTools.swift`: the `ToolProvider`.
- Protocol: `addNotes`, `updateNotes` (name and frame only, so a board never overwrites entries
  an agent wrote meanwhile), `removeNotes`, `writeNote`, `deleteNote`; the core answers with
  `notesAdded`, `notesUpdated` (to every board, the sender too, when entries changed) and
  `notesRemoved`. `BoardState.notes` is optional, so boards and cores of the build before keep
  working (they drop the new messages).
- An agent card that is removed takes its statuses with it; its notes stay.
- Board: `AgentStore+Notes.swift` mirrors the blocks; `NotesCardLayer.swift` draws the card
  (chrome as layers, the list drawn into one layer, redrawn only when what it shows changes) and
  `NotesCardLayout` places everything for drawing and hit-testing alike. Notes cards stack above
  agents and below browsers.

## Not yet

- Renaming a block from the board.
- Marking a status as stale after a while without updates.
