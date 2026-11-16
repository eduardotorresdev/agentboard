import CoreGraphics
import Foundation
import Testing
import Connections

struct RadialLayoutTests {
    private func item(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 400, _ height: CGFloat = 300, hub: Bool = false) -> BoardLayout.Item {
        BoardLayout.Item(id: UUID(), frame: CGRect(x: x, y: y, width: width, height: height), isHub: hub)
    }

    private func noOverlaps(_ frames: [CGRect]) -> Bool {
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] where a.intersects(b) { return false }
        }
        return true
    }

    /// Agents with runners, notes and images, a couple linked to each other, and loners.
    private func board(agents: Int) -> ([BoardLayout.Item], [Connection]) {
        var items: [BoardLayout.Item] = [], lines: [Connection] = []
        var previous: UUID?
        for index in 0..<agents {
            let agent = item(CGFloat(index) * 13, 0, 640, 420, hub: true)
            let runner = item(0, CGFloat(index) * 7, 500, 260)
            let note = item(5, 5, 280, 240)
            items += [agent, runner, note]
            lines += [Connection(a: agent.id, b: runner.id), Connection(a: note.id, b: agent.id)]
            if index % 2 == 1, let previous { lines.append(Connection(a: previous, b: agent.id)) }
            previous = agent.id
        }
        items += (0..<3).map { _ in item(0, 0, 900, 600) }
        return (items, lines)
    }

    @Test func oneCardStaysPut() {
        let lone = item(120, -40)
        #expect(RadialLayout.organize([lone], connections: []) == [lone.id: lone.frame])
    }

    @Test func manyCardsNeverOverlapAndKeepTheirSize() {
        let (items, lines) = board(agents: 12)
        let result = RadialLayout.organize(items, connections: lines)
        #expect(result.count == items.count)
        #expect(noOverlaps(Array(result.values)))
        for item in items { #expect(result[item.id]!.size == item.frame.size) }
    }

    @Test func noCardCoversAnAgentsComposer() {
        let (items, lines) = board(agents: 8)
        let result = RadialLayout.organize(items, connections: lines)
        let footprints = items.map { item -> CGRect in
            var frame = result[item.id]!
            if item.isHub { frame.size.height += RadialLayout.composerRoom }
            return frame
        }
        #expect(noOverlaps(footprints))
    }

    @Test func satellitesSitNextToTheirAgent() {
        let (items, lines) = board(agents: 6)
        let result = RadialLayout.organize(items, connections: lines)
        let agent = result[items[3].id]!, runner = result[items[4].id]!, far = result[items[9].id]!
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }
        #expect(distance(agent, runner) < distance(agent, far))
    }

    @Test func organizingTwiceChangesNothing() {
        let (items, lines) = board(agents: 5)
        let first = RadialLayout.organize(items, connections: lines)
        let moved = items.map { BoardLayout.Item(id: $0.id, frame: first[$0.id]!, isHub: $0.isHub) }
        #expect(RadialLayout.organize(moved, connections: lines) == first)
    }

    @Test func aNewLonerLeavesTheConnectedCardsWhereTheyWere() {
        let (items, lines) = board(agents: 4)
        let before = RadialLayout.organize(items, connections: lines)
        let after = RadialLayout.organize(items + [item(0, 0, 280, 240)], connections: lines)
        // The 12 connected cards keep their spots; only the loners' ring makes room.
        for item in items.prefix(12) { #expect(after[item.id] == before[item.id]) }
    }
}
