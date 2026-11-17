use serde_json::{json, Map, Value};

use connections::{Reply, ToolDefinition, ToolProvider, Uuid};

use crate::orchestrator::Turn;

/// The worktree and host tools, listed by the core and run by a board, which keeps the sidebar's
/// titles, the projects and the account's hosts (see `Turn::relay`).
pub(crate) struct WorktreeTools;

impl<'a> ToolProvider<Turn<'a>> for WorktreeTools {
    fn tools(&self, _turn: &mut Turn<'a>, _caller: Uuid) -> Vec<ToolDefinition> {
        vec![
            ToolDefinition::with_schema(
                "worktree_set_title",
                "Titles the worktree your card is in, as the user's sidebar shows it: what the work here is \
                 about, in a few words (e.g. \"Board input with mentions\"). Set it once you know, and again \
                 when the work changes course. A title the user wrote stays; the result says so. Needs the board open.",
                json!({"type": "object", "properties": {
                    "title": {"type": "string", "description": "A few words, at most 60 characters."},
                }, "required": ["title"]}),
            ),
            ToolDefinition::new(
                "host_list",
                "Lists the hosts worktrees can live on: this Mac and the machines signed in to the user's \
                 account, each with its id and whether it is online, and which one you run on; a host the \
                 board is connected to also shows its overall CPU use, memory and disk. Says so when \
                 the user isn't signed in (then there is only this Mac). Needs the board open.",
            ),
            ToolDefinition::with_schema(
                "worktree_create",
                "Adds a worktree to a project in the user's sidebar, on a branch: the existing branch with \
                 that name (local, or origin's), else a new one. Use it to start separate work without \
                 touching your own checkout; agents are added to it by the user. On another host the project \
                 is cloned there from its `origin` on first use, so it needs an `origin` the host can read \
                 and the branch's starting point pushed. Needs the board open.",
                json!({"type": "object", "properties": {
                    "branch": {"type": "string", "description": "Branch to check out, created when it doesn't exist."},
                    "project": {"type": "string", "description": "Project name or folder, as project_list shows it. Yours when left out."},
                    "host": {"type": "string", "description": "Host name or id, as host_list shows it. The host you run on when left out."},
                }, "required": ["branch"]}),
            ),
            ToolDefinition::with_schema(
                "worktree_remove",
                "Removes a worktree of a project in the user's sidebar: its folder goes, its branch stays. \
                 Never the one your card is in, nor a project's main checkout. One with uncommitted changes \
                 or unpushed commits is kept unless `force`; the result says what would be lost. Needs the board open.",
                json!({"type": "object", "properties": {
                    "path": {"type": "string", "description": "The worktree's folder, as project_list shows it."},
                    "force": {"type": "boolean", "description": "Remove it even with uncommitted changes or unpushed commits, which are lost."},
                }, "required": ["path"]}),
            ),
        ]
    }

    fn call(&mut self, turn: &mut Turn<'a>, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        turn.relay(name, arguments, caller, reply)
    }
}
