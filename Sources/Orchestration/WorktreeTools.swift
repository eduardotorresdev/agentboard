import Connections
import Foundation

/// The worktree tools, listed by the core and run by a board, which keeps the sidebar's titles
/// (see `Orchestrator.relay`).
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
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        await store.relay(name, arguments: arguments, caller: caller)
    }
}
