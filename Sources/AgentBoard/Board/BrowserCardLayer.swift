import AppKit
import QuartzCore

/// Where a browser card's controls sit, in the card's own coordinates (or the board's, given
/// the card's frame): shared by the layer that draws them and the board that hit-tests them.
struct BrowserCardLayout {
    let dot: CGRect
    let title: CGRect
    /// The device chip, which opens the menu that changes it.
    let device: CGRect
    let back: CGRect
    let forward: CGRect
    let reload: CGRect
    let address: CGRect
    let close: CGRect
    let content: CGRect

    static let button: CGFloat = 22
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let addressFont = NSFont.systemFont(ofSize: 12)
    static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// What the device chip says: the preset it follows, or the size of a custom one.
    static func chipLabel(_ device: BrowserDevice) -> String {
        let label = device.title == BrowserDevice.customTitle ? "\(device.width) × \(device.height)" : device.preset ?? device.title
        return label + " ▾"
    }

    init(frame: CGRect, record: BrowserRecord) {
        let mid = frame.minY + CardMetrics.titleHeight / 2
        dot = CGRect(x: frame.minX + CardMetrics.inset + 2, y: mid - 3.5, width: 7, height: 7)
        let width = min(140, ceil((record.name as NSString).size(withAttributes: [.font: Self.titleFont]).width) + 2)
        title = CGRect(x: dot.maxX + 8, y: mid - 9, width: width, height: 18)
        let chip = ceil((Self.chipLabel(record.device) as NSString).size(withAttributes: [.font: Self.chipFont]).width) + 16
        device = CGRect(x: title.maxX + 6, y: mid - 10, width: min(150, chip), height: 20)
        let size = Self.button
        back = CGRect(x: device.maxX + 6, y: mid - size / 2, width: size, height: size)
        forward = back.offsetBy(dx: size + 2, dy: 0)
        reload = forward.offsetBy(dx: size + 2, dy: 0)
        close = CardMetrics.close(of: frame)
        address = CGRect(x: reload.maxX + 8, y: mid - 11, width: max(0, close.minX - reload.maxX - 16), height: 22)
        content = CardMetrics.content(of: frame)
    }
}

/// One browser card: chrome as Core Animation layers and the page itself, shown by hosting the
/// layers WebKit draws it with (no pixels are copied; the window server composites them).
final class BrowserCardLayer: CALayer {
    private let dot = CALayer()
    private let title = CATextLayer()
    private let chip = CALayer()
    private let chipText = CATextLayer()
    private let address = CATextLayer()
    private let glyphs: [CATextLayer] = (0..<3).map { _ in CATextLayer() }
    private let hover = CALayer()
    private let closeGlyph = CATextLayer()
    private let page = CALayer()
    private var host: CALayer?
    private var hostedContext: UInt32?
    private let dim = CALayer()
    private let status = CATextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?

    /// Which control the pointer is over, so it shows a soft fill.
    enum Control: Equatable { case device, back, forward, reload, close }

    override init() {
        super.init()
        backgroundColor = BoardPalette.card
        cornerRadius = CardMetrics.radius
        shadowColor = BoardPalette.rgb(BoardPalette.ink)
        dot.cornerRadius = 3.5
        dot.backgroundColor = BoardPalette.rgb(BoardPalette.secondary)
        hover.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.12)
        hover.isHidden = true
        for text in [title, address, closeGlyph, status] + glyphs {
            text.fontSize = 12
            text.truncationMode = .end
        }
        title.font = BrowserCardLayout.titleFont
        chipText.font = BrowserCardLayout.chipFont
        chipText.fontSize = 11
        chipText.alignmentMode = .center
        chipText.truncationMode = .end
        chip.addSublayer(chipText)
        address.font = BrowserCardLayout.addressFont
        closeGlyph.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeGlyph.string = "✕"
        for (glyph, symbol) in zip(glyphs, ["‹", "›", "↻"]) {
            glyph.string = symbol
            glyph.font = NSFont.systemFont(ofSize: symbol == "↻" ? 13 : 17, weight: .medium)
            glyph.fontSize = symbol == "↻" ? 13 : 17
            glyph.alignmentMode = .center
        }
        closeGlyph.alignmentMode = .center
        status.alignmentMode = .center
        status.isWrapped = true
        page.backgroundColor = BoardPalette.card
        page.masksToBounds = true
        page.cornerRadius = 6
        dim.backgroundColor = BoardPalette.rgb(0xFFFFFF, 0.8)
        ([dot, hover, chip, title, address, closeGlyph, page, dim, status] + glyphs).forEach(addSublayer)
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

    func update(frame: CGRect, record: BrowserRecord, page state: BrowserPage?, status message: String?,
                focused: Bool, hovered control: Control?, editingAddress: Bool, scale: CGFloat) {
        self.frame = frame
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: CardMetrics.radius, cornerHeight: CardMetrics.radius, transform: nil)
        shadowOpacity = focused ? 0.16 : 0.08
        shadowRadius = focused ? 14 : 8
        shadowOffset = CGSize(width: 0, height: focused ? 12 : 5)
        for layer in [title, address, closeGlyph, status, chipText] + glyphs { layer.contentsScale = scale }

        let layout = BrowserCardLayout(frame: bounds, record: record)
        let ink = BoardPalette.ink
        let line = ceil(BrowserCardLayout.addressFont.ascender - BrowserCardLayout.addressFont.descender) + 2
        dot.frame = layout.dot
        dot.backgroundColor = state?.phase == .open ? BoardPalette.rgb(BoardPalette.accent) : BoardPalette.rgb(BoardPalette.secondary)
        title.string = record.name
        title.foregroundColor = BoardPalette.rgb(ink, focused ? 0.9 : 0.6)
        title.frame = CGRect(x: layout.title.minX, y: layout.title.midY - line / 2, width: layout.title.width, height: line)
        chip.frame = layout.device
        chip.cornerRadius = layout.device.height / 2
        chip.backgroundColor = BoardPalette.rgb(BoardPalette.accent, control == .device ? 0.16 : 0.08)
        chipText.string = BrowserCardLayout.chipLabel(record.device)
        chipText.foregroundColor = BoardPalette.rgb(BoardPalette.accent)
        let chipLine = ceil(BrowserCardLayout.chipFont.ascender - BrowserCardLayout.chipFont.descender) + 1
        chipText.frame = CGRect(x: 6, y: (layout.device.height - chipLine) / 2, width: layout.device.width - 12, height: chipLine)
        for (glyph, rect) in zip(glyphs, [layout.back, layout.forward, layout.reload]) {
            let height = ceil(glyph.fontSize * 1.3)
            glyph.frame = CGRect(x: rect.minX, y: rect.midY - height / 2 - 1, width: rect.width, height: height)
            glyph.foregroundColor = BoardPalette.rgb(ink, 0.55)
        }
        let url = state?.url.isEmpty == false ? state!.url : record.url
        address.string = url.isEmpty ? L("Enter an address") : Self.display(url)
        address.foregroundColor = BoardPalette.rgb(ink, url.isEmpty ? 0.35 : 0.55)
        address.frame = CGRect(x: layout.address.minX + 8, y: layout.address.midY - line / 2, width: max(0, layout.address.width - 16), height: line)
        address.isHidden = editingAddress
        closeGlyph.frame = CGRect(x: layout.close.minX, y: layout.close.midY - line / 2, width: layout.close.width, height: line)
        closeGlyph.foregroundColor = BoardPalette.rgb(ink, control == .close ? 0.8 : 0.4)
        let hoverRect: CGRect? = switch control {
        case .device: nil
        case .back: layout.back
        case .forward: layout.forward
        case .reload: layout.reload
        case .close: layout.close
        case nil: nil
        }
        hover.isHidden = hoverRect == nil
        if let hoverRect {
            hover.frame = hoverRect
            hover.cornerRadius = hoverRect.height / 2
        }

        page.frame = layout.content
        let surface = state?.surface ?? record.device.viewport
        let zoom = layout.content.width / max(1, surface.width)
        if let contextID = state?.contextID, state?.phase == .open {
            hostPage(contextID, size: surface, zoom: zoom)
        } else {
            host?.removeFromSuperlayer()
            host = nil
            hostedContext = nil
        }
        dim.frame = layout.content
        dim.isHidden = message == nil
        status.isHidden = message == nil
        status.string = message
        status.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        status.foregroundColor = BoardPalette.rgb(ink, 0.6)
        status.frame = CGRect(x: layout.content.minX + 16, y: layout.content.midY - line, width: max(0, layout.content.width - 32), height: line * 2)
    }

    /// Shows the page's own layers, scaled from WebKit's size to the card's.
    private func hostPage(_ contextID: UInt32, size: CGSize, zoom: CGFloat) {
        if hostedContext != contextID {
            host?.removeFromSuperlayer()
            // CALayerHost (QuartzCore): shows another process's layer tree by its context id, the
            // way WebKit shows its own web content process.
            guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { return }
            let host = type.init()
            host.setValue(NSNumber(value: contextID), forKey: "contextId")
            host.anchorPoint = .zero
            host.position = .zero
            page.addSublayer(host)
            self.host = host
            hostedContext = contextID
        }
        host?.bounds = CGRect(origin: .zero, size: size)
        host?.transform = CATransform3DMakeScale(zoom, zoom, 1)
    }

    /// An address without its scheme, the way the title bar shows it.
    private static func display(_ url: String) -> String {
        for scheme in ["https://", "http://"] where url.hasPrefix(scheme) { return String(url.dropFirst(scheme.count)) }
        return url
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
