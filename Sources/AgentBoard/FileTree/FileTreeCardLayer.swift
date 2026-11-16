import AppKit
import QuartzCore

/// A file tree card's chrome: background, title and close button, and its connection handles.
/// The files themselves are a SwiftUI view the board places over `CardMetrics.content`.
final class FileTreeCardLayer: CALayer {
    private let bar = CardTitleBar()
    private var focused = false
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?

    override init() {
        super.init()
        [bar, closeHover, closeGlyph].forEach(addSublayer)
        CardFrame.reveal([closeGlyph], visible: false)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: CardMetrics.handleSize, height: CardMetrics.handleSize)
            handle.cornerRadius = CardMetrics.handleSize / 2
            handle.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
            handle.borderColor = BoardPalette.card
            handle.borderWidth = 2
            handle.isHidden = true
            handle.zPosition = 10
            addSublayer(handle)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(frame: CGRect, name: String, focused: Bool, closeHovered: Bool, scale: CGFloat) {
        self.frame = frame
        self.focused = focused
        CardFrame.style(self, focused: focused)
        let close = CardMetrics.close(of: bounds)
        bar.update(size: bounds.size, icon: .symbol("folder", color: Theme.Hex.inkMuted), status: nil, title: name, detail: nil, focused: focused,
                   reserve: bounds.width - close.minX + 8, scale: scale)
        CardFrame.closeButton(closeHover, closeGlyph, in: close, hovered: closeHovered, scale: scale)
    }

    func updateHandles(visible: Bool, hovered: Int?, linkTarget: Bool) {
        for (handle, point) in zip(handles, CardMetrics.handles(of: bounds)) { handle.position = point }
        if visible != handlesVisible {
            handlesVisible = visible
            for handle in handles {
                handle.isHidden = !visible
                if visible { handle.add(Self.spring("opacity", from: 0, to: 1), forKey: "appear") }
            }
        }
        if hovered != hoveredHandle {
            for (index, handle) in handles.enumerated() {
                let scale: CGFloat = index == hovered ? 1.4 : 1
                handle.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            hoveredHandle = hovered
        }
        // A line's target lights up with the highlighted ring, like focus.
        CardFrame.style(self, focused: focused || linkTarget)
        CardFrame.reveal([closeGlyph], visible: visible || focused)
    }

    func animateAppearance() {
        add(Self.spring("opacity", from: 0, to: 1), forKey: "appear-fade")
        add(Self.spring("transform.translation.y", from: 14, to: 0), forKey: "appear-rise")
    }

    private static func spring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.stiffness = 260
        spring.damping = 24
        spring.duration = spring.settlingDuration
        return spring
    }
}
