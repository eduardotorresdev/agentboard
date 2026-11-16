import CoreGraphics
import Foundation
import Testing
@testable import AgentBoard

struct OrganizationSwitchGestureTests {
    typealias Gesture = OrganizationSwitchGesture
    let a = UUID(), b = UUID(), c = UUID()
    /// A narrow, a wide and a medium name.
    var segments: [Gesture.Segment] {
        [.init(id: a, minX: 0, maxX: 60), .init(id: b, minX: 60, maxX: 200), .init(id: c, minX: 200, maxX: 280)]
    }

    // MARK: Snapping

    @Test func nearestIsTheNameUnderThePointerOrTheClosestEdge() {
        #expect(Gesture.nearest(to: 10, in: segments) == a)
        #expect(Gesture.nearest(to: 75, in: segments) == b) // just inside a wide name, not its narrow neighbor
        #expect(Gesture.nearest(to: 230, in: segments) == c)
        #expect(Gesture.nearest(to: -500, in: segments) == a)
        #expect(Gesture.nearest(to: 900, in: segments) == c)
        #expect(Gesture.nearest(to: 10, in: []) == nil)
    }

    // MARK: Click

    @Test func clickOnAnotherNameSelectsItOnRelease() {
        var gesture = Gesture()
        _ = gesture.press(at: 230, in: segments)
        #expect(gesture.move(to: 231, in: segments) == .none) // under the threshold: still a click
        #expect(gesture.release(at: 231, in: segments, current: a) == .select(c))
        #expect(gesture.phase == .idle)
    }

    @Test func clickOnTheCurrentNameDoesNothing() {
        var gesture = Gesture()
        _ = gesture.press(at: 10, in: segments)
        #expect(gesture.release(at: 10, in: segments, current: a) == .none)
    }

    // MARK: Drag

    @Test func dragFollowsWithoutSelectingAndSelectsOnlyOnRelease() {
        var gesture = Gesture()
        _ = gesture.press(at: 10, in: segments)
        // Passes over b on the way to c: follow effects only, never a select.
        for x in stride(from: CGFloat(20), through: 240, by: 20) {
            guard case let .follow(_, _, over) = gesture.move(to: x, in: segments) else {
                Issue.record("expected follow at \(x)"); return
            }
            #expect(over == Gesture.nearest(to: x, in: segments))
        }
        #expect(gesture.release(at: 240, in: segments, current: a) == .select(c))
    }

    @Test func dragBackOntoTheCurrentNameSnapsWithoutSelecting() {
        var gesture = Gesture()
        _ = gesture.press(at: 10, in: segments)
        _ = gesture.move(to: 120, in: segments)
        _ = gesture.move(to: 15, in: segments)
        #expect(gesture.release(at: 15, in: segments, current: a) == .snap)
    }

    @Test func followKeepsTheThumbInsideTheTrackAndAsWideAsTheNameUnderIt() {
        #expect(Gesture.follow(-100, in: segments) == .follow(minX: 0, maxX: 60, over: a))
        #expect(Gesture.follow(1000, in: segments) == .follow(minX: 200, maxX: 280, over: c))
        #expect(Gesture.follow(130, in: segments) == .follow(minX: 60, maxX: 200, over: b))
        #expect(Gesture.follow(10, in: []) == .none)
    }

    // MARK: Hold

    @Test func holdOpensTheEditorAndNothingAfterItSwitches() {
        var gesture = Gesture()
        let press = gesture.press(at: 230, in: segments)!
        #expect(gesture.holdTimeout(press: press) == .openEditor(c))
        // Jitter, or dragging on with the editor open, must not switch.
        #expect(gesture.move(to: 231, in: segments) == .none)
        #expect(gesture.move(to: 20, in: segments) == .none)
        #expect(gesture.release(at: 20, in: segments, current: a) == .none)
    }

    @Test func holdTimeoutAfterADragOrFromAnOldPressIsIgnored() {
        var gesture = Gesture()
        let first = gesture.press(at: 10, in: segments)!
        _ = gesture.move(to: 100, in: segments)
        #expect(gesture.holdTimeout(press: first) == .none)
        _ = gesture.release(at: 100, in: segments, current: a)
        let second = gesture.press(at: 230, in: segments)!
        #expect(gesture.holdTimeout(press: first) == .none)
        #expect(gesture.holdTimeout(press: second) == .openEditor(c))
    }

    // MARK: Cancel

    @Test func escapeDuringADragSnapsBackAndTheReleaseDoesNothing() {
        var gesture = Gesture()
        _ = gesture.press(at: 10, in: segments)
        _ = gesture.move(to: 240, in: segments)
        #expect(gesture.cancel() == .snap)
        #expect(gesture.move(to: 250, in: segments) == .none)
        #expect(gesture.release(at: 250, in: segments, current: a) == .none)
        #expect(gesture.phase == .idle)
    }

    @Test func cancelledPressCannotOpenTheEditorOrSwitch() {
        var gesture = Gesture()
        let press = gesture.press(at: 230, in: segments)!
        #expect(gesture.cancel() == .none)
        #expect(gesture.holdTimeout(press: press) == .none)
        #expect(gesture.release(at: 230, in: segments, current: a) == .none)
    }

    @Test func gestureEndingWithoutReleaseResetsSoTheNextPressWorks() {
        var gesture = Gesture()
        _ = gesture.press(at: 10, in: segments)
        _ = gesture.move(to: 240, in: segments)
        #expect(gesture.end() == .snap)
        #expect(gesture.phase == .idle)
        #expect(gesture.press(at: 230, in: segments) != nil)
        #expect(gesture.release(at: 230, in: segments, current: a) == .select(c))
    }

    // MARK: Keyboard and removal

    @Test func keyboardStepsByIdAndStopsAtTheEnds() {
        let ids = [a, b, c]
        #expect(Gesture.step(from: a, by: 1, in: ids) == b)
        #expect(Gesture.step(from: c, by: -1, in: ids) == b)
        #expect(Gesture.step(from: a, by: -1, in: ids) == nil)
        #expect(Gesture.step(from: c, by: 1, in: ids) == nil)
        #expect(Gesture.step(from: UUID(), by: 1, in: ids) == nil)
    }

    @Test func removedOrganizationIsNeverTheTarget() {
        // b removed: the track closes up and a release where b was lands on a real name.
        let remaining: [Gesture.Segment] = [.init(id: a, minX: 0, maxX: 60), .init(id: c, minX: 60, maxX: 140)]
        var gesture = Gesture()
        _ = gesture.press(at: 10, in: remaining)
        _ = gesture.move(to: 130, in: remaining)
        #expect(gesture.release(at: 130, in: remaining, current: a) == .select(c))
        #expect(Gesture.step(from: a, by: 1, in: remaining.map(\.id)) == c)
    }
}
