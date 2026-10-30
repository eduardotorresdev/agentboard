import AgentRuntime
import AppKit
import Metal
import Orchestration
import QuartzCore
import SwiftUI
import TerminalCore
import TerminalRenderer

/// One card's terminal outside the board, live and typed into: the session is drawn at its own
/// columns and rows and scaled to fit, so showing it here never resizes the agent's screen.
struct LiveTerminal: NSViewRepresentable {
    let store: AgentStore
    let record: AgentRecord
    /// A bare Esc closes what shows the terminal instead of reaching the agent, where it would
    /// interrupt its turn; ⌥Esc sends one.
    var onEscape: (() -> Void)?
    /// Takes the keyboard when shown; off for a card that is leaving.
    var takesFocus = true

    func makeNSView(context: Context) -> LiveTerminalView {
        LiveTerminalView(store: store)
    }

    func updateNSView(_ view: LiveTerminalView, context: Context) {
        view.onEscape = onEscape
        view.takesFocus = takesFocus
        view.show(record)
    }

    static func dismantleNSView(_ view: LiveTerminalView, coordinator: ()) {
        view.show(nil)
    }
}

final class LiveTerminalView: NSView, NSTextInputClient {
    private let store: AgentStore
    private let presenter: TerminalPresenter?
    private let theme = TerminalTheme.light
    private let metal = CAMetalLayer()
    private let cursor = CALayer()
    private var glyphs: GlyphCache?
    private var terminal: TerminalLayer?
    private var record: AgentRecord?
    private var marked = ""
    private var scrollRemainder: CGFloat = 0
    var onEscape: (() -> Void)?
    var takesFocus = true
    private static let fontSize: CGFloat = 12

    init(store: AgentStore) {
        self.store = store
        presenter = MTLCreateSystemDefaultDevice().flatMap { TerminalPresenter(device: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = BoardPalette.card
        layer?.masksToBounds = true
        metal.device = presenter?.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = true
        metal.anchorPoint = .zero
        metal.addSublayer(cursor)
        cursor.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.55)
        cursor.isHidden = true
        layer?.addSublayer(metal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var session: AgentSession? { record.flatMap { store.sessions[$0.id] } }

    /// Shows `record`'s terminal, or nothing. Typing goes to it once the view has focus.
    func show(_ record: AgentRecord?) {
        guard record?.id != self.record?.id else { return }
        if let old = self.record {
            store.stopObserving(old.id, by: self)
        }
        self.record = record
        terminal = nil
        guard let record else { return }
        _ = store.session(for: record, cols: Self.columns(of: record, scale: scale), rows: Self.rows(of: record, scale: scale))
        store.observe(record.id, by: self) { [weak self] in self?.draw() }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            if self.takesFocus { window.makeFirstResponder(self) }
            self.draw()
        }
    }

    /// The size the board gives a new session for the card, so one first shown here matches it.
    private static func columns(of record: AgentRecord, scale: CGFloat) -> Int {
        max(2, Int(CardMetrics.terminal(of: record).width * scale) / cell(scale).width)
    }

    private static func rows(of record: AgentRecord, scale: CGFloat) -> Int {
        max(1, Int(CardMetrics.terminal(of: record).height * scale) / cell(scale).height)
    }

    private static func cell(_ scale: CGFloat) -> (width: Int, height: Int) {
        GlyphCache.cellSize(of: NSFont.monospacedSystemFont(ofSize: fontSize * scale, weight: .regular))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyphs = nil
        terminal = nil
        draw()
    }

    override func layout() {
        super.layout()
        draw()
    }

    private func draw() {
        guard let presenter, let session, window != nil else { return }
        if glyphs == nil {
            glyphs = GlyphCache(device: presenter.device, font: NSFont.monospacedSystemFont(ofSize: Self.fontSize * scale, weight: .regular))
        }
        guard let glyphs, !session.isMidUpdate else { return }
        let layer = terminal ?? TerminalLayer(device: presenter.device)
        terminal = layer
        presenter.beginFrame()
        session.withTerminalForDisplay { _ = layer.update(from: $0, theme: theme, glyphs: glyphs) }
        let pixels = CGSize(width: layer.cols * glyphs.cellWidth, height: layer.rows * glyphs.cellHeight)
        guard pixels.width > 0, pixels.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        // Fit the terminal's own size into the view, never past 1:1.
        let natural = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        // Never below 0.85, or the text stops being readable: the top rows clip instead.
        let fit = max(min(bounds.width / natural.width, bounds.height / natural.height, 1), 0.85)
        let size = CGSize(width: natural.width * fit, height: natural.height * fit)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.drawableSize = pixels
        metal.contentsScale = scale
        // Too large for the view, it is cut at the top and the right: the latest rows (the
        // prompt, the question) and the start of each line stay in view.
        metal.frame = CGRect(x: max(0, (bounds.width - size.width) / 2), y: min(0, bounds.height - size.height),
                             width: size.width, height: size.height)
        if let drawable = metal.nextDrawable() {
            presenter.render([TerminalPresenter.Target(layer: layer, texture: drawable.texture, drawable: drawable)],
                             glyphs: glyphs, background: theme.clearColor)
        }
        let cell = CGSize(width: size.width / CGFloat(max(layer.cols, 1)), height: size.height / CGFloat(max(layer.rows, 1)))
        let state = layer.cursor
        let showsCursor = state.visible && session.state == .running && window?.firstResponder === self
            && state.row < layer.rows && state.column < layer.cols
        cursor.isHidden = !showsCursor
        if showsCursor {
            let x = CGFloat(state.column) * cell.width, y = CGFloat(state.row) * cell.height
            cursor.frame = switch state.shape {
            case .block: CGRect(x: x, y: y, width: cell.width, height: cell.height)
            case .underline: CGRect(x: x, y: y + cell.height - 2, width: cell.width, height: 2)
            case .bar: CGRect(x: x, y: y, width: 2, height: cell.height)
            }
        }
        CATransaction.commit()
    }

    override func becomeFirstResponder() -> Bool {
        sendFocus(true)
        DispatchQueue.main.async { [weak self] in self?.draw() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        sendFocus(false)
        DispatchQueue.main.async { [weak self] in self?.draw() }
        return true
    }

    private func sendFocus(_ focused: Bool) {
        guard let session, let bytes = session.withTerminal({ $0.encodeFocus(focused) }) else { return }
        session.send(bytes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Scrolls the program when it takes mouse input, as the board does over a focused card.
    override func scrollWheel(with event: NSEvent) {
        guard let session, let terminal, terminal.rows > 0, terminal.cols > 0, metal.frame.height > 0,
              session.withTerminal({ $0.wantsMouse }) else { return super.scrollWheel(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let line = metal.frame.height / CGFloat(terminal.rows)
        let column = min(max(Int((point.x - metal.frame.minX) / (metal.frame.width / CGFloat(terminal.cols))), 0), terminal.cols - 1)
        let row = min(max(Int((point.y - metal.frame.minY) / line), 0), terminal.rows - 1)
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * line
        while abs(scrollRemainder) >= line {
            let mouse = MouseEvent(kind: scrollRemainder > 0 ? .scrollUp : .scrollDown, button: 0, column: column, row: row,
                                   modifiers: BoardView.modifiers(event))
            if let bytes = session.withTerminal({ $0.encodeMouse(mouse) }) { session.send(bytes) }
            scrollRemainder -= scrollRemainder > 0 ? line : -line
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, hasMarkedText() {
            // Cancels a dead key's accent, as anywhere else.
            return unmarkText()
        }
        if event.keyCode == 53, let onEscape {
            if flags.isEmpty { return onEscape() }
            if flags == .option { return session.send(session.withTerminal { $0.encode(.escape) }) }
        }
        if let key = BoardView.terminalKey(event) {
            let modifiers = BoardView.modifiers(event)
            session.send(session.withTerminal { $0.encode(key, modifiers: modifiers) })
        } else if flags.contains(.control), let bytes = BoardView.controlKey(event) {
            session.send(bytes)
        } else {
            interpretKeyEvents([event])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "v", window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard let session, let text = NSPasteboard.general.string(forType: .string) else { return }
        session.send(session.withTerminal { $0.encodePaste(text) })
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""
        session?.send(Array(text.utf8))
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(metal.frame, to: nil)) ?? .zero
    }
}
