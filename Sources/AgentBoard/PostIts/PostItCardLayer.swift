import AppKit
import Orchestration
import QuartzCore

/// How a post-it shows its text: rendered markdown, or the markdown itself, written in place.
enum PostItMode: Equatable {
    case view
    case code
}

/// What the pointer can act on in a post-it.
enum PostItControl: Equatable {
    case close
    case mode(PostItMode)
    /// The text area.
    case text
}

/// Where everything in a post-it sits, in the card's own coordinates: shared by the layer that
/// draws it and the board that hit-tests it.
struct PostItCardLayout {
    let title: CGRect
    let close: CGRect
    /// The View | Code switch, and each of its halves.
    let modes: CGRect
    let view: CGRect
    let code: CGRect
    /// Where the text shows; it scrolls inside.
    let content: CGRect

    static let titleFont = CardFrame.titleFont
    static let modeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let placeholderFont = NSFont.systemFont(ofSize: 12)

    init(size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let mid = CardMetrics.titleHeight / 2
        close = CardMetrics.close(of: bounds)
        let labels = [L("View"), L("Code")].map { ceil(($0 as NSString).size(withAttributes: [.font: Self.modeFont]).width) + 16 }
        let height: CGFloat = 22
        let modesWidth = labels.reduce(0, +) + 4
        modes = CGRect(x: close.minX - 8 - modesWidth, y: mid - height / 2, width: modesWidth, height: height)
        view = CGRect(x: modes.minX + 2, y: modes.minY + 2, width: labels[0], height: height - 4)
        code = CGRect(x: view.maxX, y: view.minY, width: labels[1], height: height - 4)
        title = CGRect(x: CardFrame.titleX, y: mid - 10, width: max(0, modes.minX - CardFrame.titleX - 8), height: 20)
        content = CGRect(x: CardMetrics.inset + 4, y: CardMetrics.titleHeight + 4,
                         width: max(0, size.width - CardMetrics.inset * 2 - 8),
                         height: max(0, size.height - CardMetrics.titleHeight - CardMetrics.inset - 8))
    }

    func control(at point: CGPoint) -> PostItControl? {
        if close.contains(point) { return .close }
        if view.contains(point) { return .mode(.view) }
        if code.contains(point) { return .mode(.code) }
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
    private let modes = CALayer()
    private let selectedMode = CALayer()
    private let viewLabel = CATextLayer()
    private let codeLabel = CATextLayer()
    private let text = PostItTextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?
    private var shownMode: PostItMode?

    override init() {
        super.init()
        for layer in [viewLabel, codeLabel] { layer.truncationMode = .end }
        for (label, string) in [(viewLabel, L("View")), (codeLabel, L("Code"))] {
            label.font = PostItCardLayout.modeFont
            label.fontSize = PostItCardLayout.modeFont.pointSize
            label.string = string
            label.alignmentMode = .center
        }
        modes.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.07)
        selectedMode.backgroundColor = BoardPalette.card
        text.masksToBounds = true
        text.needsDisplayOnBoundsChange = true
        [bar, closeHover, closeGlyph, modes, selectedMode, viewLabel, codeLabel, text].forEach(addSublayer)
        CardFrame.reveal([closeGlyph], visible: false)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: CardMetrics.handleSize, height: CardMetrics.handleSize)
            handle.cornerRadius = CardMetrics.handleSize / 2
            handle.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
            handle.borderColor = BoardPalette.card
            handle.borderWidth = 2
            handle.shadowColor = BoardPalette.rgb(BoardPalette.ink)
            handle.shadowOpacity = 0.18
            handle.shadowRadius = 3
            handle.shadowOffset = CGSize(width: 0, height: 1)
            handle.isHidden = true
            handle.zPosition = 10
            addSublayer(handle)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text's whole height, as last laid out.
    var contentHeight: CGFloat { text.contentHeight }

    /// The link under a point in the card's coordinates, while the markdown shows rendered.
    func link(at point: CGPoint, layout: PostItCardLayout, scroll: CGFloat) -> URL? {
        text.link(at: CGPoint(x: point.x - layout.content.minX, y: point.y - layout.content.minY + scroll))
    }

    /// `editing`: a text view covers the text, so the layer leaves it blank.
    func update(frame: CGRect, record: PostItRecord, layout: PostItCardLayout, mode: PostItMode, scroll: CGFloat, focused: Bool,
                hovered: PostItControl?, editing: Bool, scale: CGFloat) {
        self.frame = frame
        self.focused = focused
        CardFrame.style(self, focused: focused)
        for layer in [viewLabel, codeLabel] { layer.contentsScale = scale }

        let ink = BoardPalette.ink
        bar.update(size: bounds.size, icon: .symbol("note.text", color: Theme.Hex.inkMuted), status: nil, title: record.name, detail: nil, focused: focused,
                   reserve: bounds.width - layout.title.maxX, fill: BoardPalette.rgb(BoardPalette.postIt), scale: scale)
        CardFrame.closeButton(closeHover, closeGlyph, in: layout.close, hovered: hovered == .close, scale: scale)

        modes.frame = layout.modes
        modes.cornerRadius = Theme.Radius.control
        let selected = mode == .view ? layout.view : layout.code
        // The selected half slides under its label.
        if shownMode != nil, shownMode != mode {
            let slide = CASpringAnimation(keyPath: "position")
            slide.fromValue = selectedMode.presentation()?.position ?? selectedMode.position
            slide.toValue = CGPoint(x: selected.midX, y: selected.midY)
            slide.stiffness = 420
            slide.damping = 30
            slide.duration = slide.settlingDuration
            selectedMode.add(slide, forKey: "slide")
        }
        shownMode = mode
        selectedMode.frame = selected
        selectedMode.cornerRadius = Theme.Radius.control - 1
        let modeLine = PostItCardLayout.lineHeight(PostItCardLayout.modeFont) + 1
        for (label, rect, kind) in [(viewLabel, layout.view, PostItMode.view), (codeLabel, layout.code, .code)] {
            label.frame = CGRect(x: rect.minX, y: rect.midY - modeLine / 2, width: rect.width, height: modeLine)
            label.foregroundColor = BoardPalette.rgb(ink, mode == kind ? 0.95 : hovered == .mode(kind) ? 0.75 : 0.55)
        }

        text.frame = layout.content
        text.contentsScale = scale
        text.show(PostItTextLayer.Model(text: record.text, form: mode == .view ? .rendered : .source, width: layout.content.width,
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
        let form: PostItText.Form
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
        if laidOut == nil || model.text != self.model?.text || model.form != self.model?.form || model.width != self.model?.width {
            laidOut = PostItText(model.text, form: model.form, width: model.width)
        }
        self.model = model
        drawnScale = contentsScale
        setNeedsDisplay()
    }

    func link(at point: CGPoint) -> URL? {
        guard model?.form == .rendered else { return nil }
        return laidOut?.link(at: point)
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
            let empty = (model.form == .rendered ? L("Empty. Double-click to write.") : L("Write in markdown…")) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PostItCardLayout.placeholderFont, .foregroundColor: NSColor(cgColor: BoardPalette.rgb(BoardPalette.ink, 0.4)) ?? .gray,
            ]
            if model.form == .rendered {
                let size = empty.size(withAttributes: attributes)
                empty.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            } else {
                empty.draw(at: .zero, withAttributes: attributes)
            }
            return
        }
        laidOut.draw(at: CGPoint(x: 0, y: -model.scroll), visible: bounds)
    }
}
