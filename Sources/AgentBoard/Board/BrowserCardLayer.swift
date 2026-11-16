import AppKit
import QuartzCore

/// Where a browser card's controls sit, in the card's own coordinates (or the board's, given
/// the card's frame): shared by the layer that draws them and the board that hit-tests them.
struct BrowserCardLayout {
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
    static let titleFont = CardFrame.titleFont
    static let addressFont = NSFont.systemFont(ofSize: 12)
    static let chipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    /// What the device chip says: the preset it follows, or the size of a custom one.
    static func chipLabel(_ device: BrowserDevice) -> String {
        let label = device.title == BrowserDevice.customTitle ? "\(device.width) × \(device.height)" : device.preset ?? device.title
        return label + " ▾"
    }

    init(frame: CGRect, record: BrowserRecord) {
        let mid = frame.minY + CardMetrics.titleHeight / 2
        let width = min(140, CardFrame.width(of: record.name, font: Self.titleFont) + 2)
        title = CGRect(x: frame.minX + CardFrame.titleX, y: mid - 10, width: width, height: 20)
        let chip = ceil((Self.chipLabel(record.device) as NSString).size(withAttributes: [.font: Self.chipFont]).width) + 16
        device = CGRect(x: title.maxX + 8, y: mid - 11, width: min(150, chip), height: 22)
        let size = Self.button
        back = CGRect(x: device.maxX + 6, y: mid - size / 2, width: size, height: size)
        forward = back.offsetBy(dx: size + 2, dy: 0)
        reload = forward.offsetBy(dx: size + 2, dy: 0)
        close = CardMetrics.close(of: frame)
        address = CGRect(x: reload.maxX + 8, y: mid - 12, width: max(0, close.minX - reload.maxX - 16), height: 24)
        content = CardMetrics.content(of: frame)
    }
}

/// One browser card: chrome as Core Animation layers and the page itself, shown by hosting the
/// layers WebKit draws it with (no pixels are copied; the window server composites them).
final class BrowserCardLayer: CALayer {
    private let bar = CardTitleBar()
    private let addressField = CALayer()
    private var focused = false
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
        hover.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.1)
        hover.isHidden = true
        for text in [address, status] + glyphs {
            text.fontSize = 12
            text.truncationMode = .end
        }
        address.fontSize = BrowserCardLayout.addressFont.pointSize
        addressField.backgroundColor = BoardPalette.card
        addressField.cornerRadius = Theme.Radius.control
        chipText.font = BrowserCardLayout.chipFont
        chipText.fontSize = BrowserCardLayout.chipFont.pointSize
        chipText.alignmentMode = .center
        chipText.truncationMode = .end
        chip.addSublayer(chipText)
        address.font = BrowserCardLayout.addressFont
        for (glyph, symbol) in zip(glyphs, ["‹", "›", "↻"]) {
            glyph.string = symbol
            glyph.font = NSFont.systemFont(ofSize: symbol == "↻" ? 13 : 17, weight: .medium)
            glyph.fontSize = symbol == "↻" ? 13 : 17
            glyph.alignmentMode = .center
        }
        status.alignmentMode = .center
        status.isWrapped = true
        page.backgroundColor = BoardPalette.card
        page.masksToBounds = true
        page.cornerRadius = Theme.Radius.control
        dim.backgroundColor = BoardPalette.rgb(0xFFFFFF, 0.8)
        ([bar, addressField, hover, chip, address, closeGlyph, page, dim, status] + glyphs).forEach(addSublayer)
        CardFrame.reveal([closeGlyph] + glyphs, visible: false)
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
        self.focused = focused
        CardFrame.style(self, focused: focused)
        for layer in [address, status, chipText] + glyphs { layer.contentsScale = scale }

        let layout = BrowserCardLayout(frame: bounds, record: record)
        let ink = BoardPalette.ink
        let line = ceil(BrowserCardLayout.addressFont.ascender - BrowserCardLayout.addressFont.descender) + 2
        // The page's own state is its address and content; the tile stays the browser's mark.
        bar.update(size: bounds.size, icon: .symbol("globe", color: Theme.Hex.inkMuted), status: nil, title: record.name, detail: nil, focused: focused,
                   reserve: bounds.width - layout.title.maxX - 10, scale: scale)
        chip.frame = layout.device
        chip.cornerRadius = Theme.Radius.control
        chip.backgroundColor = BoardPalette.rgb(BoardPalette.accent, control == .device ? 1 : 0.14)
        chipText.string = BrowserCardLayout.chipLabel(record.device)
        chipText.foregroundColor = control == .device ? BoardPalette.rgb(Theme.Hex.white) : BoardPalette.rgb(BoardPalette.accent)
        let chipLine = ceil(BrowserCardLayout.chipFont.ascender - BrowserCardLayout.chipFont.descender) + 1
        chipText.frame = CGRect(x: 6, y: (layout.device.height - chipLine) / 2, width: layout.device.width - 12, height: chipLine)
        for (glyph, rect) in zip(glyphs, [layout.back, layout.forward, layout.reload]) {
            let height = ceil(glyph.fontSize * 1.3)
            glyph.frame = CGRect(x: rect.minX, y: rect.midY - height / 2 - 1, width: rect.width, height: height)
            glyph.foregroundColor = BoardPalette.rgb(ink, 0.75)
        }
        let url = state?.url.isEmpty == false ? state!.url : record.url
        address.string = url.isEmpty ? L("Enter an address") : Self.display(url)
        address.foregroundColor = BoardPalette.rgb(ink, url.isEmpty ? 0.45 : 0.75)
        address.frame = CGRect(x: layout.address.minX + 8, y: layout.address.midY - line / 2, width: max(0, layout.address.width - 16), height: line)
        address.isHidden = editingAddress
        addressField.frame = layout.address
        CardFrame.closeButton(nil, closeGlyph, in: layout.close, hovered: control == .close, scale: scale)
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
            hover.cornerRadius = Theme.Radius.control
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
        // A line's target lights up with the highlighted ring, like focus.
        CardFrame.style(self, focused: focused || linkTarget)
        CardFrame.reveal([closeGlyph] + glyphs, visible: visible || focused)
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
