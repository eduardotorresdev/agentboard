import AppKit
import Orchestration
import QuartzCore

/// What the pointer can act on in a post-it.
enum PostItControl: Equatable {
    case close
    /// The text area.
    case text
}

/// Where everything in a post-it sits, in the card's own coordinates: shared by the layer that
/// draws it and the board that hit-tests it.
struct PostItCardLayout {
    let title: CGRect
    let close: CGRect
    /// Where the text shows; it scrolls inside.
    let content: CGRect

    static let titleFont = CardFrame.titleFont
    static let placeholderFont = NSFont.systemFont(ofSize: Theme.Font.labelSize)

    init(size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let mid = CardMetrics.titleHeight / 2
        close = CardMetrics.close(of: bounds)
        title = CGRect(x: CardFrame.titleX, y: mid - 10, width: max(0, close.minX - CardFrame.titleX - 8), height: 20)
        content = CGRect(x: CardMetrics.inset + 4, y: CardMetrics.titleHeight + 4,
                         width: max(0, size.width - CardMetrics.inset * 2 - 8),
                         height: max(0, size.height - CardMetrics.titleHeight - CardMetrics.inset - 8))
    }

    func control(at point: CGPoint, zoom: CGFloat = 1) -> PostItControl? {
        if close.target(zoom: zoom).contains(point) { return .close }
        if content.contains(point) { return .text }
        return nil
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

/// One post-it: chrome as Core Animation layers like the other cards, and the text drawn into
/// one layer that is redrawn only when what it shows changes.
final class PostItCardLayer: CALayer {
    private let bar = CardTitleBar()
    private var focused = false
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let text = PostItTextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?

    override init() {
        super.init()
        text.masksToBounds = true
        text.needsDisplayOnBoundsChange = true
        [bar, closeHover, closeGlyph, text].forEach(addSublayer)
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

    /// The text's whole height, as last laid out.
    var contentHeight: CGFloat { text.contentHeight }

    /// The link under a point in the card's coordinates.
    func link(at point: CGPoint, layout: PostItCardLayout, scroll: CGFloat) -> URL? {
        text.link(at: CGPoint(x: point.x - layout.content.minX, y: point.y - layout.content.minY + scroll))
    }

    /// `editing`: a text view covers the text, so the layer leaves it blank.
    func update(frame: CGRect, record: PostItRecord, layout: PostItCardLayout, scroll: CGFloat, focused: Bool,
                hovered: PostItControl?, editing: Bool, scale: CGFloat) {
        self.frame = frame
        self.focused = focused
        CardFrame.style(self, focused: focused)

        bar.update(size: bounds.size, icon: .symbol("note.text", color: Theme.Hex.inkMuted), status: nil, title: record.name, detail: nil, focused: focused,
                   reserve: bounds.width - layout.title.maxX, fill: BoardPalette.rgb(BoardPalette.postIt), scale: scale)
        CardFrame.closeButton(closeHover, closeGlyph, in: layout.close, hovered: hovered == .close, scale: scale)

        text.frame = layout.content
        text.contentsScale = scale
        text.show(PostItTextLayer.Model(text: record.text, width: layout.content.width,
                                        scroll: scroll, hidden: editing))
    }

    func updateHandles(visible: Bool, hovered: Int?, linkTarget: Bool) {
        for (handle, point) in zip(handles, CardMetrics.handles(of: bounds)) { handle.position = point }
        if visible != handlesVisible {
            handlesVisible = visible
            for handle in handles {
                handle.isHidden = !visible
                if visible { handle.add(Self.spring("opacity", from: 0, to: 1, stiffness: 300, damping: 26), forKey: "appear") }
            }
        }
        if hovered != hoveredHandle {
            for (index, handle) in handles.enumerated() where index == hovered || index == hoveredHandle {
                let grow = index == hovered
                let scale: CGFloat = grow ? 1.4 : 1
                handle.add(Self.spring("transform.scale", from: handle.presentation()?.value(forKeyPath: "transform.scale") ?? (grow ? 1 : 1.4),
                                       to: scale, stiffness: 400, damping: 22), forKey: "scale")
                handle.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            hoveredHandle = hovered
        }
        // A line's target lights up with the highlighted ring, like focus.
        CardFrame.style(self, focused: focused || linkTarget)
        CardFrame.reveal([closeGlyph], visible: visible || focused)
    }

    func animateAppearance() {
        add(Self.spring("opacity", from: 0, to: 1, stiffness: 240, damping: 24), forKey: "appear-fade")
        add(Self.spring("transform.translation.y", from: 14, to: 0, stiffness: 240, damping: 24), forKey: "appear-rise")
    }

    private static func spring(_ keyPath: String, from: Any?, to: Any, stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        return spring
    }
}

/// The post-it's text, drawn into the layer's contents; laid out again only when the text, its
/// form or the width changes.
private final class PostItTextLayer: CALayer {
    struct Model: Equatable {
        let text: String
        let width: CGFloat
        let scroll: CGFloat
        let hidden: Bool
    }

    private var model: Model?
    private var laidOut: PostItText?
    private var drawnScale: CGFloat = 0

    var contentHeight: CGFloat { laidOut?.height ?? 0 }

    func show(_ model: Model) {
        guard model != self.model || drawnScale != contentsScale else { return }
        if laidOut == nil || model.text != self.model?.text || model.width != self.model?.width {
            laidOut = PostItText(model.text, width: model.width)
        }
        self.model = model
        drawnScale = contentsScale
        setNeedsDisplay()
    }

    func link(at point: CGPoint) -> URL? {
        laidOut?.link(at: point)
    }

    override func draw(in ctx: CGContext) {
        guard let model, let laidOut, !model.hidden else { return }
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let empty = L("Empty. Double-click to write.") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PostItCardLayout.placeholderFont, .foregroundColor: NSColor(cgColor: BoardPalette.rgb(Theme.Hex.inkMuted, 1)) ?? .gray,
            ]
            let size = empty.size(withAttributes: attributes)
            empty.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }
        laidOut.draw(at: CGPoint(x: 0, y: -model.scroll), visible: bounds)
    }
}
