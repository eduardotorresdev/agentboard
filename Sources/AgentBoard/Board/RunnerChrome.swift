import AgentRuntime
import AppKit
import Orchestration
import QuartzCore

/// What can be clicked on a runner card besides its terminal.
enum RunnerControl: Equatable {
    /// Stop while it runs, start while it doesn't.
    case toggle
    case restart
    /// Opens the address in the default browser.
    case link(String)
}

/// A runner card's extra chrome, in card coordinates: start/stop and restart in the title bar,
/// and under it a strip with the command, the addresses it serves, and what it costs.
struct RunnerChromeLayout {
    static let stripHeight: CGFloat = 30
    static let buttonGap: CGFloat = 6
    static let chipHeight: CGFloat = 20
    static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let commandFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let metricsFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Room the title leaves for the two buttons next to close.
    static let titleReserve = (CardMetrics.closeSize + buttonGap) * 2

    let toggle: CGRect
    let restart: CGRect
    let strip: CGRect
    let command: CGRect
    let chips: [(rect: CGRect, link: Link)]

    struct Link: Equatable {
        let label: String
        let url: String
        /// The network address of a port other devices can reach, as opposed to localhost.
        let network: Bool
    }

    /// Where the terminal goes on a runner card of `size`.
    static func terminal(in bounds: CGRect) -> CGRect {
        let content = CardMetrics.content(of: bounds)
        return CGRect(x: content.minX, y: content.minY + stripHeight, width: content.width, height: max(0, content.height - stripHeight))
    }

    init(bounds: CGRect, command: String, links: [Link], metricsWidth: CGFloat) {
        let close = CardMetrics.close(of: bounds)
        restart = close.offsetBy(dx: -(close.width + Self.buttonGap), dy: 0)
        toggle = restart.offsetBy(dx: -(close.width + Self.buttonGap), dy: 0)
        strip = CGRect(x: bounds.minX + CardMetrics.inset, y: bounds.minY + CardMetrics.titleHeight,
                       width: bounds.width - CardMetrics.inset * 2, height: Self.stripHeight)
        let available = strip.width - metricsWidth - 12
        let commandWidth = min(Self.width(of: "$ " + command, font: Self.commandFont), available * 0.4)
        let line = ceil(Self.commandFont.ascender - Self.commandFont.descender)
        self.command = CGRect(x: strip.minX + 2, y: strip.midY - line / 2 - 2, width: commandWidth, height: line)
        var x = self.command.maxX + 10
        var chips: [(CGRect, Link)] = []
        for link in links {
            let width = Self.width(of: link.label + " ↗", font: Self.chipFont) + 16
            // Chips that don't fit are left out; the tools still list every address.
            guard x + width <= strip.minX + available else { break }
            chips.append((CGRect(x: x, y: strip.midY - Self.chipHeight / 2 - 2, width: width, height: Self.chipHeight), link))
            x += width + 6
        }
        self.chips = chips
    }

    func control(at point: CGPoint) -> RunnerControl? {
        if toggle.insetBy(dx: -2, dy: -4).contains(point) { return .toggle }
        if restart.insetBy(dx: -2, dy: -4).contains(point) { return .restart }
        return chips.first { $0.rect.contains(point) }.map { .link($0.link.url) }
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Draws a runner card's chrome over its `CardLayer`.
final class RunnerChromeLayer: CALayer {
    private let toggleHover = CALayer()
    private let toggleIcon = CALayer()
    private let restartHover = CALayer()
    private let restartIcon = CALayer()
    private let command = CATextLayer()
    private let metrics = CATextLayer()
    private var chips: [(background: CALayer, label: CATextLayer)] = []
    private var iconKey: [CALayer: String] = [:]

    override init() {
        super.init()
        for hover in [toggleHover, restartHover] {
            hover.cornerRadius = CardMetrics.closeSize / 2
            hover.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.12)
            hover.isHidden = true
        }
        for icon in [toggleIcon, restartIcon] { icon.contentsGravity = .center }
        command.font = RunnerChromeLayout.commandFont
        command.fontSize = RunnerChromeLayout.commandFont.pointSize
        command.foregroundColor = BoardPalette.rgb(BoardPalette.ink, 0.5)
        command.truncationMode = .end
        metrics.font = RunnerChromeLayout.metricsFont
        metrics.fontSize = RunnerChromeLayout.metricsFont.pointSize
        metrics.alignmentMode = .right
        [toggleHover, toggleIcon, restartHover, restartIcon, command, metrics].forEach(addSublayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The strip's right side: what the runner costs while it runs, otherwise its state.
    static func metricsText(state: AgentSession.State, stats: RunnerStats?, exitCode: Int32?) -> (text: String, attention: Bool) {
        switch state {
        case .starting: return (L("Starting…"), false)
        case .running:
            guard let stats else { return (L("Running"), false) }
            let memory = ByteCountFormatter.string(fromByteCount: Int64(stats.memory), countStyle: .memory)
            guard let cpu = stats.cpu else { return (memory, false) }
            return ("\(String(format: "%.1f", cpu))% CPU · \(memory)", false)
        case .exited:
            let code = exitCode ?? 0
            return (code == 0 ? L("Finished") : L("Exited with code \(Int(code))"), code != 0)
        case .failed: return (L("Failed to start"), true)
        case .stopped: return (L("Stopped"), false)
        }
    }

    func update(bounds card: CGRect, layout: RunnerChromeLayout, command text: String, running: Bool,
                metrics status: (text: String, attention: Bool), hovered: RunnerControl?, scale: CGFloat) {
        frame = card
        for layer in [command, metrics] + chips.map(\.label) { layer.contentsScale = scale }

        toggleHover.frame = layout.toggle
        toggleHover.isHidden = hovered != .toggle
        restartHover.frame = layout.restart
        restartHover.isHidden = hovered != .restart
        setIcon(toggleIcon, running ? "stop.fill" : "play.fill", in: layout.toggle, hovered: hovered == .toggle, scale: scale)
        setIcon(restartIcon, "arrow.clockwise", in: layout.restart, hovered: hovered == .restart, scale: scale)

        command.string = "$ " + text
        command.frame = layout.command

        while chips.count < layout.chips.count {
            let background = CALayer()
            background.cornerRadius = RunnerChromeLayout.chipHeight / 2
            let label = CATextLayer()
            label.font = RunnerChromeLayout.chipFont
            label.fontSize = RunnerChromeLayout.chipFont.pointSize
            label.alignmentMode = .center
            label.contentsScale = scale
            background.addSublayer(label)
            addSublayer(background)
            chips.append((background, label))
        }
        while chips.count > layout.chips.count { chips.removeLast().background.removeFromSuperlayer() }
        let line = ceil(RunnerChromeLayout.chipFont.ascender - RunnerChromeLayout.chipFont.descender)
        for (chip, item) in zip(chips, layout.chips) {
            let lit = hovered == .link(item.link.url)
            chip.background.frame = item.rect
            // Localhost is the main address (violet); the network one is secondary (orange).
            let tint = item.link.network ? BoardPalette.secondary : BoardPalette.accent
            chip.background.backgroundColor = BoardPalette.rgb(tint, lit ? 0.2 : 0.1)
            chip.label.string = item.link.label + " ↗"
            chip.label.foregroundColor = BoardPalette.rgb(tint)
            chip.label.frame = CGRect(x: 0, y: (item.rect.height - line) / 2, width: item.rect.width, height: line)
        }

        let metricsLine = ceil(RunnerChromeLayout.metricsFont.ascender - RunnerChromeLayout.metricsFont.descender)
        metrics.string = status.text
        metrics.foregroundColor = status.attention ? BoardPalette.rgb(BoardPalette.secondary) : BoardPalette.rgb(BoardPalette.ink, 0.55)
        let width = RunnerChromeLayout.width(of: status.text, font: RunnerChromeLayout.metricsFont) + 4
        metrics.frame = CGRect(x: layout.strip.maxX - width, y: layout.strip.midY - metricsLine / 2 - 2, width: width, height: metricsLine)
    }

    /// Width the metrics text takes, for the layout.
    static func metricsWidth(_ text: String) -> CGFloat {
        RunnerChromeLayout.width(of: text, font: RunnerChromeLayout.metricsFont) + 4
    }

    private func setIcon(_ layer: CALayer, _ symbol: String, in rect: CGRect, hovered: Bool, scale: CGFloat) {
        layer.frame = rect
        let key = "\(symbol)-\(hovered)-\(scale)"
        guard iconKey[layer] != key else { return }
        iconKey[layer] = key
        let color = NSColor(cgColor: BoardPalette.rgb(BoardPalette.ink, hovered ? 0.8 : 0.45)) ?? .secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        layer.contentsScale = scale
        layer.contents = image?.layerContents(forContentsScale: scale)
    }
}

extension CardMetrics {
    /// Where a terminal card shows its terminal: under the title bar, and under the strip on runners.
    static func terminal(of record: AgentRecord) -> CGRect {
        record.runner == nil ? content(of: record.frame) : RunnerChromeLayout.terminal(in: record.frame)
    }
}
