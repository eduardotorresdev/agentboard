import Connections
import Foundation

/// The worktree and host tools, listed by the core and run by a board, which keeps the sidebar's
/// titles, the projects and the account's hosts (see `Orchestrator.relay`).
@MainActor
final class WorktreeTools: ToolProvider {
    private unowned let store: Orchestrator

    init(store: Orchestrator) {
        self.store = store
    }

    func tools(for caller: UUID) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "worktree_set_title",
                description: """
                    Titles the worktree your card is in, as the user's sidebar shows it: what the work here is \
                    about, in a few words (e.g. "Board input with mentions"). Set it once you know, and again \
                    when the work changes course. A title the user wrote stays; the result says so. Needs the board open.
                    """,
                inputSchema: ["type": "object", "properties": [
                    "title": ["type": "string", "description": "A few words, at most 60 characters."],
                ] as [String: Any], "required": ["title"]]),
            ToolDefinition(
                name: "host_list",
                description: """
                    Lists the hosts worktrees can live on: this Mac and the machines signed in to the user's \
                    account, each with its id and whether it is online, and which one you run on; a host the \
                    board is connected to also shows its overall CPU use, memory and disk. Says so when \
                    the user isn't signed in (then there is only this Mac). Needs the board open.
                    """),
            ToolDefinition(
                name: "worktree_create",
                description: """
                    Adds a worktree to a project in the user's sidebar, on a branch: the existing branch with \
                    that name (local, or origin's), else a new one. Use it to start separate work without \
                    touching your own checkout; agents are added to it by the user. On another host the project \
                    is cloned there from its `origin` on first use, so it needs an `origin` the host can read \
                    and the branch's starting point pushed. Needs the board open.
                    """,
                inputSchema: ["type": "object", "properties": [
                    "branch": ["type": "string", "description": "Branch to check out, created when it doesn't exist."],
                    "project": ["type": "string", "description": "Project name or folder, as project_list shows it. Yours when left out."],
                    "host": ["type": "string", "description": "Host name or id, as host_list shows it. The host you run on when left out."],
                ] as [String: Any], "required": ["branch"]]),
            ToolDefinition(
                name: "worktree_remove",
                description: """
                    Removes a worktree of a project in the user's sidebar: its folder goes, its branch stays. \
                    Never the one your card is in, nor a project's main checkout. One with uncommitted changes \
                    or unpushed commits is kept unless `force`; the result says what would be lost. Needs the board open.
                    """,
                inputSchema: ["type": "object", "properties": [
                    "path": ["type": "string", "description": "The worktree's folder, as project_list shows it."],
                    "force": ["type": "boolean", "description": "Remove it even with uncommitted changes or unpushed commits, which are lost."],
                ] as [String: Any], "required": ["path"]]),
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        await store.relay(name, arguments: arguments, caller: caller)
    }
}
