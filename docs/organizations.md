# Organizations

An organization is a separate set of projects whose agents sign in to Claude Code on their own.
They sit as round avatars at the right of the toolbar, next to Add Project and Refresh.

- **Switching:** click an avatar. The sidebar shows that organization's projects, and the canvas
  only its agents, runners, post-its and browsers. A folder can be a project in several organizations; nothing stops it.
- **Editing:** hold an avatar (or right-click it) to change its name, color, or image. An image
  is cropped square and copied into the organization's folder.
- **Adding:** the `+` avatar creates one and opens its editor.
- **Default:** every install has one ("Default", shown translated until renamed). It can't be
  removed, and it uses `~/.claude` as is. Projects and cards from before organizations are in it.

## Login

Each card stores the organization it was added in (`AgentRecord.organization`,
`PostItRecord.organization`, `BrowserRecord.organization`; missing means the default one). Runners an agent starts join the agent's organization. When the core launches an
agent of another organization, it sets `CLAUDE_CONFIG_DIR` to
`<data folder>/organizations/<id>/claude` (see `OrganizationHome`):

- Every entry of `~/.claude` except the login (`.credentials.json`, `.claude.json`) is a symlink
  to the original, so skills, commands, agents, settings and transcripts stay shared. Entries
  added to `~/.claude` later are linked at the next launch.
- On creation the folder inherits the user's login: `~/.claude.json`, `~/.claude/.credentials.json`
  when present, and the macOS keychain item (`Claude Code-credentials`, copied to the item Claude
  Code reads for that folder). If any of it fails, the organization is just signed out.
- `/login` in any of its agents' terminals signs that organization in, and only it.

Agents run with `--dangerously-skip-permissions`.
