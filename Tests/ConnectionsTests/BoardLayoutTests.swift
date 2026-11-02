import CoreGraphics
import Foundation
import Testing
import Connections

struct BoardLayoutTests {
    private func item(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 400, _ height: CGFloat = 300, hub: Bool = false) -> BoardLayout.Item {
        BoardLayout.Item(id: UUID(), frame: CGRect(x: x, y: y, width: width, height: height), isHub: hub)
    }

    private func noOverlaps(_ frames: [CGRect]) -> Bool {
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] where a.intersects(b) { return false }
        }
        return true
    }

    @Test func connectedCardsStackInTheColumnRightOfTheirAgent() {
        let runner = item(-900, 700, 500, 260)
        let agent = item(300, 300, 640, 420, hub: true)
        let note = item(2000, -50, 280, 240)
        let lines = [Connection(a: runner.id, b: agent.id), Connection(a: agent.id, b: note.id)]

        let result = BoardLayout.organize([runner, agent, note], connections: lines)

        let a = result[agent.id]!, r = result[runner.id]!, n = result[note.id]!
        // The agent is the root, whichever card came first or sat furthest up.
        #expect(r.minX == a.maxX + BoardLayout.columnGap)
        #expect(n.minX == a.maxX + BoardLayout.columnGap)
        // Its peers stack top-aligned with it, in the order they sat (the note was higher).
        #expect(n.minY == a.minY)
        #expect(r.minY == n.maxY + BoardLayout.rowGap)
        // Sizes stay.
        #expect(r.size == runner.frame.size)
    }

    @Test func groupsPackFromTheCardsTopLeftCornerWithoutOverlapping() {
        var items: [BoardLayout.Item] = []
        var lines: [Connection] = []
        for index in 0..<5 {
            let agent = item(CGFloat(index) * 37, CGFloat(index) * 53, 640, 420, hub: true)
            let runner = item(CGFloat(index) * 41, CGFloat(index) * 29, 500, 260)
            items += [agent, runner]
            lines.append(Connection(a: agent.id, b: runner.id))
        }
        items += (0..<4).map { item(CGFloat($0) * 11, CGFloat($0) * 17, 280, 240) }

        let result = BoardLayout.organize(items, connections: lines, aspect: 16 / 10)

        #expect(result.count == items.count)
        #expect(noOverlaps(Array(result.values)))
        let union = result.values.reduce(result.values.first!) { $0.union($1) }
        #expect(union.origin == CGPoint(x: 0, y: 0))
        // Rows, not one long line: about the shape of the screen.
        #expect(union.width / union.height < 4)
    }

    @Test func organizingTwiceChangesNothing() {
        let agent = item(0, 0, 640, 420, hub: true)
        let runner = item(900, 900, 500, 260)
        let lone = item(-400, 2000, 280, 240)
        let items = [agent, runner, lone]
        let lines = [Connection(a: agent.id, b: runner.id)]
        let first = BoardLayout.organize(items, connections: lines)
        let again = BoardLayout.organize(items.map { BoardLayout.Item(id: $0.id, frame: first[$0.id]!, isHub: $0.isHub) }, connections: lines)
        #expect(first == again)
    }

    @Test func aCardAnAgentAddsGoesBelowItsPeersInTheColumnRightOfIt() {
        let agent = item(0, 0, 640, 420, hub: true)
        let runner = item(640 + BoardLayout.columnGap, 0, 500, 260)
        let lines = [Connection(a: agent.id, b: runner.id)]

        let slot = BoardLayout.slot(for: CGSize(width: 280, height: 240), parent: agent.id, among: [agent, runner], connections: lines)

        #expect(slot == CGPoint(x: runner.frame.minX, y: runner.frame.maxY + BoardLayout.rowGap))
    }

    @Test func aCardTheUserAddsTakesTheNextFreeSpotInTheRows() {
        let agent = item(0, 0, 640, 420, hub: true)
        let runner = item(640 + BoardLayout.columnGap, 0, 500, 260)
        let items = [agent, runner]
        let lines = [Connection(a: agent.id, b: runner.id)]
        let size = CGSize(width: 280, height: 240)

        let slot = BoardLayout.slot(for: size, among: items, connections: lines, aspect: 16 / 10)!

        // Where organizing would put a group of its own: below this wide one keeps the rows
        // about the screen's shape, beside it would make one long strip.
        #expect(slot == CGPoint(x: 0, y: agent.frame.maxY + BoardLayout.groupGap))
        let all = items.map(\.frame) + [CGRect(origin: slot, size: size)]
        #expect(noOverlaps(all))
    }

    @Test func aCardTheUserAddsFillsTheRoomBesideATallGroup() {
        let agent = item(0, 0, 640, 420, hub: true)
        let runners = (0..<4).map { item(704, CGFloat($0) * 292, 500, 260) }
        let lines = runners.map { Connection(a: agent.id, b: $0.id) }
        let size = CGSize(width: 280, height: 240)

        let slot = BoardLayout.slot(for: size, among: [agent] + runners, connections: lines, aspect: 16 / 10)!

        #expect(slot == CGPoint(x: 1204 + BoardLayout.groupGap, y: 0))
    }

    @Test func anEmptyCanvasLeavesTheSpotToTheCaller() {
        #expect(BoardLayout.slot(for: CGSize(width: 100, height: 100), among: [], connections: []) == nil)
        #expect(BoardLayout.organize([], connections: []).isEmpty)
    }
}
