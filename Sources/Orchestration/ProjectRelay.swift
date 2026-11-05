import Connections
import Foundation

/// The project tools, listed by the core and run by a board: projects live in the board's
/// sidebar (see `Orchestrator.relay`). With no board open, a call says so.
@MainActor
final class ProjectRelay: ToolProvider {
    private unowned let store: Orchestrator

    init(store: Orchestrator) {
        self.store = store
    }

    func tools(for caller: UUID) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "project_list",
                description: "Lists the projects in the user's sidebar for your organization: name, folder, and worktrees."),
            ToolDefinition(
                name: "project_create",
                description: """
                    Adds a project to the user's sidebar, in your organization. Give `clone` to clone a repository, \
                    or leave it out to start an empty one (git init on main with a first commit). A `path` that \
                    already holds a git repository is added as it is. Needs the board open.
                    """,
                inputSchema: ["type": "object", "properties": [
                    "name": ["type": "string", "description": "Folder name, created under the user's projects folder. Taken from `clone` when left out."],
                    "path": ["type": "string", "description": "Absolute folder instead of `name`."],
                    "clone": ["type": "string", "description": "Repository URL to clone."],
                ] as [String: Any], "required": [String]()]),
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        await store.relay(name, arguments: arguments, caller: caller)
    }
}
