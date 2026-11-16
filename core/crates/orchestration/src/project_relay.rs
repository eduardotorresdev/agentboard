use serde_json::{json, Map, Value};

use connections::{Reply, ToolDefinition, ToolProvider, Uuid};

use crate::orchestrator::Turn;

/// The project tools, listed by the core and run by a board: projects live in the board's
/// sidebar (see `Turn::relay`). With no board open, a call says so.
pub(crate) struct ProjectRelay;

impl<'a> ToolProvider<Turn<'a>> for ProjectRelay {
    fn tools(&self, _turn: &mut Turn<'a>, _caller: Uuid) -> Vec<ToolDefinition> {
        vec![
            ToolDefinition::new("project_list", "Lists the projects in the user's sidebar for your organization: name, folder, and worktrees."),
            ToolDefinition::with_schema(
                "project_create",
                "Adds a project to the user's sidebar, in your organization. Give `clone` to clone a repository, \
                 or leave it out to start an empty one (git init on main with a first commit). A `path` that \
                 already holds a git repository is added as it is. Needs the board open.",
                json!({"type": "object", "properties": {
                    "name": {"type": "string", "description": "Folder name, created under the user's projects folder. Taken from `clone` when left out."},
                    "path": {"type": "string", "description": "Absolute folder instead of `name`."},
                    "clone": {"type": "string", "description": "Repository URL to clone."},
                }, "required": []}),
            ),
        ]
    }

    fn call(&mut self, turn: &mut Turn<'a>, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        turn.relay(name, arguments, caller, reply)
    }
}
