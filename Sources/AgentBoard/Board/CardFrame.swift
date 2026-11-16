import AgentRuntime
import AppKit
import MetalPerformanceShaders
import QuartzCore

/// The one frame every card wears: firm corners, no shadow, and a translucent title bar with
/// the card's icon, its name, its state and a quieter detail. Each card layer adds its own
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

    /// Corners and the highlighted look (focus, and selection
    /// through the same flag): a solid accent ring, with the accent cap the title bar draws. No
    /// blurred glow. The card has no background of its own: its title bar draws header and body.
    static func style(_ card: CALayer, focused highlighted: Bool) {
        card.backgroundColor = nil
        card.cornerRadius = CardMetrics.radius
        // No shadow: the card's contrast against the sky separates it.
        card.shadowOpacity = 0
        card.borderColor = BoardPalette.rgb(BoardPalette.accent)
        card.borderWidth = highlighted ? 2 : 0
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

    /// The header's translucent gray: white over the sky, a breath of ink, so it reads as glass.
    static let headerWhite: CGFloat = 0.85
    static let headerInk: CGFloat = 0.04
    static let glyphSize: CGFloat = 14

    /// The header's solid color over a sky color: what its text and icons must contrast with.
    static func header(over sky: UInt32) -> UInt32 {
        func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
            (0..<3).reduce(0) { result, i in
                let shift = UInt32(16 - i * 8)
                let x = CGFloat(a >> shift & 0xFF), y = CGFloat(b >> shift & 0xFF)
                return result | UInt32((x * (1 - t) + y * t).rounded()) << shift
            }
        }
        return mix(mix(sky, Theme.Hex.white, headerWhite), BoardPalette.ink, headerInk)
    }
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

/// A card's title bar: translucent gray over the sky, the card's icon, its name, its state as a
/// small mark (in `CardStatus`'s vocabulary) and a quieter detail. Below it the card's body.
/// Focus shows as an accent cap on the top edge.
final class CardTitleBar: CALayer {
    private let backdrop = CALayer()
    private let tint = CALayer()
    private let body = CALayer()
    private let glyph = CALayer()
    private let title = CATextLayer()
    private let mark = CALayer()
    private let markGlyph = CALayer()
    private let detail = CATextLayer()
    private let rule = CALayer()
    private var status: CardStatus?

    override init() {
        super.init()
        maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tint.maskedCorners = maskedCorners
        backdrop.maskedCorners = maskedCorners
        backdrop.masksToBounds = true
        let ink = CALayer()
        ink.backgroundColor = BoardPalette.rgb(BoardPalette.ink, CardFrame.headerInk)
        tint.addSublayer(ink)
        body.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        mark.cornerRadius = Theme.Radius.thumb
        title.font = CardFrame.titleFont
        title.fontSize = CardFrame.titleFont.pointSize
        detail.font = CardFrame.detailFont
        detail.fontSize = CardFrame.detailFont.pointSize
        for text in [title, detail] { text.truncationMode = .end }
        rule.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
        [body, backdrop, tint, glyph, title, mark, detail, rule].forEach(addSublayer)
        mark.addSublayer(markGlyph)
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
        backdrop.frame = bounds
        backdrop.cornerRadius = CardMetrics.radius
        // Over the frosted sky: mostly white with a breath of ink, a translucent light gray.
        // Reduce Transparency makes it solid; Increase Contrast darkens the quieter text.
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        backdrop.isHidden = solid
        tint.backgroundColor = BoardPalette.rgb(Theme.Hex.white, solid ? 1 : CardFrame.headerWhite)
        tint.sublayers?.first?.frame = tint.bounds
        body.frame = CGRect(x: 0, y: height, width: width, height: max(0, size.height - height))
        body.cornerRadius = CardMetrics.radius
        body.backgroundColor = fill

        let g = CardFrame.glyphSize
        glyph.frame = CGRect(x: CardMetrics.inset, y: (height - g) / 2, width: g, height: g)
        glyph.contents = icon.image(size: g, scale: scale)
        glyph.contentsScale = scale

        let ink = BoardPalette.ink
        let available = max(0, width - CardFrame.titleX - reserve - 8)
        let titleLine = CardFrame.lineHeight(CardFrame.titleFont)
        let shown = status.flatMap { $0 == .stopped ? nil : $0 }
        let markSize: CGFloat = shown == nil ? 0 : 14
        let titleFont = status == .waiting ? CardFrame.waitingFont : CardFrame.titleFont
        // A state that needs the user (waiting, crashed) keeps its words; the name gives way.
        let urgent = status == .waiting || status == .crashed
        let keep = urgent && info != nil ? CardFrame.width(of: info!, font: CardFrame.detailFont) + 8 : 0
        let nameRoom = max(0, available - (markSize == 0 ? 0 : markSize + 6) - keep)
        let titleWidth = min(nameRoom, CardFrame.width(of: text, font: titleFont) + 2)
        title.string = text
        title.font = titleFont
        title.contentsScale = scale
        title.foregroundColor = BoardPalette.rgb(ink)
        title.frame = CGRect(x: CardFrame.titleX, y: (height - titleLine) / 2, width: titleWidth, height: titleLine)

        // The state sits next to the name, apart from the icon, as the same dot the sidebar
        // shows: running accent, waiting deep blue (and a bolder name), crashed red; stopped nothing.
        mark.isHidden = shown == nil
        mark.backgroundColor = nil
        if let shown {
            let dot: CGFloat = 8
            let color = shown == .crashed ? Theme.Hex.danger : shown == .waiting || contrast ? Theme.Hex.deep : BoardPalette.accent
            mark.frame = CGRect(x: title.frame.maxX + 6, y: (height - markSize) / 2, width: markSize, height: markSize)
            markGlyph.contents = nil
            markGlyph.backgroundColor = BoardPalette.rgb(color)
            markGlyph.cornerRadius = dot / 2
            markGlyph.frame = CGRect(x: (markSize - dot) / 2, y: (markSize - dot) / 2, width: dot, height: dot)
        }
        let detailLine = CardFrame.lineHeight(CardFrame.detailFont)
        let detailX = (mark.isHidden ? title.frame.maxX : mark.frame.maxX) + 8
        detail.string = info
        detail.isHidden = info == nil || detailX + 24 > CardFrame.titleX + available
        detail.contentsScale = scale
        detail.foregroundColor = BoardPalette.rgb(status == .crashed ? Theme.Hex.danger : status == .waiting || contrast ? ink : Theme.Hex.inkMuted)
        detail.frame = CGRect(x: detailX, y: (height - detailLine) / 2 + 1, width: max(0, CardFrame.titleX + available - detailX), height: detailLine)
        // Focus caps the card's top edge; no line ever splits the bar from the content.
        rule.frame = CGRect(x: CardMetrics.radius, y: 0, width: max(0, width - CardMetrics.radius * 2), height: 3)
        rule.isHidden = !focused
        CATransaction.commit()
        animate(status)
        SkyBlur.shared.register(self)
        refreshBackdrop()
    }

    /// Shows the blurred sky's patch that lies behind this header, wherever the camera put it.
    func refreshBackdrop() {
        // The blur is of the sky layer, which may be shorter than the window (under the top bar).
        guard let surface = SkyBlur.shared.current, let root = SkyBlur.shared.sky, superlayer != nil,
              root.bounds.width > 0, root.bounds.height > 0 else { return }
        let rect = convert(bounds, to: root)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = surface
        // Unit coordinates of the sky image, whose first row is the top of the canvas.
        let y = root.isGeometryFlipped || root.contentsAreFlipped() ? rect.minY : root.bounds.height - rect.maxY
        backdrop.contentsRect = CGRect(x: rect.minX / root.bounds.width, y: y / root.bounds.height,
                                       width: rect.width / root.bounds.width, height: rect.height / root.bounds.height)
        CATransaction.commit()
    }

    /// Running breathes by size at full color (as in the sidebar, so it keeps its contrast);
    /// waiting nudges; crashed and stopped hold still.
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

/// The sky behind the cards, blurred once per sky frame into a shared low-resolution surface
/// that every card header shows its own patch of: frosted glass without a live blur per card.
// Only used on the main thread: the sky draws there and the completion hops back to it.
final class SkyBlur: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SkyBlur()

    /// Two surfaces taking turns, so each frame is a new `contents` the headers pick up.
    private var surfaces: [(surface: IOSurface, texture: MTLTexture)] = []
    private var next = 0
    private var blur: MPSImageGaussianBlur?
    /// The surface with the latest blurred frame.
    private(set) var current: IOSurface?
    private let headers = NSHashTable<CardTitleBar>.weakObjects()

    /// The sky layer the blurred frames are of; headers place their patch relative to it.
    weak var sky: CALayer?

    func register(_ header: CardTitleBar) { headers.add(header) }

    func setCurrentForTesting(_ surface: IOSurface) { current = surface }

    /// Whether any header is on screen over the sky, so the sky can skip the blur otherwise.
    var isNeeded: Bool {
        guard let sky else { return false }
        return headers.allObjects.contains { header in
            header.superlayer != nil && !header.isHidden && header.convert(header.bounds, to: sky).intersects(sky.bounds)
        }
    }

    /// Encodes the blur of a sky frame into the sky's own command buffer (`SkyView.onSkyFrame`).
    func encode(_ texture: MTLTexture, _ commands: MTLCommandBuffer) {
        let device = texture.device
        if surfaces.first.map({ $0.texture.width != texture.width || $0.texture.height != texture.height }) ?? true {
            surfaces = (0..<2).compactMap { _ in
                guard let surface = IOSurface(properties: [.width: texture.width, .height: texture.height, .bytesPerElement: 4,
                                                           .pixelFormat: kCVPixelFormatType_32BGRA]) else { return nil }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: texture.width,
                                                                          height: texture.height, mipmapped: false)
                descriptor.usage = [.shaderWrite, .shaderRead]
                guard let target = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
                return (surface, target)
            }
            // Sigma in sky pixels (two points each): soft enough to read as frosted glass.
            blur = MPSImageGaussianBlur(device: device, sigma: 6)
            blur?.edgeMode = .clamp
        }
        guard surfaces.count == 2, let blur else { return }
        let target = surfaces[next]
        next = 1 - next
        blur.encode(commandBuffer: commands, sourceTexture: texture, destinationTexture: target.texture)
        commands.addCompletedHandler { _ in
            nonisolated(unsafe) let surface = target.surface
            DispatchQueue.main.async {
                self.current = surface
                for header in self.headers.allObjects { header.refreshBackdrop() }
            }
        }
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
