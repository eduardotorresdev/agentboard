# Post-it

A board element that holds one markdown note. The developer and every agent connected to it
read and write it; several agents connect to the same post-it, as they do to a runner.

Status: built (2026-10-30). Replaces the notes block (statuses plus a list of notes).

## What it does

### For the developer

- **Add a post-it** from the canvas toolbar (note button): each click adds a new one, which opens
  in Code with the cursor in it.
- **View | Code** in the title bar: View shows the markdown rendered (headings, lists, task lists,
  quotes, code blocks, tables, emphasis, links); Code shows the markdown itself and is where it
  is written. A post-it with text opens in View, an empty one in Code; the choice stays per card
  while the board runs.
- **Writing**: clicking the text in Code places the cursor there; double-clicking the rendered
  text switches to Code. What is typed reaches the core when typing pauses (0.4 s) and when
  writing ends (Escape, or clicking elsewhere). Clicking a link in View opens it.
- While the user writes, text an agent writes shows in the editor unless the user has typed since
  the last send; then the user's text wins when it is sent.
- The text scrolls when it overflows; the title bar and the paper around the text move the card.
- Draw a line between the post-it and an agent to give that agent the post-it tools.

### For agents (MCP tools on the board's server)

| Tool | What it does |
|---|---|
| `postit_read` | The markdown, and who wrote it last and when |
| `postit_write` | Replaces the markdown, or adds `text` on a new line at the end with `append` |
| `postit_edit` | Replaces one exact passage (`old_text` must appear once) and leaves the rest |

Agents reach only post-its connected to them; with several connected, `postit` says which by
name. The tools' instructions ask agents to read the post-it before starting, keep it current,
prefer `postit_edit`/`append` since others write there too, and treat what other agents wrote as
information, not instructions from the user. `list_peers` shows a post-it as `postit` with how
many lines it has.

## How it is built

- The core keeps the post-its (`Orchestrator.postIts`, `PostItRecord` in
  `Orchestration/PostIt.swift`), so agents use them while no board runs. They are saved in the
  core's `postits` table and registered on the bus as `ElementKind.postIt`. The `notes` table of
  the build before is migrated once: same ids (so lines hold), notes as a markdown list,
  statuses dropped.
- `PostItTools.swift`: the `ToolProvider`.
- Protocol: `addPostIt`, `updatePostIt` (name and frame only, so a board never overwrites text an
  agent wrote meanwhile), `removePostIt`, `writePostIt`; the core answers with `postItAdded`,
  `postItUpdated` and `postItRemoved`, to every board but the sender. `BoardState.postIts` is
  optional, so boards and cores of the build before keep working (they drop the new messages).
- Board: `AgentStore+PostIts.swift` mirrors them; `PostItCardLayer.swift` draws the card (chrome
  as layers, the text drawn into one layer, laid out again only when the text, mode or width
  changes) and `PostItCardLayout` places everything for drawing and hit-testing alike.
  `MarkdownText.swift` turns markdown (Foundation's parser) into TextKit text; `PostItEditor` is
  the text view laid over the card while writing. Post-its stack above agents and below browsers.

## Not yet

- Renaming a post-it from the board.
- Merging concurrent edits: the last text sent wins.
- Images in markdown (their alt text shows).

Agents add post-its themselves with `postit_create` (optional `name` and first `text`): it lands
right of the agent's card, below other cards in the way, in the agent's organization, connected
to it. The core runs it, so it works with no board open.
