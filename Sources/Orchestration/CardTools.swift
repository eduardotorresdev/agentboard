import AgentRuntime
import Connections
import Foundation

/// Cards the other tools don't add or close: an agent starts agents and plain terminals next
/// to it, and closes the agents, post-its and browsers connected to it.
@MainActor
final class CardTools: ToolProvider {
    private unowned let store: Orchestrator

    init(store: Orchestrator) {
        self.store = store
    }

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static func which(_ word: String) -> [String: Any] {
        ["type": "string", "description": "Which connected \(word), by name or id (as list_peers shows it). Needed only when several are connected."]
    }

    func tools(for caller: UUID) -> [ToolDefinition] {
        let agents = store.providers.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
        return [
            ToolDefinition(
                name: "agent_start",
                description: "Adds an agent card to the board next to you, in your worktree, connected to you, and starts it. Give `worktree` to start it in another worktree instead; it stays connected to you. Tell it what to do with send_message.",
                inputSchema: Self.schema([
                    "agent": ["type": "string", "enum": store.providers.map(\.id), "description": "Which agent to run: \(agents)."],
                    "name": ["type": "string", "description": "Card name, which is how you address it. Named after the agent when left out."],
                    "worktree": ["type": "string", "description": "Absolute path of another worktree of your organization's projects, on your host, as project_list shows it. Yours when left out. Needs the board open."],
                ], required: ["agent"])),
            ToolDefinition(
                name: "agent_close",
                description: "Ends an agent connected to you and removes its card from the board. Whatever it was doing stops; close only agents you no longer need.",
                inputSchema: Self.schema(["agent": Self.which("agent")])),
            ToolDefinition(
                name: "terminal_open",
                description: "Adds a plain terminal (the user's login shell, no command) as a runner card next to you, connected to you. Type into it with runner_input, read it with runner_logs, remove it with runner_close.",
                inputSchema: Self.schema(["name": ["type": "string", "description": "Card name. “terminal” when left out."]])),
            ToolDefinition(
                name: "postit_remove",
                description: "Takes a connected post-it off the board, with its text.",
                inputSchema: Self.schema(["postit": Self.which("post-it")])),
            ToolDefinition(
                name: "browser_close",
                description: "Closes a connected browser and removes its card from the board. Needs the board open.",
                inputSchema: Self.schema(["browser": Self.which("browser")])),
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        switch name {
        case "browser_close":
            return await store.relay(name, arguments: arguments, caller: caller)
        case "agent_start", "terminal_open":
            guard let me = store.record(caller), me.runner == nil else { return .error("Only agents on the board can add cards.") }
            let cardName: String?
            switch BoardName.argument(arguments["name"]) {
            case .success(let clean): cardName = clean
            case .failure(let error): return .error("\(error)")
            }
            if name == "terminal_open" {
                let record = store.addRunner(command: "", name: cardName, directory: nil, owner: caller, to: me.worktree,
                                             at: store.runnerOrigin(near: me))
                return .text("Opened terminal “\(record.name)”, connected to you.")
            }
            let wanted = (arguments["agent"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let provider = store.providers.first(where: { $0.id == wanted })
                    ?? store.providers.first(where: { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                return .error("No agent “\(wanted)”. Give `agent` one of: \(store.providers.map(\.id).joined(separator: ", ")).")
            }
            var worktree = me.worktree
            if let other = (arguments["worktree"] as? String)?.trimmingCharacters(in: .whitespaces), !other.isEmpty, other != worktree {
                // The board knows the projects: it says whether the path is one of their worktrees.
                let known = await store.relay("worktree_resolve", arguments: ["path": other], caller: caller)
                guard !known.isError else { return known }
                worktree = other
            }
            let record = store.addAgent(provider, name: cardName, owner: me, in: worktree)
            return .text("Started agent “\(record.name)”\(worktree == me.worktree ? "" : " in \(worktree)"), connected to you. Tell it what to do with send_message.")
        case "agent_close":
            return connected(.agent, "agent", arguments["agent"], to: caller) { element in
                let name = element.name
                store.remove(element.id)
                return "Ended \(name) and removed its card."
            }
        case "postit_remove":
            return connected(.postIt, "post-it", arguments["postit"], to: caller) { element in
                let name = element.name
                store.removePostIt(element.id)
                return "Removed “\(name)” from the board."
            }
        default:
            return .error("Unknown tool “\(name)”.")
        }
    }

    /// Runs `body` on the `kind` element connected to `caller` that `address` names, or the only one.
    private func connected(_ kind: ElementKind, _ word: String, _ address: Any?, to caller: UUID,
                           _ body: (any BoardElement) -> String) -> ToolResult {
        let found = store.bus.peers(of: caller, kind: kind)
        let names = found.map(\.name).joined(separator: ", ")
        guard !found.isEmpty else { return .error("No \(word) is connected to you.") }
        if let address = (address as? String)?.trimmingCharacters(in: .whitespaces), !address.isEmpty {
            guard let element = findElement(address, among: found) else {
                return .error("No \(word) named “\(address)” is connected to you. Connected: \(names).")
            }
            return .text(body(element))
        }
        guard found.count == 1, let only = found.first else { return .error("Several are connected; say which: \(names).") }
        return .text(body(only))
    }
}

extension Orchestrator {
    /// Adds an agent card in `owner`'s organization, connected to it, and starts it: next to it in
    /// its worktree, or to the right of what `worktree`'s canvas holds.
    func addAgent(_ provider: any AgentProvider, name: String?, owner: AgentRecord, in worktree: String? = nil) -> AgentRecord {
        let size = CGSize(width: 640, height: 420)
        let base = name?.isEmpty == false ? name ?? provider.title : provider.title
        let worktree = worktree ?? owner.worktree
        let frames = layoutItems(in: worktree).map(\.frame)
        let origin = worktree == owner.worktree ? origin(near: owner, size: size)
            : CGPoint(x: frames.map(\.maxX).max().map { $0 + BoardLayout.columnGap } ?? 0, y: frames.map(\.minY).min() ?? 0)
        let record = AgentRecord(id: UUID(), worktree: worktree, providerID: provider.id,
                                 name: AgentRecord.uniqueName(base, among: cards(in: worktree)),
                                 frame: CGRect(origin: origin, size: size), organization: owner.organization)
        insert(record)
        bus.connect(owner.id, record.id)
        server.openSession(record.id, cols: Self.estimatedColumns(record.frame), rows: Self.estimatedRows(record.frame), for: nil)
        launch(record.id)
        return record
    }
}
