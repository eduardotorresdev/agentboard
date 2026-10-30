import AppKit
import QuartzCore

/// A file tree card's chrome: background, title and close button, and its connection handles.
/// The files themselves are a SwiftUI view the board places over `CardMetrics.content`.
final class FileTreeCardLayer: CALayer {
    private let icon = CATextLayer()
    private let title = CATextLayer()
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override init() {
        super.init()
        backgroundColor = BoardPalette.card
        cornerRadius = CardMetrics.radius
        shadowColor = BoardPalette.rgb(BoardPalette.ink)
        closeHover.cornerRadius = CardMetrics.closeSize / 2
        closeHover.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.08)
        for layer in [icon, title, closeGlyph] {
            layer.fontSize = 12
            layer.truncationMode = .end
        }
        title.font = Self.titleFont
        icon.string = "▤"
        icon.foregroundColor = BoardPalette.rgb(BoardPalette.accent)
        closeGlyph.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeGlyph.string = "✕"
        closeGlyph.alignmentMode = .center
        [icon, title, closeHover, closeGlyph].forEach(addSublayer)
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
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: CardMetrics.radius, cornerHeight: CardMetrics.radius, transform: nil)
        shadowOpacity = focused ? 0.16 : 0.08
        shadowRadius = focused ? 14 : 8
        shadowOffset = CGSize(width: 0, height: focused ? 12 : 5)
        for layer in [icon, title, closeGlyph] { layer.contentsScale = scale }
        let ink = BoardPalette.ink
        let line = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading) + 2
        let mid = CardMetrics.titleHeight / 2
        let close = CardMetrics.close(of: bounds)
        icon.frame = CGRect(x: CardMetrics.inset + 2, y: mid - line / 2, width: 14, height: line)
        title.string = name
        title.foregroundColor = BoardPalette.rgb(ink, focused ? 0.9 : 0.6)
        title.frame = CGRect(x: icon.frame.maxX + 6, y: mid - line / 2, width: max(0, close.minX - icon.frame.maxX - 14), height: line)
        closeHover.frame = close
        closeHover.isHidden = !closeHovered
        closeGlyph.foregroundColor = BoardPalette.rgb(ink, closeHovered ? 0.8 : 0.4)
        closeGlyph.frame = CGRect(x: close.minX, y: close.midY - line / 2, width: close.width, height: line)
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
        if linkTarget {
            shadowColor = BoardPalette.rgb(BoardPalette.accent)
            shadowOpacity = 0.45
            shadowRadius = 18
            shadowOffset = .zero
        } else {
            shadowColor = BoardPalette.rgb(BoardPalette.ink)
        }
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
