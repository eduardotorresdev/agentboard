import AppKit
import QuartzCore

/// Where a simulator card's controls sit, in the card's own coordinates (or the board's, given
/// the card's frame): shared by the layer that draws them and the board that hit-tests them.
struct SimulatorCardLayout {
    let title: CGRect
    /// The device chip, which opens the menu that changes the device type.
    let device: CGRect
    let home: CGRect
    let close: CGRect
    let content: CGRect

    static let titleFont = CardFrame.titleFont
    static let chipFont = BrowserCardLayout.chipFont

    static func chipLabel(_ record: SimulatorRecord) -> String { record.deviceType + " ▾" }

    init(frame: CGRect, record: SimulatorRecord) {
        let mid = frame.minY + CardMetrics.titleHeight / 2
        let size = BrowserCardLayout.button
        let close = CardMetrics.close(of: frame)
        let chip = min(150, ceil((Self.chipLabel(record) as NSString).size(withAttributes: [.font: Self.chipFont]).width) + 16)
        // On a narrow card the name gives way first, so the controls never reach close.
        let controls = 8 + chip + 6 + size + 12
        let room = max(0, close.minX - frame.minX - CardFrame.titleX - controls)
        let width = min(140, room, CardFrame.width(of: record.name, font: Self.titleFont) + 2)
        title = CGRect(x: frame.minX + CardFrame.titleX, y: mid - 10, width: width, height: 20)
        device = CGRect(x: title.maxX + 8, y: mid - 11, width: chip, height: 22)
        home = CGRect(x: device.maxX + 6, y: mid - size / 2, width: size, height: size)
        self.close = close
        content = CardMetrics.content(of: frame)
    }
}

/// One simulator card: chrome as Core Animation layers and the device's screen, shown by
/// hosting the layer the simulator sidecar puts its framebuffer in (no pixels are copied; the
/// window server composites it, and a still screen costs nothing).
final class SimulatorCardLayer: CALayer {
    private let bar = CardTitleBar()
    private var focused = false
    private let chip = CALayer()
    private let chipText = CATextLayer()
    private let homeGlyph = CATextLayer()
    private let hover = CALayer()
    private let closeGlyph = CATextLayer()
    private let screenLayer = CALayer()
    private var host: CALayer?
    private var hostedContext: UInt32?
    private let dim = CALayer()
    private let status = CATextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?

    /// Which control the pointer is over, so it shows a soft fill.
    enum Control: Equatable { case device, home, close }

    override init() {
        super.init()
        hover.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.1)
        hover.isHidden = true
        chipText.font = SimulatorCardLayout.chipFont
        chipText.fontSize = SimulatorCardLayout.chipFont.pointSize
        chipText.alignmentMode = .center
        chipText.truncationMode = .end
        chip.addSublayer(chipText)
        homeGlyph.string = "⌂"
        homeGlyph.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        homeGlyph.fontSize = 15
        homeGlyph.alignmentMode = .center
        status.fontSize = Theme.Font.labelSize
        status.alignmentMode = .center
        status.isWrapped = true
        screenLayer.backgroundColor = BoardPalette.rgb(Theme.Hex.window)
        screenLayer.masksToBounds = true
        screenLayer.cornerRadius = Theme.Radius.control
        dim.backgroundColor = BoardPalette.rgb(Theme.Hex.paper, 0.8)
        [bar, hover, chip, homeGlyph, closeGlyph, screenLayer, dim, status].forEach(addSublayer)
        CardFrame.reveal([closeGlyph, homeGlyph], visible: false)
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

    func update(frame: CGRect, record: SimulatorRecord, screen state: SimulatorScreen?, status message: String?,
                focused: Bool, hovered control: Control?, scale: CGFloat) {
        self.frame = frame
        self.focused = focused
        CardFrame.style(self, focused: focused)
        for layer in [status, chipText, homeGlyph] { layer.contentsScale = scale }

        let layout = SimulatorCardLayout(frame: bounds, record: record)
        let ink = BoardPalette.ink
        bar.update(size: bounds.size, icon: .symbol("iphone", color: Theme.Hex.inkMuted), status: nil, title: record.name, detail: nil,
                   focused: focused, reserve: bounds.width - layout.title.maxX - 10, scale: scale)
        chip.frame = layout.device
        chip.cornerRadius = Theme.Radius.control
        chip.backgroundColor = BoardPalette.rgb(control == .device ? BoardPalette.accent : Theme.Hex.accentSoft)
        chipText.string = SimulatorCardLayout.chipLabel(record)
        chipText.foregroundColor = BoardPalette.rgb(control == .device ? Theme.Hex.white : Theme.Hex.accentText)
        let chipLine = ceil(SimulatorCardLayout.chipFont.ascender - SimulatorCardLayout.chipFont.descender) + 1
        chipText.frame = CGRect(x: 6, y: (layout.device.height - chipLine) / 2, width: layout.device.width - 12, height: chipLine)
        let glyphHeight = ceil(homeGlyph.fontSize * 1.3)
        homeGlyph.frame = CGRect(x: layout.home.minX, y: layout.home.midY - glyphHeight / 2, width: layout.home.width, height: glyphHeight)
        homeGlyph.foregroundColor = BoardPalette.rgb(ink, 0.75)
        CardFrame.closeButton(nil, closeGlyph, in: layout.close, hovered: control == .close, scale: scale)
        let hoverRect: CGRect? = switch control {
        case .home: layout.home
        case .close: layout.close
        case .device, nil: nil
        }
        hover.isHidden = hoverRect == nil
        if let hoverRect {
            hover.frame = hoverRect
            hover.cornerRadius = Theme.Radius.control
        }

        screenLayer.frame = layout.content
        switch (state?.phase == .open ? state?.content : nil, state?.size) {
        case (.context(let contextID)?, let size?):
            hostScreen(contextID, size: size, zoom: layout.content.width / max(1, size.width))
        case (.layer(let video)?, _):
            show(video)
            video.frame = screenLayer.bounds
        default:
            show(nil)
        }
        let line = ceil(BrowserCardLayout.addressFont.ascender - BrowserCardLayout.addressFont.descender) + 2
        dim.frame = layout.content
        dim.cornerRadius = Theme.Radius.control
        dim.isHidden = message == nil
        status.isHidden = message == nil
        status.string = message
        status.font = NSFont.systemFont(ofSize: Theme.Font.labelSize, weight: .medium)
        status.foregroundColor = BoardPalette.rgb(ink, 0.7)
        status.frame = CGRect(x: layout.content.minX + 16, y: layout.content.midY - line * 1.5, width: max(0, layout.content.width - 32), height: line * 3)
    }

    /// Puts `layer` (or nothing) on the screen in place of what was there.
    private func show(_ layer: CALayer?) {
        guard host !== layer || layer == nil else { return }
        host?.removeFromSuperlayer()
        host = layer
        hostedContext = nil
        if let layer {
            layer.anchorPoint = .zero
            layer.position = .zero
            screenLayer.addSublayer(layer)
        }
    }

    /// Shows the sidecar's layer, scaled from the screen's points to the card's.
    private func hostScreen(_ contextID: UInt32, size: CGSize, zoom: CGFloat) {
        if hostedContext != contextID {
            host?.removeFromSuperlayer()
            // CALayerHost (QuartzCore): shows another process's layer tree by its context id.
            guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { return }
            let host = type.init()
            host.setValue(NSNumber(value: contextID), forKey: "contextId")
            host.anchorPoint = .zero
            host.position = .zero
            screenLayer.addSublayer(host)
            self.host = host
            hostedContext = contextID
        }
        host?.bounds = CGRect(origin: .zero, size: size)
        host?.transform = CATransform3DMakeScale(zoom, zoom, 1)
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
        CardFrame.style(self, focused: focused || linkTarget)
        CardFrame.reveal([closeGlyph, homeGlyph], visible: visible || focused)
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
