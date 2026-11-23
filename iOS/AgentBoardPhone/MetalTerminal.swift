import AgentRuntime
import Metal
import QuartzCore
import SwiftUI
import TerminalCore
import TerminalRenderer
import UIKit

/// A card's terminal drawn with the Mac's Metal renderer (TerminalRenderer), at the session's own
/// columns and rows, scaled to fit. It redraws only when the session changes and only while
/// `live`; `zoom` is how much larger than 1:1 it shows, so its glyphs are rasterized for that
/// size (the canvas passes it when a pinch ends, never per frame).
struct MetalTerminal: UIViewRepresentable {
    let session: AgentSession
    var live = true
    var zoom: CGFloat = 1
    var showsCursor = false

    func makeUIView(context: Context) -> MetalTerminalView { MetalTerminalView() }

    func updateUIView(_ view: MetalTerminalView, context: Context) {
        view.configure(session: session, live: live, zoom: zoom, showsCursor: showsCursor)
    }

    static func dismantleUIView(_ view: MetalTerminalView, coordinator: ()) {
        view.configure(session: nil, live: false, zoom: 1, showsCursor: false)
    }
}

final class MetalTerminalView: UIView {
    /// One device and pipeline for every terminal; glyph atlases per pixel size.
    private static let presenter = MTLCreateSystemDefaultDevice().flatMap { TerminalPresenter(device: $0) }
    private static var atlases: [Int: GlyphCache] = [:]
    static let fontSize: CGFloat = 12
    private let theme = TerminalTheme.light
    private let metal = CAMetalLayer()
    private let cursor = CALayer()
    private(set) var session: AgentSession?
    private var layerState: TerminalLayer?
    private(set) var live = false
    /// How many of the session's changes reached this view (a test reads it).
    private(set) var changes = 0
    /// Every view showing a session: the canvas card and the full-screen page share one, and a
    /// session has a single `onChange`, so it goes to all of them, not to whichever came last.
    private static var viewers: [ObjectIdentifier: NSHashTable<MetalTerminalView>] = [:]
    private var zoom: CGFloat = 1
    private var showsCursor = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surfaceUI
        clipsToBounds = true
        isUserInteractionEnabled = false
        metal.device = Self.presenter?.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = true
        metal.anchorPoint = .zero
        metal.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        cursor.backgroundColor = UIColor(Theme.accent).withAlphaComponent(0.55).cgColor
        cursor.isHidden = true
        metal.addSublayer(cursor)
        layer.addSublayer(metal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(session: AgentSession?, live: Bool, zoom: CGFloat, showsCursor: Bool) {
        // SwiftUI calls this on every board update; only a real change costs a frame.
        guard session !== self.session || live != self.live || abs(zoom - self.zoom) > 0.01 || showsCursor != self.showsCursor else { return }
        let previous = self.session
        if session !== previous {
            if let previous { Self.viewers[ObjectIdentifier(previous)]?.remove(self) }
            self.session = session
            layerState = nil
        }
        let rescaled = abs(zoom - self.zoom) > 0.01
        self.live = live
        self.zoom = zoom
        self.showsCursor = showsCursor
        if let previous, previous !== session { Self.watch(previous) }
        if let session {
            // Stored first: a class through `default:` is only read, never kept.
            let table = Self.viewers[ObjectIdentifier(session)] ?? .weakObjects()
            table.add(self)
            Self.viewers[ObjectIdentifier(session)] = table
            Self.watch(session)
        }
        if rescaled { layerState = nil }
        draw()
    }

    /// Observed while any view shows it live; each change redraws every one of them.
    private static func watch(_ session: AgentSession) {
        let key = ObjectIdentifier(session)
        let showing = { viewers[key]?.allObjects.filter { $0.session.map(ObjectIdentifier.init) == key && $0.live } ?? [] }
        if showing().isEmpty {
            viewers[key] = nil
            session.isObserved = false
            session.onChange = nil
        } else {
            session.isObserved = true
            session.onChange = { for view in showing() { view.changes += 1; view.draw() } }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        draw()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        draw()
    }

    /// Pixels per point the glyphs are drawn at: the screen's, times the zoom, within reason.
    private var rasterScale: CGFloat {
        (window?.screen.scale ?? 3) * min(max(zoom, 0.25), 3)
    }

    private func glyphs() -> GlyphCache? {
        guard let presenter = Self.presenter else { return nil }
        let size = Int((Self.fontSize * rasterScale).rounded())
        if let cached = Self.atlases[size] { return cached }
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular) as CTFont
        let atlas = GlyphCache(device: presenter.device, font: font)
        Self.atlases[size] = atlas
        return atlas
    }

    private func draw() {
        guard let presenter = Self.presenter, let session, window != nil, bounds.width > 0, bounds.height > 0,
              let glyphs = glyphs(), !session.isMidUpdate else { return }
        #if DEBUG
        DebugPerf.count("draw")
        #endif
        let state = layerState ?? TerminalLayer(device: presenter.device)
        layerState = state
        presenter.beginFrame()
        session.withTerminalForDisplay { _ = state.update(from: $0, theme: theme, glyphs: glyphs) }
        let pixels = CGSize(width: state.cols * glyphs.cellWidth, height: state.rows * glyphs.cellHeight)
        guard pixels.width > 0, pixels.height > 0 else { return }
        // The session's own size, fitted into the card: never resizes the agent's screen.
        let fit = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let size = CGSize(width: pixels.width * fit, height: pixels.height * fit)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.drawableSize = pixels
        metal.contentsScale = pixels.width / max(size.width, 1)
        metal.frame = CGRect(origin: .zero, size: size)
        if let drawable = metal.nextDrawable() {
            presenter.render([TerminalPresenter.Target(layer: state, texture: drawable.texture, drawable: drawable)],
                             glyphs: glyphs, background: theme.clearColor)
        }
        let cell = CGSize(width: size.width / CGFloat(max(state.cols, 1)), height: size.height / CGFloat(max(state.rows, 1)))
        let position = state.cursor
        let shown = showsCursor && position.visible && position.row < state.rows && position.column < state.cols
        cursor.isHidden = !shown
        if shown {
            let x = CGFloat(position.column) * cell.width, y = CGFloat(position.row) * cell.height
            cursor.frame = switch position.shape {
            case .block: CGRect(x: x, y: y, width: cell.width, height: cell.height)
            case .underline: CGRect(x: x, y: y + cell.height - 2, width: cell.width, height: 2)
            case .bar: CGRect(x: x, y: y, width: 2, height: cell.height)
            }
        }
        CATransaction.commit()
    }
}

extension Theme {
    static let surfaceUI = UIColor(surface)
}

#if DEBUG
/// Appends to Documents/term.txt, which `simctl get_app_container … data` reaches.
enum DebugTerm {
    /// Back to the start of the browsing stack (`-leaveAfterTyping`).
    static let leaveBoard = Notification.Name("debugLeaveBoard")
    static func log(_ line: String) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("term.txt") else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
#endif
