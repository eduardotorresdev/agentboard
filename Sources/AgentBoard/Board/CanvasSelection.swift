import CoreGraphics
import Foundation

/// The pure rules of picking several cards on the canvas: the box, toggling one, moving them together.
enum CanvasSelection {
    /// The cards the box touches, added to `base`.
    static func hits(_ frames: [(id: UUID, frame: CGRect)], in box: CGRect, adding base: Set<UUID> = []) -> Set<UUID> {
        base.union(frames.filter { $0.frame.intersects(box) }.map(\.id))
    }

    /// A card's frame grown down to cover what shows just below it (an agent's composer), `extra` world points.
    static func extended(_ frame: CGRect, below extra: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + extra)
    }

    /// Shift- or Command-clicking a card adds it, or takes it out if it was in.
    static func toggling(_ id: UUID, in selection: Set<UUID>) -> Set<UUID> {
        selection.symmetricDifference([id])
    }

    /// Every frame moved by the same offset from where it started, so the group keeps its shape.
    static func moved(_ start: [UUID: CGRect], by offset: CGSize) -> [UUID: CGRect] {
        start.mapValues { $0.offsetBy(dx: offset.width, dy: offset.height).integral }
    }
}
