import CoreGraphics
import Foundation

/// The pointer and keyboard logic of the organization switcher, free of SwiftUI so it can be
/// tested. The view feeds it what happens (press, move, hold timeout, release, cancel, escape)
/// and carries out the effect it returns. Organizations are named by id, never by position.
struct OrganizationSwitchGesture: Equatable {
    /// One organization's name in the track, in track coordinates.
    struct Segment: Equatable {
        let id: UUID
        let minX: CGFloat
        let maxX: CGFloat
        var width: CGFloat { maxX - minX }
    }

    enum Phase: Equatable {
        case idle
        /// Down on `id`, not moved yet. `press` tells a hold timeout apart from an older press's.
        case pressed(id: UUID, startX: CGFloat, press: Int)
        case dragging
        /// Held still long enough: the editor is open, so this gesture can no longer switch.
        case holding
        /// Cancelled (escape, or the system took the gesture); ignored until the pointer lifts.
        case cancelled
    }

    enum Effect: Equatable {
        case none
        /// Thumb edges while dragging; `over` is the name under the pointer, to scroll into view.
        case follow(minX: CGFloat, maxX: CGFloat, over: UUID)
        /// Thumb back onto the current organization.
        case snap
        case select(UUID)
        case openEditor(UUID)
    }

    /// Movement under this many points is still a press, not a drag.
    static let dragThreshold: CGFloat = 3

    private(set) var phase: Phase = .idle
    private var presses = 0

    var isActive: Bool { phase != .idle }

    /// The pointer went down. Returns the press number the hold timer must hand back.
    mutating func press(at x: CGFloat, in segments: [Segment]) -> Int? {
        guard phase == .idle, let id = Self.nearest(to: x, in: segments) else { return nil }
        presses += 1
        phase = .pressed(id: id, startX: x, press: presses)
        return presses
    }

    mutating func move(to x: CGFloat, in segments: [Segment]) -> Effect {
        switch phase {
        case let .pressed(_, startX, _) where abs(x - startX) > Self.dragThreshold:
            phase = .dragging
            return Self.follow(x, in: segments)
        case .dragging:
            return Self.follow(x, in: segments)
        default:
            return .none
        }
    }

    /// The hold timer of press number `press` fired.
    mutating func holdTimeout(press: Int) -> Effect {
        guard case let .pressed(id, _, current) = phase, current == press else { return .none }
        phase = .holding
        return .openEditor(id)
    }

    /// The pointer lifted at `x`. Only a click or a drag switches, and only to another organization.
    mutating func release(at x: CGFloat, in segments: [Segment], current: UUID) -> Effect {
        defer { phase = .idle }
        switch phase {
        case let .pressed(id, _, _):
            return id == current ? .none : .select(id)
        case .dragging:
            guard let id = Self.nearest(to: x, in: segments), id != current else { return .snap }
            return .select(id)
        default:
            return .none
        }
    }

    /// Escape, or the system cancelled the gesture: nothing switches and the thumb goes home.
    mutating func cancel() -> Effect {
        let wasDragging = phase == .dragging
        if phase != .idle { phase = .cancelled }
        return wasDragging ? .snap : .none
    }

    /// The gesture is over without a release (its state was reset): cancel and start fresh.
    mutating func end() -> Effect {
        let effect = cancel()
        phase = .idle
        return effect
    }

    /// The organization `offset` places from `current`, or nil at either end.
    static func step(from current: UUID, by offset: Int, in ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: current), ids.indices.contains(index + offset) else { return nil }
        return ids[index + offset]
    }

    /// The segment under `x`, or the one whose edge is closest to it.
    static func nearest(to x: CGFloat, in segments: [Segment]) -> UUID? {
        func distance(_ segment: Segment) -> CGFloat { max(segment.minX - x, x - segment.maxX, 0) }
        return segments.min { distance($0) < distance($1) }?.id
    }

    /// The thumb centered on `x`, as wide as the name under it, kept inside the track.
    static func follow(_ x: CGFloat, in segments: [Segment]) -> Effect {
        guard let id = nearest(to: x, in: segments), let segment = segments.first(where: { $0.id == id }),
              let first = segments.first, let last = segments.last else { return .none }
        let half = segment.width / 2
        let center = min(max(x, first.minX + half), last.maxX - half)
        return .follow(minX: center - half, maxX: center + half, over: id)
    }
}
