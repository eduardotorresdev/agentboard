import Connections
import Foundation

/// `element_layout`, `element_move` and the `group_` tools: an agent sees where everything on
/// its board sits and how big it is, moves and resizes it, and keeps images and videos in
/// organizational groups (see `ImageGroup`).
@MainActor
final class LayoutTools: ToolProvider {
    private unowned let store: Orchestrator

    init(store: Orchestrator) {
        self.store = store
    }

    func context(for caller: UUID, event: String) -> String? { nil }

    func instructions(for caller: UUID) -> String? {
        """
        element_layout lists every element of your board with its place and size (board points; x grows right, y grows \
        down) and the organizational groups. element_move moves an element, resizes it, or both. Groups keep images and \
        videos, nothing else, in one column (vertical) or one row (horizontal), snapped to the group's grid on a light \
        panel of a palette color: group_create makes one, group_edit changes its direction, color or members, \
        group_remove dissolves it and leaves its pictures in place. Moving or resizing a grouped picture moves or \
        resizes its whole group.
        """
    }

    private static let element: [String: Any] = ["type": "string", "description": "The element's name or id, as list_peers shows it. Use the id when two share a name."]
    private static let direction: [String: Any] = ["type": "string", "enum": ImageGroup.Direction.allCases.map(\.rawValue),
                                                   "description": "vertical: one column, every card the same width. horizontal: one row, every picture the same height."]
    private static let color: [String: Any] = ["type": "string", "enum": ImageGroup.colors, "description": "The light color of the group's panel."]
    private static let members: [String: Any] = ["type": "array", "items": ["type": "string"],
                                                 "description": "The images and videos, by name or id, in the order they are laid out."]
    private static let group: [String: Any] = ["type": "string", "description": "The group's name or id, as element_layout shows it."]

    func tools(for caller: UUID) -> [ToolDefinition] {
        [ToolDefinition(
            name: "element_layout",
            description: "Lists every element of your board with its top left corner (x, y), width and height in board points (x grows right, y grows down), and the organizational groups with their members."),
         ToolDefinition(
            name: "element_move",
            description: """
                Moves an element of your board, resizes it, or both; what you leave out stays as it is. An image or video \
                keeps its proportion: give `width` and its height follows. A browser, simulator or event source only moves. \
                A grouped image or video takes its whole group along.
                """,
            inputSchema: ["type": "object", "properties": [
                "element": Self.element,
                "x": ["type": "number", "description": "The new left edge, in board points."],
                "y": ["type": "number", "description": "The new top edge, in board points."],
                "width": ["type": "number", "description": "The new width, in board points."],
                "height": ["type": "number", "description": "The new height, in board points."],
            ] as [String: Any], "required": ["element"]]),
         ToolDefinition(
            name: "group_create",
            description: "Groups images and videos of your board in one column or one row, snapped to the group's grid, on a light panel. One already in another group moves to this one.",
            inputSchema: ["type": "object", "properties": ["elements": Self.members, "direction": Self.direction, "color": Self.color] as [String: Any],
                          "required": ["elements", "direction"]]),
         ToolDefinition(
            name: "group_edit",
            description: "Changes a group: its direction, its color, or its members (`elements` replaces the whole list, in layout order). What you leave out stays.",
            inputSchema: ["type": "object", "properties": ["group": Self.group, "elements": Self.members, "direction": Self.direction, "color": Self.color] as [String: Any],
                          "required": ["group"]]),
         ToolDefinition(
            name: "group_remove",
            description: "Dissolves a group. Its images and videos stay on the board, where they are.",
            inputSchema: ["type": "object", "properties": ["group": Self.group], "required": ["group"]])]
    }

    /// The pictures `arguments["elements"]` names, or why not.
    private func pictures(_ arguments: [String: Any], for caller: UUID) -> Result<[UUID], DecisionDraft.Refused> {
        var ids: [UUID] = []
        for address in arguments["elements"] as? [String] ?? [] {
            switch store.element(address, onBoardOf: caller) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found):
                guard store.image(found.id) != nil else {
                    return .failure(.init(reason: "“\(found.name)” is a \(found.kind.rawValue); groups only take images and videos."))
                }
                if !ids.contains(found.id) { ids.append(found.id) }
            }
        }
        return ids.isEmpty ? .failure(.init(reason: "Give `elements`: the images and videos to group, by name or id.")) : .success(ids)
    }

    private func group(_ arguments: [String: Any], for caller: UUID) -> ImageGroup? {
        findElement(arguments["group"] as? String ?? "", among: store.imageGroups(onBoardOf: caller), id: \.id, name: \.name)
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        let direction = (arguments["direction"] as? String).flatMap(ImageGroup.Direction.init(rawValue:))
        let color = arguments["color"] as? String
        if let color, !ImageGroup.colors.contains(color) { return .error("`color` is one of: \(ImageGroup.colors.joined(separator: ", ")).") }
        if arguments["direction"] != nil, direction == nil { return .error("`direction` is vertical or horizontal.") }
        switch name {
        case "element_layout":
            return .text(listing(for: caller))
        case "group_create":
            guard let direction else { return .error("Give `direction`: vertical or horizontal.") }
            switch pictures(arguments, for: caller) {
            case .failure(let refusal): return .error(refusal.reason)
            case .success(let ids):
                let group = ImageGroup(direction: direction, color: color ?? ImageGroup.colors[0], members: ids)
                store.setImageGroup(group)
                return .text("Made “\(store.imageGroups.first { $0.id == group.id }?.name ?? "")” with \(ids.count) in a \(direction == .vertical ? "column" : "row").")
            }
        case "group_edit":
            guard var group = group(arguments, for: caller) else { return .error("No such group on your board; element_layout lists them.") }
            if arguments["elements"] != nil {
                switch pictures(arguments, for: caller) {
                case .failure(let refusal): return .error(refusal.reason)
                case .success(let ids): group.members = ids
                }
            }
            group.direction = direction ?? group.direction
            group.color = color ?? group.color
            store.setImageGroup(group)
            return .text("Changed “\(group.name)”.")
        case "group_remove":
            guard let group = group(arguments, for: caller) else { return .error("No such group on your board; element_layout lists them.") }
            store.removeImageGroup(group.id)
            return .text("Dissolved “\(group.name)”; its pictures stay where they are.")
        default:
            return await move(arguments, for: caller)
        }
    }

    private func listing(for caller: UUID) -> String {
        func place(_ frame: CGRect) -> String { "x \(Int(frame.minX)), y \(Int(frame.minY)), width \(Int(frame.width)), height \(Int(frame.height))" }
        var lines = store.bus.elements(onBoardOf: caller).compactMap { element -> String? in
            guard let frame = store.frame(of: element.id) else { return nil }
            let group = store.imageGroup(of: element.id).map { ", in group “\($0.name)”" } ?? ""
            return "- “\(element.name)” (\(element.kind.rawValue), id: \(element.id.uuidString)): \(place(frame))\(group)"
        }
        if lines.isEmpty { lines = ["Nothing on your board has a place yet."] }
        let groups = store.imageGroups(onBoardOf: caller).map { group in
            let members = group.members.compactMap { store.image($0) }
            let panel = members.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -ImageGroup.padding, dy: -ImageGroup.padding)
            return "- “\(group.name)” (id: \(group.id.uuidString), \(group.direction.rawValue), \(group.color)): \(place(panel)); members in order: "
                + members.map { "“\($0.name)”" }.joined(separator: ", ")
        }
        return (["Elements (board points; x grows right, y grows down):"] + lines + (groups.isEmpty ? [] : ["Groups:"] + groups)).joined(separator: "\n")
    }

    private func move(_ arguments: [String: Any], for caller: UUID) async -> ToolResult {
        let found: any BoardElement
        switch store.element(arguments["element"], onBoardOf: caller) {
        case .failure(let refusal): return .error(refusal.reason)
        case .success(let element): found = element
        }
        guard var frame = store.frame(of: found.id) else { return .error("“\(found.name)” has no place of its own on the board.") }
        var numbers: [String: CGFloat] = [:]
        for key in ["x", "y", "width", "height"] where arguments[key] != nil {
            guard let number = (arguments[key] as? NSNumber)?.doubleValue, number.isFinite, abs(number) <= 1_000_000 else {
                return .error("`\(key)` is a number of board points.")
            }
            numbers[key] = CGFloat(number.rounded())
        }
        guard !numbers.isEmpty else { return .error("Give `x` and `y` to move it, `width` and `height` to resize it.") }
        frame.origin = CGPoint(x: numbers["x"] ?? frame.minX, y: numbers["y"] ?? frame.minY)
        // The smallest any card gets, as on the board.
        let size = CGSize(width: max(numbers["width"] ?? frame.width, 160), height: max(numbers["height"] ?? frame.height, 120))
        let resizes = numbers["width"] != nil || numbers["height"] != nil
        var note = ""
        let id = found.id
        if let record = store.image(id) {
            if let width = numbers["width"] {
                frame.size = ImageRecord.cardSize(width: min(width, ImageRecord.maximumWidth), for: record.pixelSize)
            } else if numbers["height"] != nil {
                note = " Its size follows `width`; give that to resize it."
            }
            store.updateImage(id) { $0.frame = frame }
            store.imageFrameChanged(id, from: record.frame)
        } else if store.record(id) != nil {
            store.update(id) { $0.frame = CGRect(origin: frame.origin, size: size) }
        } else if store.postIt(id) != nil {
            store.updatePostIt(id) { $0.frame = CGRect(origin: frame.origin, size: size) }
        } else if store.fileTree(id) != nil {
            store.updateFileTree(id) { $0.frame = CGRect(origin: frame.origin, size: size) }
        } else {
            // shortcut: browsers, simulators and event sources size themselves (device, channels), so they only move; add resizing if agents need it.
            if resizes { note = " It only moves: its size is its own." }
            if store.eventSource(id) != nil {
                store.changeEventSource(id) { $0.frame.origin = frame.origin }
            } else {
                let done = await store.relay("board_move", arguments: ["id": id.uuidString, "x": Double(frame.minX), "y": Double(frame.minY)], caller: caller)
                guard !done.isError else { return done }
            }
        }
        let now = store.frame(of: id) ?? frame
        return .text("“\(found.name)” is at x \(Int(now.minX)), y \(Int(now.minY)), \(Int(now.width))×\(Int(now.height)) points.\(note)")
    }
}

extension Orchestrator {
    /// Where an element sits on its board; nil for one without a card of its own (an event channel).
    func frame(of id: UUID) -> CGRect? {
        record(id)?.frame ?? postIt(id)?.frame ?? image(id)?.frame ?? fileTree(id)?.frame ?? eventSource(id)?.frame ?? elementInfo(id)?.frame
    }
}
