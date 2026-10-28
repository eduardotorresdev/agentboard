import CoreGraphics
import Foundation

/// A connection's path on the board: from the edge of its first element's card to the edge of
/// the second's, in horizontal and vertical segments.
public struct Route: Hashable, Sendable {
    public let points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }

    public var length: CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The point `fraction` (0…1) of the way along the route.
    public func point(at fraction: CGFloat) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var remaining = length * min(max(fraction, 0), 1)
        for (start, end) in zip(points, points.dropFirst()) {
            let segment = hypot(end.x - start.x, end.y - start.y)
            if remaining <= segment, segment > 0 {
                let t = remaining / segment
                return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            }
            remaining -= segment
        }
        return points.last ?? .zero
    }

    /// The shortest distance from `point` to the route.
    public func distance(to point: CGPoint) -> CGFloat {
        guard points.count > 1 else { return points.first.map { hypot($0.x - point.x, $0.y - point.y) } ?? .infinity }
        return zip(points, points.dropFirst()).map { start, end in
            let dx = end.x - start.x, dy = end.y - start.y
            let squared = dx * dx + dy * dy
            let t = squared > 0 ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squared, 0), 1) : 0
            return hypot(start.x + dx * t - point.x, start.y + dy * t - point.y)
        }.min() ?? .infinity
    }

    public var reversed: Route { Route(points: points.reversed()) }
}

/// Lays out the lines between cards: horizontal and vertical segments on a grid, around every
/// card and around every other line. Lines never run on top of each other, share a corner or an
/// end, and don't cross either; only when no path around exists does a line cross another (at
/// a right angle), and only when even that fails may it run along one.
///
/// Connections are routed in order, each one around the ones before it, so moving a card only
/// shifts lines that have to give way.
public struct ConnectorRouter: Sendable {
    /// Grid pitch, in points: lines sit on it and parallel lines are at least this far apart.
    public var spacing: CGFloat
    /// The gap kept between a line and any card it passes.
    public var clearance: CGFloat
    /// How far from a card's corners a line may attach (keeps it off the rounded corner).
    public var cornerInset: CGFloat

    /// Search costs, in grid steps: a turn costs as much as `bendCost` steps of length.
    private static let bendCost: Float = 4
    private static let crossingCost: Float = 6
    /// Grid steps of free space searched around the two cards before widening.
    private static let padding = 6

    public init(spacing: CGFloat = 12, clearance: CGFloat = 12, cornerInset: CGFloat = 22) {
        self.spacing = spacing
        self.clearance = clearance
        self.cornerInset = cornerInset
    }

    /// Routes every connection between cards in `cards`; connections with an end not in it are
    /// left out.
    public func route(_ connections: [Connection], around cards: [UUID: CGRect]) -> [UUID: Route] {
        var occupancy = Occupancy()
        return route(connections, around: cards, occupancy: &occupancy)
    }

    /// The line being drawn from `card` (leaving by `side`, if given) to a free point, laid out
    /// after `connections` so they stay put. Nil when the point is too close to a card to reach.
    public func sketch(_ connections: [Connection], around cards: [UUID: CGRect], from card: UUID, side: Side?,
                       to point: CGPoint) -> Route? {
        var occupancy = Occupancy()
        _ = route(connections, around: cards, occupancy: &occupancy)
        guard let a = cards[card] else { return nil }
        let target = GridPoint(x: Int((point.x / spacing).rounded()), y: Int((point.y / spacing).rounded()))
        let goal = Port(node: target, edge: world(target), outward: .up)
        let all = Array(cards.values)
        let region = box(around: [a, CGRect(origin: point, size: .zero)])
        for attempt in [(side, region), (nil, region), (nil, box(around: all + [CGRect(origin: point, size: .zero)]))] {
            if let found = search(from: ports(of: a, side: attempt.0, occupancy: occupancy), to: [goal], anyHeading: true,
                                  region: attempt.1, cards: all, occupancy: occupancy, crossings: false) {
                return Route(points: Self.simplified([found.start.edge] + found.path.map(world)))
            }
        }
        return nil
    }

    private func route(_ connections: [Connection], around cards: [UUID: CGRect], occupancy: inout Occupancy) -> [UUID: Route] {
        var routes: [UUID: Route] = [:]
        let all = Array(cards.values)
        for connection in connections {
            guard let a = cards[connection.a], let b = cards[connection.b] else { continue }
            routes[connection.id] = route(from: a, connection.aSide, to: b, connection.bSide, cards: all, occupancy: &occupancy)
        }
        return routes
    }

    private struct Attempt {
        let region: Box
        /// Keep to the sides the user picked.
        let sides: Bool
        let crossings: Bool
        /// Stay off other lines' segments.
        let respectOthers: Bool
    }

    private func route(from a: CGRect, _ aSide: Side?, to b: CGRect, _ bSide: Side?, cards: [CGRect],
                       occupancy: inout Occupancy) -> Route {
        let near = box(around: [a, b])
        let everything = box(around: cards)
        // Tightest first, then wider and wider: a detour around everything, other sides of the
        // cards, crossing a line; last, if lines box the cards in, running along one.
        var attempts = [Attempt(region: near, sides: true, crossings: false, respectOthers: true)]
        if aSide != nil || bSide != nil {
            attempts.append(Attempt(region: everything, sides: true, crossings: false, respectOthers: true))
        }
        attempts += [
            Attempt(region: everything, sides: false, crossings: false, respectOthers: true),
            Attempt(region: everything, sides: false, crossings: true, respectOthers: true),
            Attempt(region: everything, sides: false, crossings: true, respectOthers: false),
        ]
        for attempt in attempts {
            let others = attempt.respectOthers ? occupancy : Occupancy()
            if let found = search(from: ports(of: a, side: attempt.sides ? aSide : nil, occupancy: others),
                                  to: ports(of: b, side: attempt.sides ? bSide : nil, occupancy: others), anyHeading: false,
                                  region: attempt.region, cards: cards, occupancy: others, crossings: attempt.crossings) {
                occupancy.claim(found.path)
                let points = [found.start.edge] + found.path.map(world) + [found.end.edge]
                return Route(points: Self.simplified(points))
            }
        }
        // The cards overlap: nothing to route around.
        return Route(points: [CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY)])
    }

    // MARK: Grid

    private func world(_ node: GridPoint) -> CGPoint {
        CGPoint(x: CGFloat(node.x) * spacing, y: CGFloat(node.y) * spacing)
    }

    private func inflated(_ card: CGRect) -> CGRect { card.insetBy(dx: -clearance, dy: -clearance) }

    /// The grid region covering `rects` (with their clearance and ports) plus padding.
    private func box(around rects: [CGRect]) -> Box {
        let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        let outer = inflated(union)
        let pad = Self.padding + 1
        return Box(minX: Int((outer.minX / spacing).rounded(.down)) - pad, minY: Int((outer.minY / spacing).rounded(.down)) - pad,
                   maxX: Int((outer.maxX / spacing).rounded(.up)) + pad, maxY: Int((outer.maxY / spacing).rounded(.up)) + pad)
    }

    /// Where lines may attach to `card`: the grid nodes just past its clearance on each side (or
    /// only `side`), away from the corners and not taken by another line.
    private func ports(of card: CGRect, side: Side?, occupancy: Occupancy) -> [Port] {
        let outer = inflated(card)
        let top = Int((outer.minY / spacing).rounded(.up)) - 1
        let bottom = Int((outer.maxY / spacing).rounded(.down)) + 1
        let left = Int((outer.minX / spacing).rounded(.up)) - 1
        let right = Int((outer.maxX / spacing).rounded(.down)) + 1
        func span(_ low: CGFloat, _ high: CGFloat) -> ClosedRange<Int>? {
            let first = Int(((low + cornerInset) / spacing).rounded(.up)), last = Int(((high - cornerInset) / spacing).rounded(.down))
            return first <= last ? first...last : nil
        }
        var ports: [Port] = []
        if let columns = span(card.minX, card.maxX) {
            for x in columns {
                let edgeX = CGFloat(x) * spacing
                ports.append(Port(node: GridPoint(x: x, y: top), edge: CGPoint(x: edgeX, y: card.minY), outward: .up))
                ports.append(Port(node: GridPoint(x: x, y: bottom), edge: CGPoint(x: edgeX, y: card.maxY), outward: .down))
            }
        }
        if let rows = span(card.minY, card.maxY) {
            for y in rows {
                let edgeY = CGFloat(y) * spacing
                ports.append(Port(node: GridPoint(x: left, y: y), edge: CGPoint(x: card.minX, y: edgeY), outward: .left))
                ports.append(Port(node: GridPoint(x: right, y: y), edge: CGPoint(x: card.maxX, y: edgeY), outward: .right))
            }
        }
        let outward = side.map(Direction.init)
        return ports.filter { occupancy.nodes[$0.node] == nil && (outward == nil || $0.outward == outward) }
    }

    // MARK: Search

    /// A* over (node, heading), from any port of the first card to any of `goals`, arriving
    /// head-on unless `anyHeading`. Turns and crossings cost extra; cards, other lines' segments,
    /// corners and ends are walls, and so are other lines themselves unless `crossings`.
    private func search(from starts: [Port], to goals: [Port], anyHeading: Bool, region: Box, cards: [CGRect],
                        occupancy: Occupancy, crossings: Bool) -> (path: [GridPoint], start: Port, end: Port)? {
        guard !starts.isEmpty, !goals.isEmpty else { return nil }
        let width = region.maxX - region.minX + 1, height = region.maxY - region.minY + 1
        var blocked = [Bool](repeating: false, count: width * height)
        for card in cards {
            let outer = inflated(card)
            let x0 = max(region.minX, Int((outer.minX / spacing).rounded(.up))), x1 = min(region.maxX, Int((outer.maxX / spacing).rounded(.down)))
            let y0 = max(region.minY, Int((outer.minY / spacing).rounded(.up))), y1 = min(region.maxY, Int((outer.maxY / spacing).rounded(.down)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 { blocked[(y - region.minY) * width + x - region.minX] = true }
            }
        }
        func index(_ node: GridPoint) -> Int? {
            guard node.x >= region.minX, node.x <= region.maxX, node.y >= region.minY, node.y <= region.maxY else { return nil }
            return (node.y - region.minY) * width + node.x - region.minX
        }

        var goalHeading: [GridPoint: Direction] = [:]
        var goalPorts: [GridPoint: Port] = [:]
        for port in goals where index(port.node).map({ !blocked[$0] }) == true {
            goalHeading[port.node] = port.outward.opposite
            goalPorts[port.node] = port
        }
        guard !goalPorts.isEmpty else { return nil }
        let goalBox = goalPorts.keys.reduce(Box(minX: .max, minY: .max, maxX: .min, maxY: .min)) { $0.including($1) }
        func estimate(_ node: GridPoint) -> Float {
            let dx = max(goalBox.minX - node.x, 0, node.x - goalBox.maxX)
            let dy = max(goalBox.minY - node.y, 0, node.y - goalBox.maxY)
            return Float(dx + dy)
        }

        let states = width * height * 4
        var cost = [Float](repeating: .infinity, count: states)
        var previous = [Int32](repeating: -1, count: states)
        var open = Heap()
        var startPorts: [GridPoint: Port] = [:]
        for port in starts {
            guard let node = index(port.node), !blocked[node] else { continue }
            let state = node * 4 + port.outward.rawValue
            cost[state] = 0
            startPorts[port.node] = port
            open.push(estimate(port.node), state)
        }

        func node(of state: Int) -> GridPoint {
            let cell = state / 4
            return GridPoint(x: region.minX + cell % width, y: region.minY + cell / width)
        }

        while let (priority, state) = open.pop() {
            let here = node(of: state)
            let heading = Direction(rawValue: state % 4)!
            let spent = cost[state]
            if priority > spent + estimate(here) + 0.0001 { continue }
            if anyHeading || goalHeading[here] == heading, let end = goalPorts[here] {
                var path = [here]
                var cursor = state
                while previous[cursor] >= 0 {
                    cursor = Int(previous[cursor])
                    path.append(node(of: cursor))
                }
                path.reverse()
                guard let start = startPorts[path[0]] else { return nil }
                return (path, start, end)
            }
            // Crossing another line: straight through only.
            let crossing = occupancy.nodes[here] != nil
            for next in Direction.allCases where next != heading.opposite && (!crossing || next == heading) {
                let neighbor = here.moved(next)
                guard let cell = index(neighbor), !blocked[cell], !occupancy.edges.contains(Edge(here, next)) else { continue }
                var step: Float = 1
                if next != heading { step += Self.bendCost }
                switch occupancy.nodes[neighbor] {
                case nil: break
                case .fixed: continue
                case .straight(let horizontal):
                    if !crossings || horizontal == next.isHorizontal { continue }
                    step += Self.crossingCost
                }
                let target = cell * 4 + next.rawValue
                let total = spent + step
                guard total < cost[target] else { continue }
                cost[target] = total
                previous[target] = Int32(state)
                open.push(total + estimate(neighbor), target)
            }
        }
        return nil
    }

    /// Drops points in the middle of straight runs.
    private static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, last == point { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if (a.x == b.x && b.x == point.x) || (a.y == b.y && b.y == point.y) {
                    result[result.count - 1] = point
                    continue
                }
            }
            result.append(point)
        }
        return result
    }
}

// MARK: - Search types

private enum Direction: Int, CaseIterable {
    case right, down, left, up

    init(_ side: Side) {
        self = switch side {
        case .top: .up
        case .right: .right
        case .bottom: .down
        case .left: .left
        }
    }

    var opposite: Direction { Direction(rawValue: (rawValue + 2) % 4)! }
    var isHorizontal: Bool { self == .right || self == .left }
}

private struct GridPoint: Hashable {
    var x: Int
    var y: Int

    func moved(_ direction: Direction) -> GridPoint {
        switch direction {
        case .right: GridPoint(x: x + 1, y: y)
        case .left: GridPoint(x: x - 1, y: y)
        case .down: GridPoint(x: x, y: y + 1)
        case .up: GridPoint(x: x, y: y - 1)
        }
    }
}

private struct Box {
    var minX: Int, minY: Int, maxX: Int, maxY: Int

    func including(_ node: GridPoint) -> Box {
        Box(minX: min(minX, node.x), minY: min(minY, node.y), maxX: max(maxX, node.x), maxY: max(maxY, node.y))
    }
}

/// A place a line meets a card: the grid node it leaves from, the point on the card's edge
/// it is drawn to, and the side it faces.
private struct Port {
    let node: GridPoint
    let edge: CGPoint
    let outward: Direction
}

/// One grid step, the same whichever end it is walked from.
private struct Edge: Hashable {
    let x: Int, y: Int
    let horizontal: Bool

    init(_ node: GridPoint, _ direction: Direction) {
        let other = node.moved(direction)
        x = min(node.x, other.x)
        y = min(node.y, other.y)
        horizontal = direction.isHorizontal
    }
}

/// What routed lines already hold.
private struct Occupancy {
    enum Use {
        /// A line runs straight through, horizontally or vertically: a later line may cross it.
        case straight(horizontal: Bool)
        /// A corner, an end or a crossing: nothing else may pass.
        case fixed
    }

    var edges: Set<Edge> = []
    var nodes: [GridPoint: Use] = [:]

    mutating func claim(_ path: [GridPoint]) {
        for (index, node) in path.enumerated() {
            var use = Use.fixed
            if index > 0, index < path.count - 1 {
                let before = path[index - 1], after = path[index + 1]
                if before.y == after.y { use = .straight(horizontal: true) } else if before.x == after.x { use = .straight(horizontal: false) }
            }
            nodes[node] = nodes[node] == nil ? use : .fixed
            if index > 0 {
                let before = path[index - 1]
                let direction: Direction = before.x < node.x ? .right : before.x > node.x ? .left : before.y < node.y ? .down : .up
                edges.insert(Edge(before, direction))
            }
        }
    }
}

/// Min-heap of search states by priority.
private struct Heap {
    private var items: [(priority: Float, state: Int)] = []

    mutating func push(_ priority: Float, _ state: Int) {
        items.append((priority, state))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].priority < items[parent].priority else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Float, Int)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (first.priority, first.state)
    }
}
