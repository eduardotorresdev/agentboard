import CoreGraphics
import Foundation
import Testing
@testable import AgentBoard

struct CanvasSelectionTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func boxSelectsTouchedCardsAndKeepsTheBase() {
        let frames = [(id: a, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                      (id: b, frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
                      (id: c, frame: CGRect(x: 0, y: 500, width: 100, height: 100))]
        #expect(CanvasSelection.hits(frames, in: CGRect(x: 90, y: 50, width: 120, height: 10)) == [a, b])
        #expect(CanvasSelection.hits(frames, in: CGRect(x: 150, y: 300, width: 10, height: 10), adding: [c]) == [c])
    }

    @Test func toggleAddsThenRemoves() {
        let once = CanvasSelection.toggling(a, in: [b])
        #expect(once == [a, b])
        #expect(CanvasSelection.toggling(a, in: once) == [b])
    }

    @Test func groupMoveKeepsRelativeOffsets() {
        let start = [a: CGRect(x: 0, y: 0, width: 10, height: 10), b: CGRect(x: 30, y: -20, width: 5, height: 5)]
        let moved = CanvasSelection.moved(start, by: CGSize(width: 12, height: 7))
        #expect(moved[a]?.origin == CGPoint(x: 12, y: 7))
        #expect(moved[b]?.origin == CGPoint(x: 42, y: -13))
        #expect(moved[b]?.size == CGSize(width: 5, height: 5))
    }

    @Test func composerBelowAnAgentCountsForTheBox() {
        let card = CGRect(x: 0, y: 0, width: 100, height: 100)
        let box = CGRect(x: 10, y: 120, width: 10, height: 10)
        #expect(CanvasSelection.hits([(id: a, frame: card)], in: box).isEmpty)
        #expect(CanvasSelection.hits([(id: a, frame: CanvasSelection.extended(card, below: 42))], in: box) == [a])
    }
}
