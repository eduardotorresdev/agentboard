import CoreGraphics
import Testing
@testable import AgentBoard

/// Where a sidebar item dragged by the pointer lands.
@Suite struct ReorderDragTests {
    /// a, a tall (expanded) b, c and d; the list starts at y 0.
    let keys = ["a", "b", "c", "d"]
    let heights: [String: CGFloat] = ["a": 34, "b": 200, "c": 34, "d": 34]

    private func drag(_ key: String, to y: CGFloat) -> Int {
        let top: CGFloat = keys.prefix { $0 != key }.reduce(0) { $0 + heights[$1]! }
        var drag = ReorderDrag(key: key, keys: keys, frame: CGRect(x: 0, y: top, width: 240, height: heights[key]!), heights: heights)
        drag.move(pointer: y)
        return drag.target
    }

    @Test func itStaysInItsOwnPlaceUntilANeighborIsCrossed() {
        // c spans 234...268.
        #expect(drag("c", to: 234) == 2)
        #expect(drag("c", to: 268) == 2)
    }

    @Test func goingUpItPassesANeighborOnceThePointerIsOverItsMiddle() {
        // Into the tall b from below: half of c's height is enough (b's bottom is 234).
        #expect(drag("c", to: 218) == 2)
        #expect(drag("c", to: 216) == 1)
        // Over a's middle (17).
        #expect(drag("c", to: 18) == 1)
        #expect(drag("c", to: 16) == 0)
    }

    @Test func goingDownItPassesANeighborOnceThePointerIsUnderItsMiddle() {
        // b is laid out at 34...234 before it moves: 17 into it passes it, not its whole height.
        #expect(drag("a", to: 50) == 0)
        #expect(drag("a", to: 52) == 1)
        // Then c (234...268 before it moves): past its middle, 251.
        #expect(drag("a", to: 250) == 1)
        #expect(drag("a", to: 252) == 2)
        // Beyond the list: the end.
        #expect(drag("a", to: 900) == 3)
        #expect(drag("d", to: -50) == 0)
    }

    @Test func theNewOrderPutsItWhereItLands() {
        var drag = ReorderDrag(key: "a", keys: keys, frame: CGRect(x: 0, y: 0, width: 240, height: 34), heights: heights)
        drag.move(pointer: 252)
        #expect(drag.order == ["b", "c", "a", "d"])
        // Its own place stays open; the new one opens before d.
        #expect(drag.slot(before: "a") == 0)
        #expect(drag.slot(before: "d") == 34)
    }
}
