import AgentRuntime
import AppKit
import QuartzCore

/// The one frame every card wears: soft corners, no shadow, and a solid title bar with the
/// card's icon, its name, a quieter detail and its state. Each card layer adds its own
/// controls on top.
enum CardFrame {
    static let titleFont = NSFont.systemFont(ofSize: Theme.Font.bodySize, weight: .semibold)
    /// A card waiting on the user says so by weight.
    static let waitingFont = NSFont.systemFont(ofSize: Theme.Font.bodySize, weight: .heavy)
    static let detailFont = NSFont.systemFont(ofSize: Theme.Font.labelSize, weight: .regular)
    static let controlFont = NSFont.systemFont(ofSize: Theme.Font.labelSize, weight: .medium)
    /// Where the name starts, after the icon.
    static var titleX: CGFloat { CardMetrics.inset + glyphSize + 8 }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) + 2 }

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Corners and the highlighted look (focus, and selection through the same flag): a ring that
    /// is always there, clear until the card is highlighted, then the accent. No blurred glow. The card has no background of its own: its title bar draws header and body.
    static func style(_ card: CALayer, focused highlighted: Bool) {
        card.backgroundColor = nil
        card.cornerRadius = CardMetrics.radius
        // No shadow: the card's contrast against the canvas separates it.
        card.shadowOpacity = 0
        card.borderWidth = 2
        card.borderColor = highlighted ? BoardPalette.rgb(BoardPalette.accent) : CGColor(gray: 0, alpha: 0)
    }

    /// A close control: a crisp square that fills while hovered, its cross centered.
    static func closeButton(_ hover: CALayer?, _ glyph: CATextLayer, in rect: CGRect, hovered: Bool, scale: CGFloat) {
        hover?.frame = rect
        hover?.cornerRadius = Theme.Radius.control
        hover?.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.1)
        hover?.isHidden = !hovered
        glyph.font = controlFont
        glyph.fontSize = controlFont.pointSize
        glyph.string = "✕"
        glyph.alignmentMode = .center
        glyph.contentsScale = scale
        glyph.foregroundColor = BoardPalette.rgb(BoardPalette.ink, hovered ? 0.9 : 0.55)
        let line = lineHeight(controlFont)
        glyph.frame = CGRect(x: rect.minX, y: rect.midY - line / 2, width: rect.width, height: line)
    }

    /// Shows or hides card controls with a spring fade, only when it changes.
    static func reveal(_ layers: [CALayer], visible: Bool) {
        for layer in layers where (layer.opacity == 1) != visible {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = visible ? 1 : 0
            let spring = CASpringAnimation(keyPath: "opacity")
            spring.fromValue = from
            spring.toValue = layer.opacity
            spring.stiffness = 320
            spring.damping = 28
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "reveal")
        }
    }

    /// The icon of an agent of this kind: Claude's own mark in its own orange; other agents a
    /// generic glyph in their brand color from the catalog.
    static func agentIcon(provider id: String?) -> CardIcon {
        if id == nil || id == "claude" { return .claude }
        let brand = id.flatMap(AgentCatalog.provider(id:))?.brandColor
        return .symbol("chevron.left.forwardslash.chevron.right", color: brand ?? BoardPalette.ink)
    }

    static let glyphSize: CGFloat = 14
    /// The header's solid fill, one step lighter than the card's body: what its text and icons must contrast with.
    static let header: UInt32 = Theme.Hex.paperDeep
    /// The status pill on the header's right: its fill and the color of its dot and words.
    static func pill(_ status: CardStatus) -> (fill: UInt32, ink: UInt32)? {
        switch status {
        case .running: (Theme.Hex.accentSoft, Theme.Hex.accentText)
        case .waiting: (Theme.Hex.you, Theme.Hex.onYou)
        case .crashed: (Theme.Hex.danger, Theme.Hex.window)
        case .stopped: nil
        }
    }
    static let pillFont = NSFont.systemFont(ofSize: Theme.Font.captionSize, weight: .semibold)
}

/// What a card's title bar shows as its icon.
enum CardIcon: Hashable {
    /// Claude's mark, drawn in its own brand color.
    case claude
    case symbol(String, color: UInt32)

    /// The glyph as pixels, drawn once per icon and scale.
    func image(size: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(self)|\(size)|\(scale)"
        if let cached = Self.cache[key] { return cached }
        let source: NSImage? = switch self {
        case .claude: Self.claudeMark
        case .symbol(let name, _):
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        }
        guard let source else { return nil }
        let pixels = Int(ceil(size * scale))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Fit the glyph's aspect into the square.
        let aspect = source.size.width / max(1, source.size.height)
        let fit = aspect > 1 ? CGSize(width: CGFloat(pixels), height: CGFloat(pixels) / aspect)
                             : CGSize(width: CGFloat(pixels) * aspect, height: CGFloat(pixels))
        let rect = CGRect(x: (CGFloat(pixels) - fit.width) / 2, y: (CGFloat(pixels) - fit.height) / 2, width: fit.width, height: fit.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        if case .symbol(_, let color) = self {
            context.setBlendMode(.sourceIn)
            context.setFillColor(BoardPalette.rgb(color))
            context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        let image = context.makeImage()
        Self.cache[key] = image
        return image
    }

    // Only touched from the board, which draws on the main thread.
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    private static let claudeMark = Bundle.module.url(forResource: "ClaudeSymbol", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
}

/// A card's title bar: a solid header one step lighter than the body, the card's icon, its name,
/// a quieter detail and, on the right, its state as a pill (in `CardStatus`'s vocabulary).
/// Below it the card's body.
final class CardTitleBar: CALayer {
    private let tint = CALayer()
    private let body = CALayer()
    private let glyph = CALayer()
    private let title = CATextLayer()
    private let pill = CALayer()
    private let mark = CALayer()
    private let pillText = CATextLayer()
    private let detail = CATextLayer()
    private var status: CardStatus?

    override init() {
        super.init()
        maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tint.maskedCorners = maskedCorners
        body.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        pill.cornerRadius = Theme.Radius.thumb
        pill.cornerCurve = .continuous
        title.font = CardFrame.titleFont
        title.fontSize = CardFrame.titleFont.pointSize
        detail.font = CardFrame.detailFont
        detail.fontSize = CardFrame.detailFont.pointSize
        pillText.font = CardFrame.pillFont
        pillText.fontSize = CardFrame.pillFont.pointSize
        for text in [title, detail, pillText] { text.truncationMode = .end }
        [body, tint, glyph, title, pill, detail].forEach(addSublayer)
        [mark, pillText].forEach(pill.addSublayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays the bar out across a card of `size`, leaving `reserve` points on the right for the
    /// card's controls, and fills the body below it with `fill`. A nil status is a card without
    /// one (browser, post-it, image, file tree).
    func update(size: CGSize, height: CGFloat = CardMetrics.titleHeight, icon: CardIcon, status: CardStatus?, kind: CardStatus.Kind = .agent,
                title text: String, detail info: String?, focused: Bool, reserve: CGFloat, fill: CGColor = BoardPalette.card, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = size.width
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        cornerRadius = CardMetrics.radius
        backgroundColor = nil
        tint.frame = bounds
        tint.cornerRadius = CardMetrics.radius
        tint.backgroundColor = BoardPalette.rgb(CardFrame.header)
        body.frame = CGRect(x: 0, y: height, width: width, height: max(0, size.height - height))
        body.cornerRadius = CardMetrics.radius
        body.backgroundColor = fill
        // Increase Contrast brings the quieter detail up to full ink.
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        let g = CardFrame.glyphSize
        glyph.frame = CGRect(x: CardMetrics.inset, y: (height - g) / 2, width: g, height: g)
        glyph.contents = icon.image(size: g, scale: scale)
        glyph.contentsScale = scale

        let ink = BoardPalette.ink
        // The pill sits at the right, before the card's controls.
        let colors = status.flatMap(CardFrame.pill)
        pill.isHidden = colors == nil
        var pillX = width - reserve
        if let colors, let status {
            let dot: CGFloat = 6, pad: CGFloat = 8, pillHeight: CGFloat = 20
            let textWidth = CardFrame.width(of: status.label, font: CardFrame.pillFont) + 2
            let pillWidth = pad + dot + 5 + textWidth + pad
            pillX -= pillWidth
            pill.frame = CGRect(x: pillX, y: (height - pillHeight) / 2, width: pillWidth, height: pillHeight)
            pill.backgroundColor = BoardPalette.rgb(colors.fill)
            mark.frame = CGRect(x: pad, y: (pillHeight - dot) / 2, width: dot, height: dot)
            mark.cornerRadius = dot / 2
            mark.backgroundColor = BoardPalette.rgb(colors.ink)
            let line = CardFrame.lineHeight(CardFrame.pillFont)
            pillText.string = status.label
            pillText.contentsScale = scale
            pillText.foregroundColor = BoardPalette.rgb(colors.ink)
            pillText.frame = CGRect(x: pad + dot + 5, y: (pillHeight - line) / 2, width: textWidth, height: line)
        }

        let available = max(0, pillX - CardFrame.titleX - 8)
        let titleLine = CardFrame.lineHeight(CardFrame.titleFont)
        let titleFont = status == .waiting ? CardFrame.waitingFont : CardFrame.titleFont
        title.string = text
        title.font = titleFont
        title.contentsScale = scale
        title.foregroundColor = BoardPalette.rgb(ink)
        title.frame = CGRect(x: CardFrame.titleX, y: (height - titleLine) / 2,
                             width: min(available, CardFrame.width(of: text, font: titleFont) + 2), height: titleLine)

        let detailLine = CardFrame.lineHeight(CardFrame.detailFont)
        let detailX = title.frame.maxX + 6
        detail.string = info
        detail.isHidden = info == nil || detailX + 24 > CardFrame.titleX + available
        detail.contentsScale = scale
        detail.foregroundColor = BoardPalette.rgb(contrast ? ink : Theme.Hex.inkMuted)
        detail.frame = CGRect(x: detailX, y: (height - detailLine) / 2 + 1, width: max(0, CardFrame.titleX + available - detailX), height: detailLine)
        CATransaction.commit()
        animate(status)
    }

    /// Running breathes its dot by size at full color (as in the sidebar, so it keeps its
    /// contrast); waiting nudges; crashed and stopped hold still.
    private func animate(_ new: CardStatus?) {
        guard new != status else { return }
        status = new
        mark.removeAllAnimations()
        guard new == .running || new == .waiting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1
        spring.toValue = new == .running ? 0.65 : 1.18
        spring.stiffness = new == .running ? 30 : 180
        spring.damping = new == .running ? 9 : 10
        spring.duration = spring.settlingDuration
        spring.autoreverses = true
        spring.repeatCount = .infinity
        mark.add(spring, forKey: "status")
    }
}

extension CGRect {
    /// This control's hit area at `zoom`: grown around its center so it never gets smaller on
    /// screen than `CardMetrics.minimumTarget`, as the resize handles already do.
    func target(zoom: CGFloat) -> CGRect {
        let side = CardMetrics.minimumTarget / max(zoom, 0.01)
        return insetBy(dx: -max(0, side - width) / 2, dy: -max(0, side - height) / 2)
    }
}
