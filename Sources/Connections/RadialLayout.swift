import CoreGraphics
import Foundation

/// Organizes a canvas radially around its most connected agent.
///
/// Each agent (hub) forms a cluster with the non-agent cards joined to it (runners, post-its,
/// images, browsers), placed on a ring around it. The busiest cluster sits in the center; the
/// others go on concentric rings around it, connected clusters next to each other (breadth
/// first along agent-to-agent lines), unconnected cards last, on the outer rings.
///
/// Positions depend only on the input order (creation order), the sizes and the lines, never
/// on where cards sit now, so organizing twice changes nothing and a new card (last in the
/// order) lands at the end of the outer ring. The center card keeps its position.
public enum RadialLayout {
    /// The least room between two cards.
    public static let gap: CGFloat = 48
    /// The room a card takes.
    static func footprint(_ item: BoardLayout.Item) -> CGSize { item.frame.size }

    public static func organize(_ items: [BoardLayout.Item], connections: [Connection]) -> [UUID: CGRect] {
        guard !items.isEmpty else { return [:] }
        let order = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var peers: [UUID: [UUID]] = [:]
        for c in connections where c.a != c.b && byID[c.a] != nil && byID[c.b] != nil {
            peers[c.a, default: []].append(c.b)
            peers[c.b, default: []].append(c.a)
        }
        func sorted(_ ids: some Sequence<UUID>) -> [UUID] { Set(ids).sorted { order[$0]! < order[$1]! } }
        func degree(_ id: UUID) -> Int { Set(peers[id] ?? []).count }

        // Clusters: every hub, then hub-less cards around their most connected one.
        var owner: [UUID: UUID] = [:]
        let hubs = items.filter(\.isHub).map(\.id)
        for hub in hubs { owner[hub] = hub }
        for hub in hubs.sorted(by: { degree($0) != degree($1) ? degree($0) > degree($1) : order[$0]! < order[$1]! }) {
            for peer in sorted(peers[hub] ?? []) where owner[peer] == nil { owner[peer] = hub }
        }
        let rest = items.map(\.id).filter { owner[$0] == nil }
        for id in rest.sorted(by: { degree($0) != degree($1) ? degree($0) > degree($1) : order[$0]! < order[$1]! })
        where owner[id] == nil {
            owner[id] = id
            // Its unowned component hangs from it.
            var queue = [id]
            while !queue.isEmpty {
                for peer in sorted(peers[queue.removeFirst()] ?? []) where owner[peer] == nil {
                    owner[peer] = id
                    queue.append(peer)
                }
            }
        }
        var members: [UUID: [UUID]] = [:]
        for item in items where owner[item.id] != item.id { members[owner[item.id]!, default: []].append(item.id) }

        // Each cluster as a disc: its center card in the middle, its cards on a ring around it.
        func radius(_ id: UUID) -> CGFloat {
            let size = footprint(byID[id]!)
            return (size.width * size.width + size.height * size.height).squareRoot() / 2 + gap / 2
        }
        var offsets: [UUID: CGPoint] = [:]  // Card centers relative to their cluster's center.
        var discs: [UUID: CGFloat] = [:]
        for center in Set(owner.values) {
            offsets[center] = .zero
            let satellites = members[center] ?? []
            guard !satellites.isEmpty else {
                discs[center] = radius(center)
                continue
            }
            let (ring, angles) = ringFit(satellites.map(radius), inner: radius(center))
            var angle = -CGFloat.pi / 2
            for (index, id) in satellites.enumerated() {
                angle += angles[index] / 2
                offsets[id] = CGPoint(x: cos(angle) * ring, y: sin(angle) * ring)
                angle += angles[index] / 2
            }
            discs[center] = ring + satellites.map(radius).max()!
        }

        // Cluster graph, then the ring order: center's component breadth first, other components, then loners.
        var links: [UUID: Set<UUID>] = [:]
        for (id, list) in peers {
            for peer in list where owner[id] != owner[peer] { links[owner[id]!, default: []].insert(owner[peer]!) }
        }
        func weight(_ c: UUID) -> Int { degree(c) + (members[c]?.count ?? 0) }
        let clusters = sorted(Set(owner.values))
        let core = clusters.min { weight($0) != weight($1) ? weight($0) > weight($1) : order[$0]! < order[$1]! }!
        var ringOrder: [UUID] = []
        var seen: Set<UUID> = [core]
        var loners: [UUID] = []
        for start in [core] + clusters where start == core || !seen.contains(start) {
            if start != core && links[start] == nil && members[start] == nil {
                loners.append(start)
                continue
            }
            seen.insert(start)
            var queue = [start]
            if start != core { ringOrder.append(start) }
            while !queue.isEmpty {
                for next in sorted(links[queue.removeFirst()] ?? []) where !seen.contains(next) {
                    seen.insert(next)
                    ringOrder.append(next)
                    queue.append(next)
                }
            }
        }
        let firstLoner = ringOrder.count
        ringOrder += loners

        // Concentric rings, each as small as its discs allow, filled in order.
        var clusterCenters: [UUID: CGPoint] = [core: .zero]
        var inner = discs[core]!
        var index = 0
        while index < ringOrder.count {
            var count = 1
            // Loners start a ring of their own, so adding one never moves a connected card.
            while index + count < ringOrder.count, index + count != firstLoner,
                  ringFit(ringOrder[index...(index + count)].map { discs[$0]! }, inner: inner, grow: false) != nil {
                count += 1
            }
            let ringDiscs = ringOrder[index..<(index + count)].map { discs[$0]! }
            let (ring, angles) = ringFit(ringDiscs, inner: inner)
            var angle = -CGFloat.pi / 2
            for (offset, id) in ringOrder[index..<(index + count)].enumerated() {
                angle += angles[offset] / 2
                clusterCenters[id] = CGPoint(x: cos(angle) * ring, y: sin(angle) * ring)
                angle += angles[offset] / 2
            }
            inner = ring + ringDiscs.max()!
            index += count
        }

        // Anchored on the center card's current center.
        let anchor = CGPoint(x: byID[core]!.frame.midX, y: byID[core]!.frame.minY + footprint(byID[core]!).height / 2)
        var result: [UUID: CGRect] = [:]
        for item in items {
            let cluster = clusterCenters[owner[item.id]!]!, offset = offsets[item.id]!
            let size = footprint(item)
            let x = (anchor.x + cluster.x + offset.x - size.width / 2).rounded()
            let y = (anchor.y + cluster.y + offset.y - size.height / 2).rounded()
            result[item.id] = CGRect(origin: CGPoint(x: x, y: y), size: item.frame.size)
        }
        return result
    }

    /// The radius of a ring around a disc of `inner` that holds discs of `radii` without touching,
    /// and the angle each one gets, spread evenly. With `grow: false`, nil when they need a
    /// radius beyond the smallest one (the ring would have to grow to take them).
    static func ringFit(_ radii: [CGFloat], inner: CGFloat, grow: Bool) -> (CGFloat, [CGFloat])? {
        let base = inner + radii.max()!
        var ring = base
        func angle(_ r: CGFloat) -> CGFloat { 2 * asin(min(1, r / ring)) }
        while radii.count > 1, radii.map(angle).reduce(0, +) > 2 * .pi {
            guard grow else { return nil }
            ring *= 1.05
        }
        guard radii.count > 1 else { return (ring, [2 * .pi]) }
        let used = radii.map(angle)
        let spare = (2 * .pi - used.reduce(0, +)) / CGFloat(radii.count)
        return (ring, used.map { $0 + spare })
    }

    static func ringFit(_ radii: [CGFloat], inner: CGFloat) -> (CGFloat, [CGFloat]) {
        ringFit(radii, inner: inner, grow: true)!
    }
}
