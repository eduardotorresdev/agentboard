import CoreGraphics
import Foundation

/// A connection's path on the board, from its first element's card to its second's.
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

extension Side {
    /// The way out of a card through this side, in board coordinates (y grows downward).
    public var outward: CGVector {
        switch self {
        case .top: CGVector(dx: 0, dy: -1)
        case .right: CGVector(dx: 1, dy: 0)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        }
    }
}

/// Where a rope is tied: a point, and the direction the rope leaves it in, like a cable out of
/// its plug (zero for a loose end, such as one held by the pointer).
public struct RopeAnchor: Equatable, Sendable {
    public var point: CGPoint
    public var direction: CGVector

    public init(point: CGPoint, direction: CGVector = .zero) {
        self.point = point
        self.direction = direction
    }

    public init(point: CGPoint, side: Side) {
        self.init(point: point, direction: side.outward)
    }
}

/// A line between two cards that hangs like a rope: a chain of particles under gravity (Verlet
/// integration), held a fixed distance apart. The chain hangs from a point a little way out of
/// each card; from the card to the chain the line leaves straight out of its side, like a cable
/// out of a plug, and bends into the chain on its tangent. It swings when an end moves until it
/// comes to rest.
///
/// The rope's length follows its ends: a little longer than the distance between them, so it
/// always hangs slack. When the ends move apart faster than it grows, it stretches taut and
/// springs back.
public struct Rope: Sendable {
    private var chain: [CGPoint]
    private var previous: [CGPoint]
    private var restLength: CGFloat
    private var anchors: (a: RopeAnchor, b: RopeAnchor)
    /// Seconds of simulation owed to the clock, under one step.
    private var owed: CGFloat = 0
    /// Steps in a row nothing moved.
    private var calm = 0
    public private(set) var isSettled = false

    static let particles = 41
    /// Points per second squared.
    static let gravity: CGFloat = 1600
    static let timestep: CGFloat = 1.0 / 120
    static let iterations = 16
    /// Velocity kept per step.
    static let damping: CGFloat = 0.982
    /// Extra length, as a fraction of the span, that makes the rope sag.
    static let slack: CGFloat = 0.07
    /// How far out of a card the line runs before the chain hangs, at most.
    static let maximumLead: CGFloat = 22
    /// How fast the rope's length catches up with its ends, per step.
    static let growth: CGFloat = 0.12
    /// Movement, in points per step, below which the rope counts as still.
    static let stillness: CGFloat = 0.01

    public init(from a: RopeAnchor, to b: RopeAnchor) {
        anchors = (a, b)
        let (start, end) = Self.hangingPoints(a, b)
        restLength = Self.length(from: start, to: end)
        if hypot(end.x - start.x, end.y - start.y) < 1 {
            // Ends together (a line starting to be drawn): bunched up, ready to fall.
            chain = (0..<Self.particles).map { CGPoint(x: start.x, y: start.y + CGFloat($0) * 0.5) }
        } else {
            // Laid out along a curve leaving each end in its direction; gravity takes it from there.
            let lead = Self.lead(a, b)
            let c1 = CGPoint(x: start.x + a.direction.dx * lead, y: start.y + a.direction.dy * lead)
            let c2 = CGPoint(x: end.x + b.direction.dx * lead, y: end.y + b.direction.dy * lead)
            chain = (0..<Self.particles).map { Self.bezier(start, c1, c2, end, CGFloat($0) / CGFloat(Self.particles - 1)) }
        }
        previous = chain
    }

    /// A rope already hanging at rest between `a` and `b`, for lines that are just there (the
    /// board opening) rather than drawn.
    public static func resting(from a: RopeAnchor, to b: RopeAnchor) -> Rope {
        var rope = Rope(from: a, to: b)
        for _ in 0..<1200 where !rope.isSettled { rope.step() }
        rope.previous = rope.chain
        rope.isSettled = true
        return rope
    }

    /// The line as drawn, from the first anchor to the second.
    public var points: [CGPoint] {
        let last = chain.count - 1
        // Where the plugs blend into the chain: past the droop by its hanging points.
        let (a, b) = anchors
        let reach = Self.lead(a, b) * 2
        let joinA = a.direction == .zero ? 0 : join(from: 0, step: 1, after: reach)
        let joinB = b.direction == .zero ? last : join(from: last, step: -1, after: reach)
        guard joinA < joinB else { return [a.point] + chain + [b.point] }
        let head = a.direction == .zero ? [a.point] : plug(a, into: joinA, step: 1)
        let tail = b.direction == .zero ? [b.point] : plug(b, into: joinB, step: -1).reversed()
        return head + chain[(joinA + 1)..<joinB] + tail
    }

    public var route: Route { Route(points: points) }

    /// Moves the rope's ends to `a` and `b`; it wakes up if they changed.
    public mutating func tie(_ a: RopeAnchor, _ b: RopeAnchor) {
        guard !Self.close(a, anchors.a) || !Self.close(b, anchors.b) else { return }
        anchors = (a, b)
        isSettled = false
        calm = 0
    }

    /// Runs the simulation `seconds` forward, in fixed steps.
    public mutating func advance(by seconds: CGFloat) {
        guard !isSettled else { return }
        // A long pause (the window hidden, a breakpoint) isn't caught up on.
        owed = min(owed + max(seconds, 0), Self.timestep * 6)
        while owed >= Self.timestep, !isSettled {
            owed -= Self.timestep
            step()
        }
    }

    mutating func step() {
        let (start, end) = Self.hangingPoints(anchors.a, anchors.b)
        let last = chain.count - 1
        restLength += (Self.length(from: start, to: end) - restLength) * Self.growth
        let rest = restLength / CGFloat(last)
        let fall = Self.gravity * Self.timestep * Self.timestep
        let before = chain
        for index in 1..<last {
            let point = chain[index], old = previous[index]
            previous[index] = point
            chain[index] = CGPoint(x: point.x + (point.x - old.x) * Self.damping, y: point.y + (point.y - old.y) * Self.damping + fall)
        }
        chain[0] = start
        chain[last] = end
        previous[0] = start
        previous[last] = end
        for _ in 0..<Self.iterations {
            for index in 0..<last {
                let p = chain[index], q = chain[index + 1]
                let dx = q.x - p.x, dy = q.y - p.y
                let distance = hypot(dx, dy)
                guard distance > 0.0001 else { continue }
                let error = (distance - rest) / distance
                // The hanging points don't move: the free particle takes the whole correction.
                let share: (CGFloat, CGFloat) = index == 0 ? (0, 1) : index + 1 == last ? (1, 0) : (0.5, 0.5)
                chain[index] = CGPoint(x: p.x + dx * error * share.0, y: p.y + dy * error * share.0)
                chain[index + 1] = CGPoint(x: q.x - dx * error * share.1, y: q.y - dy * error * share.1)
            }
        }
        let moved = chain.indices.map { hypot(chain[$0].x - before[$0].x, chain[$0].y - before[$0].y) }.max() ?? 0
        calm = moved < Self.stillness ? calm + 1 : 0
        if calm >= 30 {
            previous = chain
            isSettled = true
        }
    }

    /// The first chain particle at least `distance` along the chain from `end`.
    private func join(from end: Int, step: Int, after distance: CGFloat) -> Int {
        var index = end, travelled: CGFloat = 0
        while index + step >= 0, index + step < chain.count, travelled < distance {
            let next = index + step
            travelled += hypot(chain[next].x - chain[index].x, chain[next].y - chain[index].y)
            index = next
        }
        return index
    }

    /// The stretch from an anchor into chain particle `join`: straight out of the card, then
    /// bending to meet the chain along it.
    private func plug(_ anchor: RopeAnchor, into join: Int, step: Int) -> [CGPoint] {
        let target = chain[join]
        let gap = hypot(target.x - anchor.point.x, target.y - anchor.point.y)
        let ahead = chain[min(max(join + step, 0), chain.count - 1)], behind = chain[join - step]
        var tangent = CGVector(dx: ahead.x - behind.x, dy: ahead.y - behind.y)
        let size = hypot(tangent.dx, tangent.dy)
        tangent = size > 0 ? CGVector(dx: tangent.dx / size, dy: tangent.dy / size) : .zero
        let c1 = CGPoint(x: anchor.point.x + anchor.direction.dx * gap * 0.5, y: anchor.point.y + anchor.direction.dy * gap * 0.5)
        let c2 = CGPoint(x: target.x - tangent.dx * gap * 0.3, y: target.y - tangent.dy * gap * 0.3)
        let samples = 10
        return (0...samples).map { Self.bezier(anchor.point, c1, c2, target, CGFloat($0) / CGFloat(samples)) }
    }

    private static func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                       y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y)
    }

    /// How far out of each card the line runs before the chain hangs: less when the cards are close.
    static func lead(_ a: RopeAnchor, _ b: RopeAnchor) -> CGFloat {
        min(maximumLead, hypot(b.point.x - a.point.x, b.point.y - a.point.y) * 0.12 + 4)
    }

    /// The points the chain hangs from, a lead out of each card.
    static func hangingPoints(_ a: RopeAnchor, _ b: RopeAnchor) -> (CGPoint, CGPoint) {
        let lead = lead(a, b)
        return (CGPoint(x: a.point.x + a.direction.dx * lead, y: a.point.y + a.direction.dy * lead),
                CGPoint(x: b.point.x + b.direction.dx * lead, y: b.point.y + b.direction.dy * lead))
    }

    /// The chain's natural length between its hanging points: across, plus slack.
    static func length(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y) * (1 + slack) + 16
    }

    private static func close(_ x: RopeAnchor, _ y: RopeAnchor) -> Bool {
        abs(x.point.x - y.point.x) < 0.01 && abs(x.point.y - y.point.y) < 0.01 && x.direction == y.direction
    }
}
