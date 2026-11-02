import CoreGraphics
import Foundation

/// How a canvas arranges its cards, and so where a new one goes.
///
/// Cards joined by lines form a group. A group grows as a tree to the right of its hub (the agent
/// with the most lines): each card's peers stack in the column right of it, top-aligned with
/// it. Groups, and the cards on their own, are then packed in reading order into rows about as
/// wide as the screen, each taking the first free spot from the top-left.
///
/// A new card follows the same rules: one an agent adds, connected to it, goes in the column
/// right of that agent, below the cards already there; any other takes the first free spot in
/// the rows, as a group of its own would.
public enum BoardLayout {
    public struct Item: Hashable, Sendable {
        public let id: UUID
        public let frame: CGRect
        /// An agent: what a group prefers to grow from.
        public let isHub: Bool

        public init(id: UUID, frame: CGRect, isHub: Bool) {
            self.id = id
            self.frame = frame
            self.isHub = isHub
        }
    }

    /// Between a card and the column of its peers.
    public static let columnGap: CGFloat = 64
    /// Between cards stacked in a column.
    public static let rowGap: CGFloat = 32
    /// Between groups.
    public static let groupGap: CGFloat = 96
    /// The width over height the rows aim for when no screen says otherwise.
    public static let defaultAspect: CGFloat = 16 / 10

    // MARK: Organizing

    /// Where every card goes, starting from the top-left corner the cards occupy now. Cards
    /// keep their size; only the origin changes.
    public static func organize(_ items: [Item], connections: [Connection], aspect: CGFloat = defaultAspect) -> [UUID: CGRect] {
        guard let bounds = union(items.map(\.frame)) else { return [:] }
        let groups = self.groups(items, connections: connections).map { arrange($0, connections: connections) }
        // Reading order of where the groups are now, so the result still looks familiar.
        let ordered = groups.sorted { readingOrder($0.original, $1.original) }
        let width = rowWidth(for: ordered.map(\.size), aspect: aspect)
        var placed: [CGRect] = []
        var result: [UUID: CGRect] = [:]
        for group in ordered {
            let origin = firstFit(group.size, among: placed, origin: bounds.origin, width: width, gap: groupGap)
            placed.append(CGRect(origin: origin, size: group.size))
            for (id, frame) in group.frames {
                result[id] = frame.offsetBy(dx: origin.x, dy: origin.y)
            }
        }
        return result
    }

    // MARK: New cards

    /// Where a new card of `size` goes. Connected to `parent`: in the column right of it,
    /// below the cards in the way. Otherwise: the first free spot in the rows of groups.
    /// nil when the canvas is empty (or `parent` isn't on it), for the caller to pick.
    public static func slot(for size: CGSize, parent: UUID? = nil, among items: [Item], connections: [Connection],
                            aspect: CGFloat = defaultAspect) -> CGPoint? {
        if let parent {
            guard let frame = items.first(where: { $0.id == parent })?.frame else { return nil }
            return slot(for: size, rightOf: frame, among: items.map(\.frame))
        }
        guard let bounds = union(items.map(\.frame)) else { return nil }
        let boxes = groups(items, connections: connections).compactMap { union($0.map(\.frame)) }
        let width = rowWidth(for: boxes.map(\.size) + [size], aspect: aspect)
        return firstFit(size, among: boxes, origin: bounds.origin, width: width, gap: groupGap)
    }

    /// The column right of `frame`, at its top or below whatever is in the way there.
    private static func slot(for size: CGSize, rightOf frame: CGRect, among frames: [CGRect]) -> CGPoint {
        let x = frame.maxX + columnGap
        let tops = [frame.minY] + frames.map { $0.maxY + rowGap }.filter { $0 > frame.minY }
        for y in Set(tops).sorted() {
            let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if !frames.contains(where: { overlaps($0, candidate, gap: rowGap) }) { return candidate.origin }
        }
        // Unreachable: below the lowest card nothing is in the way.
        return CGPoint(x: x, y: (frames.map(\.maxY).max() ?? frame.minY) + rowGap)
    }

    // MARK: Groups

    /// The cards joined by lines, each group in the order the items came.
    static func groups(_ items: [Item], connections: [Connection]) -> [[Item]] {
        var parent = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.id) })
        func root(_ id: UUID) -> UUID {
            var id = id
            while let next = parent[id], next != id {
                parent[id] = parent[next]
                id = next
            }
            return id
        }
        for connection in connections where parent[connection.a] != nil && parent[connection.b] != nil {
            let a = root(connection.a), b = root(connection.b)
            if a != b { parent[a] = b }
        }
        var order: [UUID] = []
        var members: [UUID: [Item]] = [:]
        for item in items {
            let key = root(item.id)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(item)
        }
        return order.compactMap { members[$0] }
    }

    private struct Arranged {
        /// Relative to the group's top-left corner.
        var frames: [UUID: CGRect]
        var size: CGSize
        /// Where the group sits now.
        var original: CGRect
    }

    /// Lays a group out as a tree growing right from its hub.
    private static func arrange(_ group: [Item], connections: [Connection]) -> Arranged {
        let byID = Dictionary(uniqueKeysWithValues: group.map { ($0.id, $0) })
        var peers: [UUID: [UUID]] = [:]
        for connection in connections where byID[connection.a] != nil && byID[connection.b] != nil && connection.a != connection.b {
            peers[connection.a, default: []].append(connection.b)
            peers[connection.b, default: []].append(connection.a)
        }
        func degree(_ item: Item) -> Int { Set(peers[item.id] ?? []).count }
        let hub = group.min { a, b in
            if a.isHub != b.isHub { return a.isHub }
            if degree(a) != degree(b) { return degree(a) > degree(b) }
            return readingOrder(a.frame, b.frame)
        }!

        // Breadth first, so each card hangs from the closest card to the hub it is joined to.
        var children: [UUID: [UUID]] = [:]
        var seen: Set<UUID> = [hub.id]
        var queue = [hub.id]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            let next = Set(peers[id] ?? []).subtracting(seen).compactMap { byID[$0] }
                .sorted { readingOrder($0.frame, $1.frame) }.map(\.id)
            seen.formUnion(next)
            children[id] = next
            queue += next
        }

        var frames: [UUID: CGRect] = [:]
        /// Places `id` at `origin` with its peers to the right; answers the height it all takes.
        func place(_ id: UUID, at origin: CGPoint) -> CGFloat {
            let size = byID[id]!.frame.size
            frames[id] = CGRect(origin: origin, size: size)
            var y = origin.y
            for child in children[id] ?? [] {
                y += place(child, at: CGPoint(x: origin.x + size.width + columnGap, y: y)) + rowGap
            }
            let stacked = (children[id] ?? []).isEmpty ? 0 : y - rowGap - origin.y
            return max(size.height, stacked)
        }
        _ = place(hub.id, at: .zero)
        let bounds = union(Array(frames.values)) ?? .zero
        return Arranged(frames: frames, size: bounds.size, original: union(group.map(\.frame)) ?? .zero)
    }

    // MARK: Packing

    /// About as wide as the screen's shape for this much area, and never narrower than the widest group.
    private static func rowWidth(for sizes: [CGSize], aspect: CGFloat) -> CGFloat {
        let area = sizes.reduce(0) { $0 + ($1.width + groupGap) * ($1.height + groupGap) }
        return max(sizes.map(\.width).max() ?? 0, (area * max(aspect, 0.1)).squareRoot())
    }

    /// The first spot, top to bottom then left to right, where `size` fits within `width` of
    /// `origin.x` without coming closer than `gap` to anything placed.
    private static func firstFit(_ size: CGSize, among placed: [CGRect], origin: CGPoint, width: CGFloat, gap: CGFloat) -> CGPoint {
        let xs = [origin.x] + placed.map { $0.maxX + gap }
        let ys = [origin.y] + placed.map { $0.maxY + gap }
        var candidates: [CGPoint] = []
        for y in Set(ys) where y >= origin.y {
            for x in Set(xs) where x >= origin.x && (x == origin.x || x + size.width <= origin.x + width) {
                candidates.append(CGPoint(x: x, y: y))
            }
        }
        candidates.sort { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        for candidate in candidates {
            let rect = CGRect(origin: candidate, size: size)
            if !placed.contains(where: { overlaps($0, rect, gap: gap) }) { return candidate }
        }
        // Unreachable: below everything at the left edge is always free.
        return CGPoint(x: origin.x, y: (placed.map(\.maxY).max() ?? origin.y) + gap)
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect, gap: CGFloat) -> Bool {
        // A hair under the gap, so cards exactly `gap` apart still fit.
        a.insetBy(dx: -(gap - 0.5), dy: -(gap - 0.5)).intersects(b)
    }

    private static func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
    }

    private static func union(_ frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
