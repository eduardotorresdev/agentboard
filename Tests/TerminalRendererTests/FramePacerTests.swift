import Testing
import TerminalRenderer

struct FramePacerTests {
    @Test func focusedDrawsEveryFrameAndBackgroundWaitsForItsBeat() {
        var pacer = FramePacer<Int>(backgroundInterval: 0.1, rideAlong: 1)
        pacer.focused = 0
        #expect(Set(pacer.select([0, 1], at: 1.0).draw) == [0, 1])
        let next = pacer.select([0, 1], at: 1.03)
        #expect(next.draw == [0])
        #expect(next.wait == [1])
        #expect(Set(pacer.select([0, 1], at: 1.09).draw) == [0, 1])
    }

    @Test func backgroundRidesAlongOnAFocusedFrame() {
        var pacer = FramePacer<Int>(backgroundInterval: 0.1, rideAlong: 0.4)
        pacer.focused = 0
        _ = pacer.select([1], at: 1.0)
        // Too early even to ride along.
        #expect(pacer.select([0, 1], at: 1.03).wait == [1])
        // Halfway through its interval: drawn with the focused card instead of on its own later.
        #expect(Set(pacer.select([0, 1], at: 1.05).draw) == [0, 1])
        // Without a focused draw it waits for the beat.
        #expect(pacer.select([1], at: 1.1).wait == [1])
    }

    @Test func paceFollowsTheUser() {
        var pacer = FramePacer<Int>()
        pacer.focused = 0
        #expect(pacer.pace(at: 0) == .background)
        _ = pacer.select([0], at: 1)
        #expect(pacer.pace(at: 1.2) == .focused(crowded: false))
        pacer.interacted(at: 1.3)
        #expect(pacer.pace(at: 1.4) == .interactive)
        #expect(pacer.pace(at: 2.0) == .background)
    }

    @Test func focusedDropsTo30HzWhenMoreThanThreeTerminalsPrint() {
        var pacer = FramePacer<Int>()
        pacer.focused = 0
        _ = pacer.select([0, 1, 2], at: 1)
        #expect(pacer.pace(at: 1.1) == .focused(crowded: false))
        #expect(pacer.pace(at: 1.1).frameRate.preferred == 60)
        _ = pacer.select([0, 3, 4], at: 1.2)
        #expect(pacer.printing(at: 1.3) == 5)
        #expect(pacer.pace(at: 1.3) == .focused(crowded: true))
        #expect(pacer.pace(at: 1.3).frameRate.preferred == 30)
        // The others went quiet a second ago: back to 60 Hz.
        _ = pacer.select([0], at: 2.15)
        #expect(pacer.pace(at: 2.25) == .focused(crowded: false))
    }
}
