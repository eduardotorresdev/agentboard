import Connections
import Foundation

/// `element_remove`, `element_connect` and `element_disconnect`: an agent tidies its board,
/// including what it didn't put there. Every
/// removal an agent asks for, here or through the older single-element tools, goes through
/// `Orchestrator.removeElements`, which decides whether the user confirms it first.
@MainActor
final class RemovalTools: ToolProvider {
    private unowned let store: Orchestrator

    init(store: Orchestrator) {
        self.store = store
    }

    func instructions(for caller: UUID) -> String? {
        """
        element_remove takes elements off your board, connected to you or not: agents, runners, post-its, images, videos, \
        browsers, simulators, file trees. One element you made yourself goes at once. Several in one call, or anything \
        you didn't make (list_peers says who made each), waits for the user to allow it in the board; when they refuse, \
        or the board is closed, nothing is removed. You can't remove your own card. element_connect draws a line between \
        two elements of your board, as the user would; element_disconnect removes lines and always waits for the user to allow it.
        """
    }

    func tools(for caller: UUID) -> [ToolDefinition] {
        [ToolDefinition(
            name: "element_remove",
            description: """
                Removes elements from your board, connected to you or not: an agent or runner is ended and its card removed, \
                a post-it, image or video goes with its content, a browser or simulator is closed. One element you made goes \
                at once; several, or any you didn't make, wait for the user to allow it in the board, and nothing is removed \
                when they refuse. Never your own card.
                """,
            inputSchema: ["type": "object", "properties": [
                "elements": ["type": "array", "items": ["type": "string"],
                             "description": "Each element's name or id, as list_peers shows it. Use the id when two share a name."],
            ] as [String: Any], "required": ["elements"]]),
         ToolDefinition(
            name: "element_connect",
            description: "Draws a line between two elements of your board, as the user would; neither needs to be you. Any two different elements that aren't connected yet can be.",
            inputSchema: ["type": "object", "properties": ["a": Self.end, "b": Self.end], "required": ["a", "b"]]),
         ToolDefinition(
            name: "element_disconnect",
            description: "Removes lines between elements of your board. Always waits for the user to allow it in the board; nothing changes when they refuse or the board is closed.",
            inputSchema: ["type": "object", "properties": [
                "connections": ["type": "array", "description": "The lines to remove, each by its two ends.", "items": [
                    "type": "object", "properties": ["a": Self.end, "b": Self.end], "required": ["a", "b"]] as [String: Any]] as [String: Any],
            ] as [String: Any], "required": ["connections"]])]
    }

    private static let end: [String: Any] = ["type": "string", "description": "An element's name or id, as list_peers shows it. Use the id when two share a name."]

    /// The element of the caller's board that `address` names, or why there isn't exactly one.
    private func find(_ address: Any?, for caller: UUID) -> Result<any BoardElement, DecisionDraft.Refused> {
        let onBoard = store.bus.elements(onBoardOf: caller)
        let address = (address as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let found = findElement(address, among: onBoard) else {
            return .failure(.init(reason: "Nothing named “\(address)” is on your board; list_peers shows what is."))
        }
        let twins = onBoard.filter { $0.name.caseInsensitiveCompare(found.name) == .orderedSame }
        if twins.count > 1, !address.contains(found.id.uuidString) {
            return .failure(.init(reason: "\(twins.count) elements are named “\(found.name)”; give the id of the one you mean."))
        }
        return .success(found)
    }

    /// The two ends `pair` names.
    private func ends(_ pair: [String: Any], for caller: UUID) -> Result<(any BoardElement, any BoardElement), DecisionDraft.Refused> {
        switch (find(pair["a"], for: caller), find(pair["b"], for: caller)) {
        case (.failure(let refusal), _), (_, .failure(let refusal)): .failure(refusal)
        case (.success(let a), .success(let b)): .success((a, b))
        }
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        switch name {
        case "element_connect":
            switch ends(arguments, for: caller) {
            case .failure(let refusal): return .error(refusal.reason)
            case .success(let (a, b)):
                guard a.id != b.id else { return .error("An element can't be connected to itself.") }
                guard store.bus.connect(a.id, b.id) != nil else { return .error("“\(a.name)” and “\(b.name)” are already connected.") }
                return .text("Connected “\(a.name)” and “\(b.name)”.")
            }
        case "element_disconnect":
            var lines: [Connection] = [], items: [[String: String]] = []
            for pair in arguments["connections"] as? [[String: Any]] ?? [] {
                switch ends(pair, for: caller) {
                case .failure(let refusal): return .error(refusal.reason + " Nothing changed.")
                case .success(let (a, b)):
                    guard let line = store.bus.graph.connection(between: a.id, b.id) else {
                        return .error("“\(a.name)” and “\(b.name)” aren't connected. Nothing changed.")
                    }
                    if !lines.contains(line) { lines.append(line); items.append(["kind": "connection", "name": "\(a.name) - \(b.name)"]) }
                }
            }
            guard !lines.isEmpty else { return .error("Give `connections`: the lines to remove, each by its two ends `a` and `b`.") }
            if let refused = await store.confirmRemoval(of: items, for: caller) { return refused }
            lines.forEach { store.bus.disconnect($0.id) }
            return .text("Removed \(lines.count == 1 ? "the line" : "\(lines.count) lines"): \(items.compactMap { $0["name"] }.joined(separator: ", ")).")
        default: break
        }
        let given = (arguments["elements"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !given.isEmpty else { return .error("Give `elements`: the names or ids to remove, as list_peers shows them.") }
        var ids: [UUID] = []
        for address in given {
            switch find(address, for: caller) {
            case .failure(let refusal): return .error(refusal.reason + " Nothing was removed.")
            case .success(let found): if !ids.contains(found.id) { ids.append(found.id) }
            }
        }
        return await store.removeElements(ids, for: caller)
    }
}

extension Orchestrator {
    /// Notes that `agent` put `element` on the board, which lets it remove it without asking.
    func made(_ element: UUID, by agent: UUID) {
        bus.makers[element] = agent
        // shortcut: entries of removed elements stay in the file (a few bytes each), prune them if it ever grows.
        try? JSONEncoder().encode(bus.makers).write(to: Self.makersFile(in: dataFolder), options: .atomic)
    }

    static func makersFile(in folder: URL) -> URL { folder.appendingPathComponent("makers.json") }

    /// Asks the user, in a board, to allow `caller` to remove `items` (each a `kind` and a `name`).
    /// Nil when they allow it; else the refusal to answer the agent with.
    func confirmRemoval(of items: [[String: String]], for caller: UUID) async -> ToolResult? {
        let answer = await relay("board_confirm_removal", arguments: ["asker": record(caller)?.name ?? "", "items": items], caller: caller)
        guard !answer.isError else { return .error("Nothing was removed. " + answer.text) }
        return answer.text == "allowed" ? nil : .error("The user refused. Nothing was removed.")
    }

    /// Removes `ids` for the agent `caller`. The one rule for every removal an agent asks for:
    /// exactly one element it made itself goes at once; more than one, or anything it didn't
    /// make, waits for the user's answer in a board. Refused, or no board open: nothing goes.
    /// Never the caller's own card.
    func removeElements(_ ids: [UUID], for caller: UUID) async -> ToolResult {
        guard !ids.contains(caller) else { return .error("You can't remove your own card. Nothing was removed.") }
        let targets = ids.compactMap { bus.element($0) }
        guard !targets.isEmpty else { return .error("That is no longer on the board.") }
        if targets.count > 1 || targets.contains(where: { bus.makers[$0.id] != caller }) {
            if let refused = await confirmRemoval(of: targets.map { ["kind": $0.kind.rawValue, "name": $0.name] }, for: caller) { return refused }
        }
        var removed: [String] = [], onBoards: [UUID] = []
        // Looked up again: the user may have removed some while the question was open.
        for target in targets where bus.element(target.id) != nil {
            let id = target.id
            removed.append("“\(target.name)” (\(target.kind.rawValue))")
            if record(id) != nil { remove(id) }
            else if postIt(id) != nil { removePostIt(id) }
            else if image(id) != nil { removeImage(id) }
            else if fileTree(id) != nil { removeFileTree(id) }
            else { onBoards.append(id) }
        }
        if !onBoards.isEmpty {
            let done = await relay("board_remove", arguments: ["ids": onBoards.map(\.uuidString)], caller: caller)
            guard !done.isError else { return .error(done.text) }
        }
        return .text(removed.isEmpty ? "Nothing was left to remove." : "Removed \(removed.joined(separator: ", ")).")
    }
}

extension ToolResult {
    /// Its text parts, joined.
    var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
}
