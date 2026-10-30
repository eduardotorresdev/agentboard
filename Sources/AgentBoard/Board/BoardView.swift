import AgentRuntime
import AppKit
import Connections
import Orchestration
import QuartzCore
import SwiftUI
import TerminalCore
import TerminalRenderer

/// Card geometry, in points.
enum CardMetrics {
    static let titleHeight: CGFloat = 34
    static let inset: CGFloat = 12
    static let radius: CGFloat = 14
    static let closeSize: CGFloat = 20
    static let resizeHandle: CGFloat = 18
    static let minimumSize = CGSize(width: 320, height: 180)
    /// Connection handles: drawn size, and the reach that grabs one (in world points).
    static let handleSize: CGFloat = 10
    static let handleReach: CGFloat = 10
    /// While a line is drawn, its end snaps to a handle this close, in screen points.
    static let snapDistance: CGFloat = 40

    static func content(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + inset, y: frame.minY + titleHeight,
               width: frame.width - inset * 2, height: frame.height - titleHeight - inset)
    }

    /// Where a card's connection handles sit: the middle of each side, in `Side` order.
    static func handles(of frame: CGRect) -> [CGPoint] {
        [CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.midY),
         CGPoint(x: frame.midX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.midY)]
    }

    static func close(of frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - inset - closeSize + 4, y: frame.minY + (titleHeight - closeSize) / 2,
               width: closeSize, height: closeSize)
    }
}

/// Board colors (sRGB).
enum BoardPalette {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let ink: UInt32 = 0x2E1F6B
    static let accent: UInt32 = 0x6E56CF
    static let secondary: UInt32 = 0xF76B15
    static let card = rgb(0xFFFFFF)
}

/// Lets SwiftUI chrome (the canvas toolbar) talk to the board.
@MainActor
@Observable
final class BoardController {
    @ObservationIgnored fileprivate weak var view: BoardView?
    /// The board's current zoom, 1 = actual size.
    fileprivate(set) var zoom: CGFloat = 1

    func add(_ provider: any AgentProvider) { view?.addAgent(provider) }
    func add(_ device: BrowserDevice) { view?.addBrowser(device) }
    func addNotes() { view?.addNotes() }
    /// The dialog that asks what a new runner runs is open.
    var addingRunner = false
    func addRunner(command: String, name: String?, directory: String?) { view?.addRunner(command: command, name: name, directory: directory) }
    /// A custom device being chosen, for a new browser card or an existing one.
    var deviceRequest: DeviceRequest?
    func editDevice(_ target: DeviceRequest.Target) { deviceRequest = DeviceRequest(target: target) }
    func apply(_ device: BrowserDevice, to target: DeviceRequest.Target) { view?.apply(device, to: target) }
    /// The import-data dialog, open for a card or for the worktree's default target.
    var importRequest: DeviceRequest?
    func importData(into target: DeviceRequest.Target) { importRequest = DeviceRequest(target: target) }
    func zoomIn() { view?.stepZoom(1) }
    func zoomOut() { view?.stepZoom(-1) }
    func resetZoom() { view?.animateZoom(to: 1) }
    func fitAgents() { view?.fitAgents() }
    /// Width of the canvas's leading edge covered by the floating sidebar, kept clear when fitting.
    var leadingInset: CGFloat = 0
}

struct DeviceRequest: Identifiable {
    enum Target: Equatable {
        case new
        case browser(UUID)
    }

    let id = UUID()
    let target: Target
}

struct Board: NSViewRepresentable {
    let store: AgentStore
    let browsers: BrowserStore
    let worktree: String
    let controller: BoardController

    func makeNSView(context: Context) -> BoardView {
        let view = BoardView(store: store, browsers: browsers)
        controller.view = view
        view.controller = controller
        return view
    }

    func updateNSView(_ view: BoardView, context: Context) {
        controller.view = view
        view.controller = controller
        view.worktree = worktree
        view.syncLayers()
    }

    static func dismantleNSView(_ view: BoardView, coordinator: ()) {
        view.releaseTerminals()
    }
}

/// The worktree canvas, built from Core Animation layers: the grid, the lines between cards, and
/// per card its chrome (background, shadow, title, cursor) and a layer showing its terminal.
///
/// Dragging from a card's handle to another card connects them; the line is routed around the
/// cards and never along another line, and a message between them shows travelling along it.
///
/// Cards live in world coordinates; the camera (pan and zoom) maps them to the screen as
/// `world × zoom + pan`. Zooming never resizes a terminal: columns and rows follow the card's
/// size at zoom 1, and once the zoom settles the terminals are redrawn at the new resolution.
///
/// Moving, panning, zooming, focusing or hovering only changes layer properties. The terminals on screen
/// live in one `SharedSurface`; a frame draws the ones whose screen changed, all in one render
/// pass, and each card's layer shows its region of the surface. Only
/// cards on screen hold a terminal layer and keep their session *observed*. Cards that scroll
/// out of view, belong to another worktree, or sit in a hidden window drop their layers and
/// stop notifying; their programs keep running and their terminals keep parsing.
final class BoardView: NSView, NSTextInputClient, NSTextFieldDelegate {
    private let store: AgentStore
    private let browsers: BrowserStore
    private let presenter: TerminalPresenter?
    private let surface: SharedSurface<UUID>?
    /// Glyphs at the backing scale times `renderZoom`.
    private var glyphs: GlyphCache?
    /// Cell size in pixels at zoom 1, which sets every terminal's columns and rows.
    private var baseCell: (width: Int, height: Int)?
    private let theme = TerminalTheme.light
    private static let fontSize: CGFloat = 12
    static let zoomRange: ClosedRange<CGFloat> = 0.25...2
    /// Stops the toolbar's zoom buttons go through.
    private static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]
    weak var controller: BoardController?

    private let root = CALayer()
    private let grid = GridLayer()
    private let linksLayer = CALayer()
    private let cardsLayer = CALayer()
    /// Above the cards: the line being drawn from a handle.
    private let overlayLayer = CALayer()
    private let linkPreview = CAShapeLayer()
    private var cards: [UUID: CardLayer] = [:]
    /// Runner cards' buttons, addresses and metrics, drawn over their `CardLayer`.
    private var runnerChrome: [UUID: RunnerChromeLayer] = [:]
    /// The runner control under the pointer.
    private var hoveredRunnerControl: (card: UUID, control: RunnerControl)?
    private var browserCards: [UUID: BrowserCardLayer] = [:]
    /// The browser control under the pointer.
    private var hoveredControl: (card: UUID, control: BrowserCardLayer.Control)?
    /// Browser card receiving the pointer while a button is held.
    private var pageCapture: UUID?
    /// The address field shown over a browser card's title bar while its address is edited.
    private var addressField: NSTextField?
    private var editingAddress: UUID?
    private var notesCards: [UUID: NotesCardLayer] = [:]
    /// How far each notes card's list is scrolled.
    fileprivate var notesScroll: [UUID: CGFloat] = [:]
    /// The notes control under the pointer, and the row it is over.
    fileprivate var hoveredNotes: (card: UUID, control: NotesControl?, row: UUID?)?
    /// The field a note is written in, over its notes card: a new note (nil entry) or one being rewritten.
    fileprivate var noteField: NSTextField?
    fileprivate var editingNote: (card: UUID, entry: UUID?)?
    private var links: [UUID: LinkLayer] = [:]
    private let router = ConnectorRouter()
    private var routes: [UUID: Route] = [:]
    /// What `routes` were laid out for; lines are rerouted only when it changes.
    private var routedFor: RouteInput?
    /// Cards whose terminal must be redrawn on the next display refresh.
    private var dirty: Set<UUID> = []
    /// Sessions told they are on screen.
    private var observed: Set<UUID> = []
    private var appearing: Set<UUID> = []
    private var displayLink: CADisplayLink?
    /// How often the board draws, and which changed cards go into each frame.
    private var pacer = FramePacer<UUID>()
    private var pace = FramePacer<UUID>.Pace.background

    var worktree = "" {
        didSet {
            guard worktree != oldValue else { return }
            endAddressEditing()
            endNoteEditing(commit: true)
            focusedID = nil
            cameraAnimation = nil
            releaseTerminals()
            if renderZoom != zoom {
                renderZoom = zoom
                glyphs = nil
            }
            // Called from a SwiftUI update: publish after it.
            DispatchQueue.main.async { [weak self] in self?.publishZoom() }
        }
    }
    private var pans: [String: CGPoint] = [:]
    private var pan: CGPoint {
        get { pans[worktree] ?? .zero }
        set { pans[worktree] = newValue }
    }
    private var zooms: [String: CGFloat] = [:]
    private var zoom: CGFloat {
        get { zooms[worktree] ?? 1 }
        set { zooms[worktree] = newValue }
    }
    /// The zoom terminals and card text are rasterized for. Trails `zoom` while it changes.
    private var renderZoom: CGFloat = 1
    private var sharpenWork: DispatchWorkItem?
    private var cameraAnimation: CameraAnimation?
    private var cameraLink: CADisplayLink?
    /// Where a drag on the empty canvas started, and the pan it started from.
    private var panDrag: (start: CGPoint, origin: CGPoint)?
    private var focusedID: UUID? {
        didSet {
            guard focusedID != oldValue else { return }
            if let oldValue { sendFocus(false, to: oldValue) }
            if let focusedID { sendFocus(true, to: focusedID) }
        }
    }
    private var hoveredClose: UUID?
    /// The card showing its connection handles, and the index of the handle under the pointer.
    private var hoveredCard: UUID?
    private var hoveredHandle: Int?
    /// The line under the pointer, which shows the knob that removes it.
    private var hoveredLink: UUID?
    /// A line being drawn from a card's handle toward another card.
    private var linkDrag: LinkDrag?
    private var interaction: Interaction?
    /// Card receiving mouse reports while a button is held.
    private var mouseCapture: UUID?
    private var scrollRemainder: CGFloat = 0

    private struct LinkDrag {
        let from: UUID
        let side: Side
        let start: CGPoint
        /// The pointer, or the handle it snapped to.
        var point: CGPoint
        var target: UUID?
        /// The target's handle the end snapped to; nil lets the router pick the side.
        var targetSide: Side?
    }

    private struct RouteInput: Equatable {
        let frames: [UUID: CGRect]
        let connections: [Connection]
    }

    private struct Interaction {
        enum Kind { case move, resize }
        let id: UUID
        let kind: Kind
        let start: CGPoint
        let frame: CGRect
    }

    init(store: AgentStore, browsers: BrowserStore) {
        self.store = store
        self.browsers = browsers
        presenter = MTLCreateSystemDefaultDevice().flatMap { TerminalPresenter(device: $0) }
        surface = presenter.map { SharedSurface(device: $0.device) }
        super.init(frame: .zero)
        root.isGeometryFlipped = true
        root.addSublayer(grid)
        // The camera transform scales about the top-left corner, not the center.
        for layer in [linksLayer, cardsLayer, overlayLayer] {
            layer.anchorPoint = .zero
            root.addSublayer(layer)
        }
        linkPreview.fillColor = nil
        linkPreview.strokeColor = BoardPalette.rgb(BoardPalette.accent, 0.8)
        linkPreview.lineWidth = 2
        linkPreview.lineCap = .round
        linkPreview.lineDashPattern = [5, 5]
        linkPreview.isHidden = true
        overlayLayer.addSublayer(linkPreview)
        layer = root
        wantsLayer = true
        store.onSessionChange = { [weak self] id in self?.sessionChanged(id) }
        store.onMessage = { [weak self] message in self?.showMessage(message) }
        store.onRunnersChange = { [weak self] in self?.syncLayers() }
        browsers.onPageChange = { [weak self] _ in self?.syncLayers() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyphs = nil
        baseCell = nil
        releaseTerminals()
        syncLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        displayLink?.invalidate()
        displayLink = nil
        cameraLink?.invalidate()
        cameraLink = nil
        cameraAnimation = nil
        guard let window else { return releaseTerminals() }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let link = displayLink(target: self, selector: #selector(refresh))
        link.isPaused = true
        pace = .background
        link.preferredFrameRateRange = Self.frameRate(pace)
        link.add(to: .main, forMode: .common)
        displayLink = link
        syncLayers()
    }

    @objc private func occlusionChanged() {
        if isOnScreen { syncLayers() } else { releaseTerminals() }
    }

    private var isOnScreen: Bool {
        #if BENCH
        if BenchScenario.background { return window != nil }
        #endif
        return window?.occlusionState.contains(.visible) ?? false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    /// Drops every terminal layer and stops observing sessions; the next sync brings back
    /// whatever is on screen then.
    func releaseTerminals() {
        for id in observed { store.sessions[id]?.isObserved = false }
        observed.removeAll()
        dirty.removeAll()
        cards.values.forEach { $0.detachTerminal() }
        surface?.release()
        displayLink?.isPaused = true
    }

    // MARK: Adding

    func addAgent(_ provider: any AgentProvider) {
        let size = CGSize(width: 640, height: 420)
        let count = store.agents(in: worktree).count
        let cascade = CGFloat(count % 6) * 28
        let center = world(CGPoint(x: bounds.midX, y: bounds.midY))
        let top = world(CGPoint(x: 0, y: 72)).y
        let origin = CGPoint(x: center.x - size.width / 2 + cascade,
                             y: max(top, center.y - size.height / 2) + cascade)
        let record = store.add(provider, to: worktree, at: origin)
        appearing.insert(record.id)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
    }

    func addRunner(command: String, name: String?, directory: String?) {
        let size = AgentRecord.runnerSize
        let count = store.runners(in: worktree).count
        let cascade = CGFloat(count % 6) * 28
        let center = world(CGPoint(x: bounds.midX, y: bounds.midY))
        let top = world(CGPoint(x: 0, y: 72)).y
        let origin = CGPoint(x: center.x - size.width / 2 + cascade, y: max(top, center.y - size.height / 2) + cascade)
        let record = store.addRunner(command: command, name: name, directory: directory, to: worktree, at: origin)
        appearing.insert(record.id)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
    }

    func addBrowser(_ device: BrowserDevice) {
        let scale = BrowserStore.initialScale(for: device)
        let size = BrowserStore.frame(for: device, at: .zero, scale: scale).size
        let count = browsers.browsers(in: worktree).count
        let cascade = CGFloat(count % 6) * 28
        let center = world(CGPoint(x: bounds.midX, y: bounds.midY))
        let top = world(CGPoint(x: 0, y: 72)).y
        let origin = CGPoint(x: center.x - size.width / 2 + cascade, y: max(top, center.y - size.height / 2) + cascade)
        let record = browsers.add(device, to: worktree, at: origin)
        appearing.insert(record.id)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
        beginAddressEditing(record.id)
    }

    func addNotes() {
        let size = NotesRecord.size
        let count = store.notes(in: worktree).count
        let cascade = CGFloat(count % 6) * 28
        let center = world(CGPoint(x: bounds.midX, y: bounds.midY))
        let top = world(CGPoint(x: 0, y: 72)).y
        let origin = CGPoint(x: center.x - size.width / 2 + cascade, y: max(top, center.y - size.height / 2) + cascade)
        let record = store.addNotes(to: worktree, at: origin)
        appearing.insert(record.id)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
    }

    // MARK: Layers

    private func prepareGlyphs() -> GlyphCache? {
        if glyphs == nil, let presenter {
            let font = NSFont.monospacedSystemFont(ofSize: Self.fontSize * scale * renderZoom, weight: .regular)
            glyphs = GlyphCache(device: presenter.device, font: font)
        }
        return glyphs
    }

    private var cellAtZoom1: (width: Int, height: Int) {
        if let baseCell { return baseCell }
        let cell = GlyphCache.cellSize(of: NSFont.monospacedSystemFont(ofSize: Self.fontSize * scale, weight: .regular))
        baseCell = cell
        return cell
    }

    /// Brings every layer in line with the store, the camera, focus and hover. Cheap: it only sets
    /// layer properties; terminals that need pixels are queued for the next display refresh.
    func syncLayers() {
        guard let glyphs = prepareGlyphs(), let presenter else { return }
        let scale = scale
        let renderScale = scale * renderZoom
        let base = cellAtZoom1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        root.contentsScale = scale
        grid.update(bounds: bounds, pan: pan, zoom: zoom, scale: scale)
        let camera = CATransform3DScale(CATransform3DMakeTranslation(pan.x, pan.y, 0), zoom, zoom, 1)
        for layer in [linksLayer, cardsLayer, overlayLayer] {
            layer.frame = bounds
            layer.sublayerTransform = camera
        }

        let records = store.agents(in: worktree)
        let ids = Set(records.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperlayer()
            cards[id] = nil
            runnerChrome[id] = nil
            dirty.remove(id)
        }
        let onScreen = isOnScreen
        var visible = Set<UUID>()
        var sizes: [UUID: (width: Int, height: Int)] = [:]
        for (index, record) in records.enumerated() {
            let content = CardMetrics.terminal(of: record)
            let cols = max(2, Int(content.width * scale) / base.width)
            let rows = max(1, Int(content.height * scale) / base.height)
            let session = store.session(for: record, cols: cols, rows: rows)
            session.resize(cols: cols, rows: rows)

            let card = cards[record.id] ?? makeCard(record.id)
            card.zPosition = CGFloat(index)
            let state = session.state
            let message: String? = if record.runner != nil {
                runnerMessage(record, state: state)
            } else {
                switch state {
                case .starting, .running: nil
                case .exited, .stopped: L("Agent exited. Click to restart.")
                case .failed(let reason): reason
                }
            }
            card.contentTop = content.minY - record.frame.minY
            card.titleReserve = record.runner == nil ? 0 : RunnerChromeLayout.titleReserve
            card.update(frame: record.frame, title: record.name, state: state, focused: record.id == focusedID,
                        closeHovered: record.id == hoveredClose, starting: record.runner == nil ? L("Starting \(record.name)…") : "",
                        message: message, scale: renderScale)
            syncRunnerChrome(record, on: card, state: state, scale: renderScale)
            // While a line is drawn every card shows the handles it can snap to.
            let showsHandles = linkDrag != nil || record.id == hoveredCard
            let lit: Int? = if let linkDrag {
                linkDrag.from == record.id ? linkDrag.side.rawValue : linkDrag.target == record.id ? linkDrag.targetSide?.rawValue : nil
            } else {
                record.id == hoveredCard ? hoveredHandle : nil
            }
            card.updateHandles(visible: showsHandles, hovered: lit, linkTarget: linkDrag?.target == record.id)

            if onScreen, screen(record.frame).intersects(bounds) {
                visible.insert(record.id)
                // Sized at zoom 1; the pixels drawn at the render zoom stretch onto it.
                let size = CGSize(width: CGFloat(cols * base.width) / scale, height: CGFloat(rows * base.height) / scale)
                if card.attachTerminal(device: presenter.device, size: size, scale: renderScale) {
                    dirty.insert(record.id)
                }
                sizes[record.id] = (cols * glyphs.cellWidth, rows * glyphs.cellHeight)
            } else {
                card.detachTerminal()
                dirty.remove(record.id)
            }
        }
        syncNotes(scale: renderScale)
        syncBrowsers(onScreen: onScreen, scale: renderScale)
        syncLinks(scale: renderScale)
        // Terminals that got a new place in the surface are drawn there before they show again.
        if let surface { dirty.formUnion(surface.arrange(sizes)) }
        observe(visible)
        if !dirty.isEmpty { displayLink?.isPaused = false }
    }

    /// Browser cards sit above the agents, in their own stacking order.
    private func syncBrowsers(onScreen: Bool, scale: CGFloat) {
        let records = browsers.browsers(in: worktree)
        let ids = Set(records.map(\.id))
        for (id, card) in browserCards where !ids.contains(id) {
            card.removeFromSuperlayer()
            browserCards[id] = nil
        }
        if let editingAddress, !ids.contains(editingAddress) { endAddressEditing() }
        let below = CGFloat(store.agents(in: worktree).count + store.notes(in: worktree).count)
        for (index, record) in records.enumerated() {
            if onScreen { browsers.show(record.id) }
            let card = browserCards[record.id] ?? {
                let card = BrowserCardLayer()
                browserCards[record.id] = card
                cardsLayer.addSublayer(card)
                if appearing.remove(record.id) != nil { card.animateAppearance() }
                return card
            }()
            card.zPosition = below + CGFloat(index)
            card.update(frame: record.frame, record: record, page: browsers.pages[record.id], status: browsers.status(of: record.id),
                        focused: record.id == focusedID, hovered: hoveredControl?.card == record.id ? hoveredControl?.control : nil,
                        editingAddress: editingAddress == record.id, scale: scale)
            let showsHandles = linkDrag != nil || record.id == hoveredCard
            let lit: Int? = if let linkDrag {
                linkDrag.from == record.id ? linkDrag.side.rawValue : linkDrag.target == record.id ? linkDrag.targetSide?.rawValue : nil
            } else {
                record.id == hoveredCard ? hoveredHandle : nil
            }
            card.updateHandles(visible: showsHandles, hovered: lit, linkTarget: linkDrag?.target == record.id)
        }
        placeAddressField()
    }

    /// Every card of this worktree, agents, notes then browsers: bottom to top.
    private var itemFrames: [(id: UUID, frame: CGRect)] {
        store.agents(in: worktree).map { ($0.id, $0.frame) } + store.notes(in: worktree).map { ($0.id, $0.frame) }
            + browsers.browsers(in: worktree).map { ($0.id, $0.frame) }
    }

    /// The lines of this worktree, between any of its cards.
    private var worktreeConnections: [Connection] {
        store.connections(in: worktree, elements: Set(browsers.browsers(in: worktree).map(\.id)))
    }

    /// Lays out the lines between this worktree's cards (rerouting only when cards or lines
    /// changed) and the one being drawn.
    private func syncLinks(scale: CGFloat) {
        let connections = worktreeConnections
        let input = RouteInput(frames: Dictionary(uniqueKeysWithValues: itemFrames.map { ($0.id, $0.frame) }), connections: connections)
        if input != routedFor {
            routes = router.route(connections, around: input.frames)
            routedFor = input
        }
        let ids = Set(connections.map(\.id))
        for (id, link) in links where !ids.contains(id) {
            link.removeFromSuperlayer()
            links[id] = nil
        }
        if let hoveredLink, !ids.contains(hoveredLink) { self.hoveredLink = nil }
        for connection in connections {
            guard let route = routes[connection.id] else { continue }
            let link = links[connection.id] ?? {
                let link = LinkLayer()
                links[connection.id] = link
                linksLayer.addSublayer(link)
                return link
            }()
            link.update(route: route, hovered: connection.id == hoveredLink, scale: scale)
        }

        linkPreview.contentsScale = scale
        if let linkDrag {
            // The line being drawn is routed like a real one, after the others so they stay put:
            // what shows is where it lands.
            let route: Route? = if let target = linkDrag.target {
                { pending in router.route(connections + [pending], around: input.frames)[pending.id] }(
                    Connection(a: linkDrag.from, b: target, aSide: linkDrag.side, bSide: linkDrag.targetSide))
            } else {
                router.sketch(connections, around: input.frames, from: linkDrag.from, side: linkDrag.side, to: linkDrag.point)
            }
            linkPreview.path = LinkLayer.path(route?.points ?? [linkDrag.start, linkDrag.point])
            linkPreview.lineDashPattern = linkDrag.target == nil ? [5, 5] : nil
            linkPreview.strokeColor = BoardPalette.rgb(BoardPalette.accent, linkDrag.target == nil ? 0.7 : 0.95)
            linkPreview.isHidden = false
        } else {
            linkPreview.isHidden = true
        }
    }

    /// A message went along a line on this board: show it travel from sender to recipient.
    private func showMessage(_ message: Message) {
        guard let connection = worktreeConnections.first(where: { $0.joins(message.from, message.to) }),
              let route = routes[connection.id], isOnScreen else { return }
        links[connection.id]?.pulse(along: connection.a == message.from ? route : route.reversed)
    }

    private func makeCard(_ id: UUID) -> CardLayer {
        let card = CardLayer()
        cards[id] = card
        cardsLayer.addSublayer(card)
        if appearing.remove(id) != nil { card.animateAppearance() }
        return card
    }

    /// Starts observing sessions that came on screen and stops the ones that left.
    private func observe(_ visible: Set<UUID>) {
        for id in observed.subtracting(visible) { store.sessions[id]?.isObserved = false }
        for id in visible.subtracting(observed) {
            store.sessions[id]?.isObserved = true
            dirty.insert(id)
        }
        observed = visible
    }

    private func sessionChanged(_ id: UUID) {
        guard observed.contains(id) else { return }
        dirty.insert(id)
        // State changes (launched, exited) show in the chrome.
        if let card = cards[id], let state = store.sessions[id]?.state, card.state != state { syncLayers() }
        displayLink?.isPaused = false
    }

    /// The user acted on the board: draw at full rate for a moment.
    private func interacted() {
        pacer.interacted(at: CACurrentMediaTime())
        setPace(pacer.pace(at: CACurrentMediaTime()))
    }

    private func setPace(_ newPace: FramePacer<UUID>.Pace) {
        guard newPace != pace else { return }
        pace = newPace
        displayLink?.preferredFrameRateRange = Self.frameRate(newPace)
    }

    private static func frameRate(_ pace: FramePacer<UUID>.Pace) -> CAFrameRateRange {
        let rate = pace.frameRate
        return CAFrameRateRange(minimum: rate.minimum, maximum: rate.maximum, preferred: rate.preferred)
    }

    /// Display refresh: redraws the terminals that changed, each into its own drawable. The
    /// focused card is drawn on every refresh; the others together, at the background rate.
    @objc private func refresh() {
        let now = CACurrentMediaTime()
        setPace(pacer.pace(at: now))
        guard let presenter, let surface, let glyphs, !dirty.isEmpty else {
            displayLink?.isPaused = true
            return
        }
        #if BENCH
        if let id = BenchScenario.cardToFocus(among: dirty) { focusedID = id }
        #endif
        pacer.focused = focusedID
        let (due, later) = pacer.select(dirty, at: now)
        guard !due.isEmpty else { return }
        presenter.beginFrame()
        let generation = glyphs.generation
        var targets: [TerminalPresenter.Target] = []
        var drawn: [(id: UUID, buffer: Int)] = []
        var pending = later
        for id in due {
            guard let card = cards[id], card.content != nil, let layer = card.terminal, let session = store.sessions[id],
                  let target = surface.target(for: id) else { continue }
            // Keep showing the last complete frame while the program is mid-way through one.
            if session.isMidUpdate {
                pending.insert(id)
                continue
            }
            session.withTerminalForDisplay { _ = layer.update(from: $0, theme: theme, glyphs: glyphs) }
            targets.append(TerminalPresenter.Target(layer: layer, texture: target.texture, origin: SIMD2(target.region.x, target.region.y)))
            drawn.append((id, target.buffer))
        }
        // The cards switch to their new pixels once the GPU has drawn them: a fraction of a
        // millisecond, and it spares a completion handler and one present per card.
        presenter.render(targets, glyphs: glyphs, background: theme.clearColor)?.waitUntilCompleted()
        let base = cellAtZoom1
        let cell = CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, buffer) in drawn {
            guard let card = cards[id], let layer = card.terminal else { continue }
            surface.show(id, from: buffer, on: card.buffers)
            card.showCursor(layer.cursor, enabled: id == focusedID && store.sessions[id]?.state == .running, cell: cell)
        }
        CATransaction.commit()
        dirty = pending
        // A full atlas was reset mid-frame: terminals drawn before the reset hold stale slots.
        if glyphs.generation != generation { dirty.formUnion(observed) }
        if dirty.isEmpty { displayLink?.isPaused = true }
    }

    // MARK: Camera

    private func world(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.x) / zoom, y: (point.y - pan.y) / zoom)
    }

    private func screen(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * zoom + pan.x, y: rect.minY * zoom + pan.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Zooms keeping the world point under `anchor` (a view point) where it is.
    private func setZoom(_ value: CGFloat, anchor: CGPoint) {
        let value = clampZoom(value)
        guard value != zoom else { return }
        let fixed = world(anchor)
        setCamera(Camera(zoom: value, pan: CGPoint(x: anchor.x - fixed.x * value, y: anchor.y - fixed.y * value)))
    }

    private func setCamera(_ camera: Camera) {
        zoom = camera.zoom
        pan = camera.pan
        interacted()
        syncLayers()
        publishZoom()
        scheduleSharpen()
    }

    private func publishZoom() {
        if let controller, controller.zoom != zoom { controller.zoom = zoom }
    }

    /// Moves to the next zoom stop in `direction` (+1 in, -1 out), around the view's center.
    func stepZoom(_ direction: Int) {
        let current = cameraAnimation?.target.zoom ?? zoom
        let next = direction > 0 ? Self.zoomSteps.first { $0 > current + 0.001 } : Self.zoomSteps.last { $0 < current - 0.001 }
        animateZoom(to: next ?? current)
    }

    /// Springs the zoom to `target` around `anchor`, the view's center by default.
    func animateZoom(to target: CGFloat, anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let target = clampZoom(target)
        let fixed = world(anchor)
        animateCamera(to: Camera(zoom: target, pan: CGPoint(x: anchor.x - fixed.x * target, y: anchor.y - fixed.y * target)))
    }

    /// Springs the camera to frame every agent in the worktree, never past actual size.
    func fitAgents() {
        let frames = itemFrames.map(\.frame)
        guard let first = frames.first else { return animateCamera(to: Camera(zoom: 1, pan: .zero)) }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        // A margin around the cards, larger at the bottom where the toolbars float and clear of the sidebar.
        let inset = controller?.leadingInset ?? 0
        let area = CGRect(x: 48 + inset, y: 48, width: bounds.width - 96 - inset, height: bounds.height - 48 - 96)
        guard area.width > 0, area.height > 0 else { return }
        let target = clampZoom(min(area.width / union.width, area.height / union.height, 1))
        animateCamera(to: Camera(zoom: target, pan: CGPoint(x: area.midX - union.midX * target, y: area.midY - union.midY * target)))
    }

    private func animateCamera(to target: Camera) {
        guard target != Camera(zoom: zoom, pan: pan) || cameraAnimation != nil else { return }
        cameraAnimation = CameraAnimation(target: target, velocity: cameraAnimation?.velocity ?? .still, time: nil)
        if cameraLink == nil {
            let link = displayLink(target: self, selector: #selector(stepCameraAnimation(_:)))
            link.add(to: .main, forMode: .common)
            cameraLink = link
        }
        cameraLink?.isPaused = false
    }

    @objc private func stepCameraAnimation(_ link: CADisplayLink) {
        guard var animation = cameraAnimation else {
            link.isPaused = true
            return
        }
        let now = link.targetTimestamp
        let elapsed = animation.time.map { min(now - $0, 1.0 / 30) } ?? 1.0 / 120
        animation.time = now
        var camera = Camera(zoom: zoom, pan: pan)
        animation.step(&camera, by: elapsed)
        if animation.isSettled(camera) {
            cameraAnimation = nil
            link.isPaused = true
            setCamera(animation.target)
            sharpen()
        } else {
            cameraAnimation = animation
            setCamera(camera)
        }
    }

    /// Redraws terminals and card text at the current zoom once it stops changing.
    private func scheduleSharpen() {
        sharpenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sharpen() }
        sharpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func sharpen() {
        sharpenWork?.cancel()
        sharpenWork = nil
        guard cameraAnimation == nil, renderZoom != zoom, let presenter else { return }
        renderZoom = zoom
        glyphs = nil
        // Fresh terminal layers upload every cell against the new atlas; the cards keep
        // showing their last frame, stretched, until the sharp one is drawn.
        cards.values.forEach { $0.renewTerminal(device: presenter.device) }
        syncLayers()
    }

    override func magnify(with event: NSEvent) {
        cameraAnimation = nil
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
        if event.phase == .ended || event.phase == .cancelled { sharpen() }
    }

    /// Two-finger double tap: in to 150% around the pointer, or back to 100%.
    override func smartMagnify(with event: NSEvent) {
        animateZoom(to: abs(zoom - 1) < 0.01 ? 1.5 : 1, anchor: convert(event.locationInWindow, from: nil))
    }

    // MARK: Pointer

    /// The topmost agent card under a world point, unless a browser or notes card covers it.
    private func card(at point: CGPoint) -> AgentRecord? {
        guard browser(at: point) == nil, notesCard(at: point) == nil else { return nil }
        return store.agents(in: worktree).last { $0.frame.contains(point) }
    }

    /// The topmost browser card under a world point.
    private func browser(at point: CGPoint) -> BrowserRecord? {
        browsers.browsers(in: worktree).last { $0.frame.contains(point) }
    }

    /// The topmost notes card under a world point, unless a browser card covers it.
    fileprivate func notesCard(at point: CGPoint) -> NotesRecord? {
        guard browser(at: point) == nil else { return nil }
        return store.notes(in: worktree).last { $0.frame.contains(point) }
    }

    /// The topmost card of any kind under a world point.
    private func item(at point: CGPoint) -> UUID? {
        browser(at: point)?.id ?? notesCard(at: point)?.id ?? card(at: point)?.id
    }

    private func frame(of id: UUID) -> CGRect? {
        record(id)?.frame ?? store.notesRecord(id)?.frame ?? browsers.record(id)?.frame
    }

    private func record(_ id: UUID) -> AgentRecord? {
        store.agents.first { $0.id == id }
    }

    /// The cell under a world point in a card's terminal, clamped to the grid.
    private func cell(at point: CGPoint, in record: AgentRecord) -> (column: Int, row: Int)? {
        guard let layer = cards[record.id]?.terminal, layer.cols > 0, layer.rows > 0 else { return nil }
        let content = CardMetrics.terminal(of: record)
        let base = cellAtZoom1
        let column = Int((point.x - content.minX) * scale) / base.width
        let row = Int((point.y - content.minY) * scale) / base.height
        return (min(max(column, 0), layer.cols - 1), min(max(row, 0), layer.rows - 1))
    }

    private static func modifiers(_ event: NSEvent) -> KeyModifiers {
        let flags = event.modifierFlags
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// Sends a mouse report to a card's program when it asked for mouse input.
    @discardableResult
    private func report(_ kind: MouseEvent.Kind, button: Int = 0, at point: CGPoint, to record: AgentRecord,
                        event: NSEvent) -> Bool {
        guard let session = store.sessions[record.id], let cell = cell(at: point, in: record) else { return false }
        let mouse = MouseEvent(kind: kind, button: button, column: cell.column, row: cell.row, modifiers: Self.modifiers(event))
        guard let bytes = session.withTerminal({ $0.wantsMouse ? $0.encodeMouse(mouse) : nil }) else { return false }
        session.send(bytes)
        return true
    }

    /// The handle under a world point: on the hovered card, or on the one the pointer is over.
    private func handle(at point: CGPoint) -> (card: UUID, index: Int)? {
        let reach = max(CardMetrics.handleReach, 8 / zoom)
        let hovered = hoveredCard.flatMap { id in frame(of: id).map { (id: id, frame: $0) } }
        let candidates = [hovered].compactMap { $0 } + itemFrames.reversed()
        for item in candidates {
            if let index = CardMetrics.handles(of: item.frame).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= reach }) {
                return (item.id, index)
            }
        }
        return nil
    }

    /// The closest handle of another card within snapping distance of a world point.
    private func snapHandle(near point: CGPoint, excluding source: UUID) -> (card: UUID, side: Side, point: CGPoint)? {
        let reach = CardMetrics.snapDistance / zoom
        var best: (card: UUID, side: Side, point: CGPoint, distance: CGFloat)?
        for item in itemFrames where item.id != source {
            for (index, handle) in CardMetrics.handles(of: item.frame).enumerated() {
                let distance = hypot(handle.x - point.x, handle.y - point.y)
                if distance <= reach, distance < best?.distance ?? .infinity, let side = Side(rawValue: index) {
                    best = (item.id, side, handle, distance)
                }
            }
        }
        return best.map { ($0.card, $0.side, $0.point) }
    }

    /// The line under a world point, if no card is.
    private func link(at point: CGPoint) -> UUID? {
        guard item(at: point) == nil else { return nil }
        let reach = max(6, 6 / zoom)
        return worktreeConnections.first { routes[$0.id].map { $0.distance(to: point) <= reach } ?? false }?.id
    }

    override func mouseDown(with event: NSEvent) {
        interacted()
        let point = convert(event.locationInWindow, from: nil)
        let location = world(point)
        window?.makeFirstResponder(self)
        if let hoveredCard, let (id, index) = handle(at: location), id == hoveredCard,
           let frame = frame(of: id) {
            // Drawing a line from this card.
            let start = CardMetrics.handles(of: frame)[index]
            linkDrag = LinkDrag(from: id, side: Side(rawValue: index) ?? .right, start: start, point: location)
            NSCursor.crosshair.push()
            syncLayers()
            return
        }
        if let id = hoveredLink, let link = links[id], link.knobContains(location, zoom: zoom) {
            store.disconnect(id)
            hoveredLink = nil
            syncLayers()
            return
        }
        if let browser = browser(at: location) {
            endAddressEditing()
            endNoteEditing(commit: true)
            browserMouseDown(browser, at: location, event: event)
            syncLayers()
            return
        }
        endAddressEditing()
        if let notes = notesCard(at: location) {
            notesMouseDown(notes, at: location, event: event)
            syncLayers()
            return
        }
        endNoteEditing(commit: true)
        let previousFocus = focusedID
        defer {
            // The cursor shows only on the focused card.
            for id in [previousFocus, focusedID].compactMap({ $0 }) where observed.contains(id) { dirty.insert(id) }
            if !dirty.isEmpty { displayLink?.isPaused = false }
        }
        guard let record = card(at: location) else {
            // Dragging the empty canvas pans it.
            focusedID = nil
            beginPanDrag(at: point)
            syncLayers()
            return
        }
        let frame = record.frame
        // The resize corner keeps its size on screen at any zoom.
        let handle = CardMetrics.resizeHandle / zoom
        let wasFocused = focusedID == record.id
        focusedID = record.id
        store.raise(record.id)
        if let control = runnerControl(at: location, in: record) {
            perform(control, on: record)
        } else if CardMetrics.close(of: frame).contains(location) {
            store.remove(record.id)
            observed.remove(record.id)
            focusedID = nil
        } else if location.x > frame.maxX - handle && location.y > frame.maxY - handle {
            interaction = Interaction(id: record.id, kind: .resize, start: point, frame: record.frame)
        } else if location.y < CardMetrics.terminal(of: record).minY {
            // The title bar, and a runner's strip, move the card.
            interaction = Interaction(id: record.id, kind: .move, start: point, frame: record.frame)
        } else if record.runner != nil, store.runnerStarts[record.id] == nil, store.sessions[record.id]?.processID == nil {
            // A runner that hasn't run since launch starts with a click, like an exited agent.
            store.startRunner(record.id)
        } else if record.runner == nil, let state = store.sessions[record.id]?.state, state != .running, state != .starting {
            store.restart(record)
        } else if wasFocused, CardMetrics.terminal(of: record).contains(location), report(.press, at: location, to: record, event: event) {
            // The first click only focuses the card; later ones go to the program if it wants them.
            mouseCapture = record.id
        }
        syncLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        interacted()
        let point = convert(event.locationInWindow, from: nil)
        if let id = mouseCapture, let record = record(id) {
            report(.drag, at: world(point), to: record, event: event)
            return
        }
        if let id = pageCapture, let record = browsers.record(id) {
            let page = pagePoint(world(point), in: record)
            browsers.input(id, ["kind": "move", "x": page.x, "y": page.y])
            return
        }
        if panDrag != nil { return continuePanDrag(to: point) }
        if var drag = linkDrag {
            let location = world(point)
            let snap = snapHandle(near: location, excluding: drag.from)
            drag.point = snap?.point ?? location
            drag.target = snap?.card ?? item(at: location).flatMap { $0 == drag.from ? nil : $0 }
            drag.targetSide = snap?.side
            linkDrag = drag
            return syncLayers()
        }
        guard let interaction else { return }
        let dx = (point.x - interaction.start.x) / zoom, dy = (point.y - interaction.start.y) / zoom
        var frame = interaction.frame
        switch interaction.kind {
        case .move:
            frame.origin.x += dx
            frame.origin.y += dy
        case .resize:
            if let record = browsers.record(interaction.id) {
                frame = Self.browserFrame(resizing: frame, by: CGSize(width: dx, height: dy), device: record.device)
            } else {
                frame.size.width = max(CardMetrics.minimumSize.width, frame.width + dx)
                frame.size.height = max(CardMetrics.minimumSize.height, frame.height + dy)
            }
        }
        setFrame(frame.integral, for: interaction.id, persist: false)
        syncLayers()
    }

    override func mouseUp(with event: NSEvent) {
        if let id = mouseCapture {
            mouseCapture = nil
            if let record = record(id) { report(.release, at: world(convert(event.locationInWindow, from: nil)), to: record, event: event) }
            return
        }
        if let id = pageCapture {
            pageCapture = nil
            if let record = browsers.record(id) {
                let page = pagePoint(world(convert(event.locationInWindow, from: nil)), in: record)
                browsers.input(id, ["kind": "up", "x": page.x, "y": page.y, "clickCount": event.clickCount,
                                    "modifiers": Self.pageModifiers(event)])
            }
            return
        }
        if panDrag != nil { return endPanDrag() }
        if let drag = linkDrag {
            linkDrag = nil
            NSCursor.pop()
            if let target = drag.target { store.connect(drag.from, target, sides: (drag.side, drag.targetSide)) }
            return syncLayers()
        }
        guard let interaction, let frame = frame(of: interaction.id) else { return }
        setFrame(frame, for: interaction.id, persist: true)
        self.interaction = nil
    }

    /// The middle button pans from anywhere, over cards too.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        interacted()
        beginPanDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard panDrag != nil else { return super.otherMouseDragged(with: event) }
        interacted()
        continuePanDrag(to: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard panDrag != nil else { return super.otherMouseUp(with: event) }
        endPanDrag()
    }

    private func beginPanDrag(at point: CGPoint) {
        guard panDrag == nil else { return }
        cameraAnimation = nil
        panDrag = (point, pan)
        NSCursor.closedHand.push()
    }

    private func continuePanDrag(to point: CGPoint) {
        guard let drag = panDrag else { return }
        pan = CGPoint(x: drag.origin.x + point.x - drag.start.x, y: drag.origin.y + point.y - drag.start.y)
        syncLayers()
    }

    private func endPanDrag() {
        panDrag = nil
        NSCursor.pop()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = world(convert(event.locationInWindow, from: nil))
        var hovered: UUID?
        let card = card(at: point)
        if let card, CardMetrics.close(of: card.frame).contains(point) {
            hovered = card.id
        }
        let browser = browser(at: point)
        let control = browser.flatMap { record in Self.control(at: point, in: record).map { (record.id, $0) } }
        if let browser, browser.id == focusedID, BrowserCardLayout(frame: browser.frame, record: browser).content.contains(point) {
            // Hover effects on the page follow the pointer while its card is focused.
            let page = pagePoint(point, in: browser)
            browsers.input(browser.id, ["kind": "move", "x": page.x, "y": page.y])
        }
        let notes = notesCard(at: point)
        let notesHover = notes.map { record in
            (card: record.id, control: notesLayout(record).control(at: local(point, in: record.frame), scroll: notesScroll[record.id] ?? 0),
             row: notesRow(at: point, in: record))
        }
        if notesHover?.card != hoveredNotes?.card || notesHover?.control != hoveredNotes?.control || notesHover?.row != hoveredNotes?.row {
            hoveredNotes = notesHover
            syncLayers()
        }
        let handle = handle(at: point)
        let showing = handle?.card ?? browser?.id ?? notes?.id ?? card?.id
        if control?.0 != hoveredControl?.card || control?.1 != hoveredControl?.control {
            hoveredControl = control.map { (card: $0.0, control: $0.1) }
            syncLayers()
        }
        let runnerControl = card.flatMap { record in self.runnerControl(at: point, in: record).map { (card: record.id, control: $0) } }
        if runnerControl?.card != hoveredRunnerControl?.card || runnerControl?.control != hoveredRunnerControl?.control {
            hoveredRunnerControl = runnerControl
            syncLayers()
        }
        // Over a line's knob the line stays hovered, even where the knob overhangs a card.
        let link = hoveredLink.flatMap { links[$0]?.knobContains(point, zoom: zoom) == true ? $0 : nil } ?? (handle == nil ? self.link(at: point) : nil)
        guard hovered != hoveredClose || showing != hoveredCard || handle?.index != hoveredHandle || link != hoveredLink else { return }
        hoveredClose = hovered
        hoveredCard = showing
        hoveredHandle = handle?.index
        hoveredLink = link
        syncLayers()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredClose != nil || hoveredCard != nil || hoveredLink != nil || hoveredControl != nil || hoveredRunnerControl != nil
                || hoveredNotes != nil else { return }
        hoveredNotes = nil
        hoveredControl = nil
        hoveredRunnerControl = nil
        hoveredClose = nil
        hoveredCard = nil
        hoveredHandle = nil
        hoveredLink = nil
        syncLayers()
    }

    /// Scrolling with ⌘ zooms around the pointer. Otherwise, over the focused card's terminal it
    /// scrolls the program when it takes mouse input; anywhere else it pans the board.
    override func scrollWheel(with event: NSEvent) {
        interacted()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            cameraAnimation = nil
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            setZoom(zoom * exp(delta), anchor: point)
            return
        }
        let location = world(point)
        if let id = focusedID, let record = browsers.record(id), browser(at: location)?.id == id,
           BrowserCardLayout(frame: record.frame, record: record).content.contains(location) {
            let page = pagePoint(location, in: record)
            let factor = (event.hasPreciseScrollingDeltas ? 1 : 10) / pageScale(of: record)
            browsers.input(id, ["kind": "wheel", "x": page.x, "y": page.y,
                                "dx": -event.scrollingDeltaX * factor, "dy": -event.scrollingDeltaY * factor])
            return
        }
        if let notes = notesCard(at: location), scrollNotes(notes, by: event) { return }
        if let id = focusedID, let record = record(id), card(at: location)?.id == id,
           CardMetrics.terminal(of: record).contains(location),
           store.sessions[id]?.withTerminal({ $0.wantsMouse }) == true {
            let line = CGFloat(cellAtZoom1.height) / scale * zoom
            scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * line
            while abs(scrollRemainder) >= line {
                report(scrollRemainder > 0 ? .scrollUp : .scrollDown, at: location, to: record, event: event)
                scrollRemainder -= scrollRemainder > 0 ? line : -line
            }
            return
        }
        cameraAnimation = nil
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        pan.x += event.scrollingDeltaX * factor
        pan.y += event.scrollingDeltaY * factor
        syncLayers()
    }

    // MARK: Keyboard

    private var focusedSession: AgentSession? {
        focusedID.flatMap { store.sessions[$0] }
    }

    private func sendFocus(_ focused: Bool, to id: UUID) {
        guard let session = store.sessions[id], let bytes = session.withTerminal({ $0.encodeFocus(focused) }) else { return }
        session.send(bytes)
    }

    override func keyDown(with event: NSEvent) {
        if let id = focusedBrowser { return browserKeyDown(event, to: id) }
        guard let session = focusedSession else { return super.keyDown(with: event) }
        interacted()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let key = Self.terminalKey(event) {
            let modifiers = Self.modifiers(event)
            session.send(session.withTerminal { $0.encode(key, modifiers: modifiers) })
        } else if flags.contains(.control), let bytes = Self.controlKey(event) {
            session.send(bytes)
        } else {
            interpretKeyEvents([event])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let id = focusedBrowser, window?.firstResponder === self, browserKeyEquivalent(event, to: id) { return true }
        if flags == .command, event.charactersIgnoringModifiers == "v", focusedSession != nil, window?.firstResponder === self {
            paste(nil)
            return true
        }
        if flags.subtracting(.shift) == .command, window?.firstResponder === self {
            switch event.charactersIgnoringModifiers {
            case "=", "+": stepZoom(1)
            case "-": stepZoom(-1)
            case "0": animateZoom(to: 1)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard let session = focusedSession, let text = NSPasteboard.general.string(forType: .string) else { return }
        interacted()
        session.send(session.withTerminal { $0.encodePaste(text) })
    }

    private static func terminalKey(_ event: NSEvent) -> TerminalKey? {
        switch event.keyCode {
        case 36, 76: .enter
        case 48: .tab
        case 51: .backspace
        case 53: .escape
        case 117: .delete
        case 114: .insert
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 115: .home
        case 119: .end
        case 116: .pageUp
        case 121: .pageDown
        case 122: .function(1)
        case 120: .function(2)
        case 99: .function(3)
        case 118: .function(4)
        case 96: .function(5)
        case 97: .function(6)
        case 98: .function(7)
        case 100: .function(8)
        case 101: .function(9)
        case 109: .function(10)
        case 103: .function(11)
        case 111: .function(12)
        default: nil
        }
    }

    private static func controlKey(_ event: NSEvent) -> [UInt8]? {
        guard let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first else { return nil }
        switch scalar {
        case "a"..."z": return [UInt8(scalar.value - 96)]
        case " ", "@": return [0]
        case "[": return [27]
        case "\\": return [28]
        case "]": return [29]
        default: return nil
        }
    }

    // MARK: NSTextInputClient

    private var marked = ""

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""
        if let id = focusedBrowser {
            browsers.input(id, ["kind": "text", "text": text])
            return
        }
        focusedSession?.send(Array(text.utf8))
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
        guard let id = focusedID, let record = record(id) else { return .zero }
        let content = screen(CardMetrics.terminal(of: record))
        return window?.convertToScreen(convert(content, to: nil)) ?? .zero
    }
}

// MARK: Runners

extension BoardView {
    /// What a runner card says over its terminal: a failure, or how to start one that hasn't run.
    fileprivate func runnerMessage(_ record: AgentRecord, state: AgentSession.State) -> String? {
        switch state {
        case .failed(let reason): reason
        case .stopped where store.runnerStarts[record.id] == nil: L("Not running. Click to start.")
        default: nil
        }
    }

    fileprivate func runnerLayout(_ record: AgentRecord, state: AgentSession.State) -> (RunnerChromeLayout, (text: String, attention: Bool)) {
        let session = store.sessions[record.id]
        let metrics = RunnerChromeLayer.metricsText(state: state, stats: store.runnerStats[record.id], exitCode: session?.exitCode)
        var links: [RunnerChromeLayout.Link] = []
        for url in store.urls(of: record.id) {
            links.append(.init(label: url.local.replacingOccurrences(of: "http://", with: ""), url: url.local, network: false))
            if let network = url.network {
                links.append(.init(label: network.replacingOccurrences(of: "http://", with: ""), url: network, network: true))
            }
        }
        let layout = RunnerChromeLayout(bounds: CGRect(origin: .zero, size: record.frame.size), command: record.runner?.command ?? "",
                                        links: links, metricsWidth: RunnerChromeLayer.metricsWidth(metrics.text))
        return (layout, metrics)
    }

    fileprivate func syncRunnerChrome(_ record: AgentRecord, on card: CALayer, state: AgentSession.State, scale: CGFloat) {
        guard let runner = record.runner else { return }
        let chrome = runnerChrome[record.id] ?? {
            let chrome = RunnerChromeLayer()
            chrome.zPosition = 5
            card.addSublayer(chrome)
            runnerChrome[record.id] = chrome
            return chrome
        }()
        let (layout, metrics) = runnerLayout(record, state: state)
        let running = state == .running || state == .starting
        chrome.update(bounds: CGRect(origin: .zero, size: record.frame.size), layout: layout, command: runner.command, running: running,
                      metrics: metrics, hovered: hoveredRunnerControl?.card == record.id ? hoveredRunnerControl?.control : nil, scale: scale)
    }

    /// The runner control under a world point on a runner card.
    fileprivate func runnerControl(at point: CGPoint, in record: AgentRecord) -> RunnerControl? {
        guard record.runner != nil else { return nil }
        let state = store.sessions[record.id]?.state ?? .stopped
        let local = CGPoint(x: point.x - record.frame.minX, y: point.y - record.frame.minY)
        return runnerLayout(record, state: state).0.control(at: local)
    }

    fileprivate func perform(_ control: RunnerControl, on record: AgentRecord) {
        switch control {
        case .toggle:
            let state = store.sessions[record.id]?.state
            if state == .running || state == .starting { store.stopRunner(record.id) } else { store.startRunner(record.id) }
        case .restart:
            store.restartRunner(record.id)
        case .link(let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: Browsers

extension BoardView {
    fileprivate var focusedBrowser: UUID? {
        focusedID.flatMap { browsers.record($0)?.id }
    }

    fileprivate func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        if browsers.record(id) != nil {
            browsers.setFrame(frame, for: id, persist: persist)
        } else if store.notesRecord(id) != nil {
            store.setNotesFrame(frame, for: id, persist: persist)
        } else {
            store.setFrame(frame, for: id, persist: persist)
        }
    }

    /// Page pixels per board point at zoom 1.
    fileprivate func pageScale(of record: BrowserRecord) -> CGFloat {
        BrowserStore.scale(of: record)
    }

    /// A world point as CSS pixels on the card's page.
    fileprivate func pagePoint(_ point: CGPoint, in record: BrowserRecord) -> CGPoint {
        let content = CardMetrics.content(of: record.frame)
        let scale = pageScale(of: record)
        return CGPoint(x: ((point.x - content.minX) / scale).rounded(), y: ((point.y - content.minY) / scale).rounded())
    }

    /// Resizing keeps the page's proportions: the card always shows the whole viewport.
    fileprivate static func browserFrame(resizing frame: CGRect, by delta: CGSize, device: BrowserDevice) -> CGRect {
        let chrome = CGSize(width: CardMetrics.inset * 2, height: CardMetrics.titleHeight + CardMetrics.inset)
        let ratio = device.viewport.height / device.viewport.width
        let width = max(200, frame.width - chrome.width + max(delta.width, delta.height / ratio))
        return CGRect(x: frame.minX, y: frame.minY, width: width + chrome.width, height: (width * ratio).rounded() + chrome.height)
    }

    fileprivate static func control(at point: CGPoint, in record: BrowserRecord) -> BrowserCardLayer.Control? {
        let layout = BrowserCardLayout(frame: record.frame, record: record)
        if layout.device.contains(point) { return .device }
        if layout.back.contains(point) { return .back }
        if layout.forward.contains(point) { return .forward }
        if layout.reload.contains(point) { return .reload }
        if layout.close.contains(point) { return .close }
        return nil
    }

    fileprivate func browserMouseDown(_ record: BrowserRecord, at location: CGPoint, event: NSEvent) {
        let frame = record.frame
        let layout = BrowserCardLayout(frame: frame, record: record)
        focusedID = record.id
        browsers.raise(record.id)
        let handle = CardMetrics.resizeHandle / zoom
        switch Self.control(at: location, in: record) {
        case .close:
            browsers.remove(record.id)
            focusedID = nil
            hoveredControl = nil
        case .device: showDeviceMenu(for: record, below: layout.device)
        case .back: browsers.go("back", on: record.id)
        case .forward: browsers.go("forward", on: record.id)
        case .reload: browsers.go("reload", on: record.id)
        case nil:
            if location.x > frame.maxX - handle && location.y > frame.maxY - handle {
                interaction = Interaction(id: record.id, kind: .resize, start: convert(event.locationInWindow, from: nil), frame: frame)
            } else if layout.address.contains(location) {
                beginAddressEditing(record.id)
            } else if location.y < frame.minY + CardMetrics.titleHeight || !layout.content.contains(location) {
                interaction = Interaction(id: record.id, kind: .move, start: convert(event.locationInWindow, from: nil), frame: frame)
            } else if case .failed = browsers.pages[record.id]?.phase {
                browsers.reopen(record.id)
            } else {
                let page = pagePoint(location, in: record)
                browsers.input(record.id, ["kind": "down", "x": page.x, "y": page.y, "clickCount": event.clickCount,
                                           "modifiers": Self.pageModifiers(event)])
                pageCapture = record.id
            }
        }
    }

    /// The presets, checked when the card uses one, and Custom… for anything else.
    fileprivate func showDeviceMenu(for record: BrowserRecord, below chip: CGRect) {
        let menu = NSMenu()
        for device in BrowserDevice.presets {
            let item = NSMenuItem(title: L(String.LocalizationValue(device.title)), action: #selector(chooseDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DeviceChoice(browser: record.id, device: device)
            if #available(macOS 14.4, *) { item.subtitle = device.help }
            item.state = record.device == device ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: L("Custom…"), action: #selector(chooseDevice(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = DeviceChoice(browser: record.id, device: nil)
        if #available(macOS 14.4, *) { custom.subtitle = L("Choose the size, density, touch, and user agent.") }
        custom.state = BrowserDevice.presets.contains(record.device) ? .off : .on
        menu.addItem(custom)

        // The profile the card browses with: its logins, shared by cards on the same profile.
        menu.addItem(.separator())
        let header = NSMenuItem(title: L("Profile"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for profile in browsers.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(chooseProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ProfileChoice(browser: record.id, profile: profile.id, importData: false)
            item.state = record.profile == profile.id ? .on : .off
            menu.addItem(item)
        }
        let importData = NSMenuItem(title: L("Import data…"), action: #selector(chooseProfile(_:)), keyEquivalent: "")
        importData.target = self
        importData.representedObject = ProfileChoice(browser: record.id, profile: nil, importData: true)
        if #available(macOS 14.4, *) { importData.subtitle = L("Bring logins from Chrome, Arc, Edge…") }
        menu.addItem(importData)

        let anchor = screen(chip)
        menu.popUp(positioning: nil, at: CGPoint(x: anchor.minX, y: anchor.maxY + 4), in: self)
    }

    @objc fileprivate func chooseDevice(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? DeviceChoice else { return }
        if let device = choice.device {
            apply(device, to: .browser(choice.browser))
        } else {
            controller?.editDevice(.browser(choice.browser))
        }
    }

    @objc fileprivate func chooseProfile(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? ProfileChoice else { return }
        if let profile = choice.profile {
            browsers.setProfile(profile, for: choice.browser)
            syncLayers()
        } else {
            controller?.importData(into: .browser(choice.browser))
        }
    }

    func apply(_ device: BrowserDevice, to target: DeviceRequest.Target) {
        switch target {
        case .new: addBrowser(device)
        case .browser(let id):
            browsers.setDevice(device, for: id)
            syncLayers()
        }
    }

    /// Modifier keys held during a click, as Playwright names them.
    fileprivate static func pageModifiers(_ event: NSEvent) -> [String] {
        let flags = event.modifierFlags
        return [(NSEvent.ModifierFlags.shift, "Shift"), (.option, "Alt"), (.control, "Control"), (.command, "Meta")]
            .filter { flags.contains($0.0) }.map(\.1)
    }

    /// Playwright's name for a key that types no text (Enter, arrows…), with its modifiers.
    fileprivate static func pageKey(_ event: NSEvent) -> String? {
        let name: String? = switch event.keyCode {
        case 36, 76: "Enter"
        case 48: "Tab"
        case 51: "Backspace"
        case 53: "Escape"
        case 117: "Delete"
        case 123: "ArrowLeft"
        case 124: "ArrowRight"
        case 125: "ArrowDown"
        case 126: "ArrowUp"
        case 115: "Home"
        case 119: "End"
        case 116: "PageUp"
        case 121: "PageDown"
        default: nil
        }
        let flags = event.modifierFlags
        if let name {
            return (pageModifiers(event) + [name]).joined(separator: "+")
        }
        // Control and Command shortcuts go to the page as keys; anything else types text.
        guard flags.contains(.control) || flags.contains(.command),
              let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1 else { return nil }
        return (pageModifiers(event) + [character]).joined(separator: "+")
    }

    fileprivate func browserKeyDown(_ event: NSEvent, to id: UUID) {
        interacted()
        if let key = Self.pageKey(event) {
            browsers.input(id, ["kind": "key", "key": key])
        } else {
            interpretKeyEvents([event])
        }
    }

    /// The browser's own shortcuts; other ⌘ keys go to the page.
    fileprivate func browserKeyEquivalent(_ event: NSEvent, to id: UUID) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "l": beginAddressEditing(id)
        case "r": browsers.go("reload", on: id)
        case "[": browsers.go("back", on: id)
        case "]": browsers.go("forward", on: id)
        case "v":
            guard let text = NSPasteboard.general.string(forType: .string) else { return true }
            browsers.input(id, ["kind": "text", "text": text])
        case "c":
            Task {
                guard let text = await browsers.copySelection(id), !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "=", "+", "-", "0": return false
        default:
            guard let key = Self.pageKey(event) else { return false }
            browsers.input(id, ["kind": "key", "key": key])
        }
        return true
    }

    // MARK: Address

    fileprivate func beginAddressEditing(_ id: UUID) {
        guard let record = browsers.record(id) else { return }
        let field = addressField ?? {
            let field = NSTextField()
            field.font = BrowserCardLayout.addressFont
            field.focusRingType = .none
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.placeholderString = L("Search or enter an address")
            addressField = field
            return field
        }()
        editingAddress = id
        field.stringValue = browsers.pages[id]?.url.isEmpty == false ? browsers.pages[id]!.url : record.url
        if field.superview == nil { addSubview(field) }
        syncLayers()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    fileprivate func placeAddressField() {
        guard let field = addressField, let id = editingAddress, let record = browsers.record(id) else { return }
        let rect = screen(BrowserCardLayout(frame: record.frame, record: record).address)
        field.frame = CGRect(x: rect.minX, y: rect.midY - 11, width: max(120, rect.width), height: 22)
    }

    fileprivate func endAddressEditing() {
        guard let field = addressField, editingAddress != nil else { return }
        editingAddress = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        syncLayers()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === noteField { return noteField(doCommandBy: selector) }
        guard let id = editingAddress else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let address = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            endAddressEditing()
            if !address.isEmpty { browsers.navigate(id, to: address) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endAddressEditing()
            return true
        }
        return false
    }
}

// MARK: Notes

extension BoardView {
    fileprivate func notesLayout(_ record: NotesRecord) -> NotesCardLayout {
        let adding = editingNote.map { $0.card == record.id && $0.entry == nil } ?? false
        return NotesCardLayout(size: record.frame.size, record: record, adding: adding)
    }

    /// A world point in a card's own coordinates.
    fileprivate func local(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// The entry whose row is under a world point.
    fileprivate func notesRow(at point: CGPoint, in record: NotesRecord) -> UUID? {
        let layout = notesLayout(record)
        let card = local(point, in: record.frame)
        guard layout.content.contains(card) else { return nil }
        let list = CGPoint(x: card.x - layout.content.minX, y: card.y - layout.content.minY + (notesScroll[record.id] ?? 0))
        return layout.rows.first { $0.frame.contains(list) }?.entry.id
    }

    /// Notes cards sit above the agents and below the browsers, in their own stacking order.
    fileprivate func syncNotes(scale: CGFloat) {
        let records = store.notes(in: worktree)
        let ids = Set(records.map(\.id))
        for (id, card) in notesCards where !ids.contains(id) {
            card.removeFromSuperlayer()
            notesCards[id] = nil
            notesScroll[id] = nil
        }
        if let editing = editingNote, store.notesRecord(editing.card) == nil { endNoteEditing(commit: false) }
        let agentCount = CGFloat(store.agents(in: worktree).count)
        for (index, record) in records.enumerated() {
            let card = notesCards[record.id] ?? {
                let card = NotesCardLayer()
                notesCards[record.id] = card
                cardsLayer.addSublayer(card)
                if appearing.remove(record.id) != nil { card.animateAppearance() }
                return card
            }()
            let layout = notesLayout(record)
            let scroll = min(notesScroll[record.id] ?? 0, layout.maxScroll)
            notesScroll[record.id] = scroll
            let hover = hoveredNotes?.card == record.id ? hoveredNotes : nil
            card.zPosition = agentCount + CGFloat(index)
            card.update(frame: record.frame, record: record, layout: layout, scroll: scroll, focused: record.id == focusedID,
                        hovered: hover?.control, hoveredRow: hover?.row,
                        editing: editingNote?.card == record.id ? editingNote?.entry : nil,
                        adding: editingNote.map { $0.card == record.id && $0.entry == nil } ?? false, scale: scale)
            let showsHandles = linkDrag != nil || record.id == hoveredCard
            let lit: Int? = if let linkDrag {
                linkDrag.from == record.id ? linkDrag.side.rawValue : linkDrag.target == record.id ? linkDrag.targetSide?.rawValue : nil
            } else {
                record.id == hoveredCard ? hoveredHandle : nil
            }
            card.updateHandles(visible: showsHandles, hovered: lit, linkTarget: linkDrag?.target == record.id)
        }
        placeNoteField()
    }

    fileprivate func notesMouseDown(_ record: NotesRecord, at location: CGPoint, event: NSEvent) {
        let frame = record.frame
        let layout = notesLayout(record)
        let point = local(location, in: frame)
        focusedID = record.id
        store.raiseNotes(record.id)
        let handle = CardMetrics.resizeHandle / zoom
        let control = layout.control(at: point, scroll: notesScroll[record.id] ?? 0)
        // Clicking anywhere but the field being written in keeps what was written.
        if control != .add || editingNote?.card != record.id { endNoteEditing(commit: true) }
        switch control {
        case .close:
            store.removeNotes(record.id)
            focusedID = nil
            hoveredNotes = nil
        case .add:
            beginNoteEditing(on: record.id, entry: nil)
        case .delete(let entry):
            store.deleteNote(entry, on: record.id)
            hoveredNotes = nil
        case .entry(let entry):
            beginNoteEditing(on: record.id, entry: entry)
        case nil:
            if location.x > frame.maxX - handle && location.y > frame.maxY - handle {
                interaction = Interaction(id: record.id, kind: .resize, start: convert(event.locationInWindow, from: nil), frame: frame)
            } else if !layout.content.contains(point) || notesRow(at: location, in: record) == nil {
                // The title bar and the space around the list move the card.
                interaction = Interaction(id: record.id, kind: .move, start: convert(event.locationInWindow, from: nil), frame: frame)
            }
        }
    }

    /// Scrolls a notes card's list when it overflows; false when it doesn't, so the board pans.
    fileprivate func scrollNotes(_ record: NotesRecord, by event: NSEvent) -> Bool {
        let layout = notesLayout(record)
        let location = world(convert(event.locationInWindow, from: nil))
        guard layout.maxScroll > 0, layout.content.contains(local(location, in: record.frame)) else { return false }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let current = notesScroll[record.id] ?? 0
        notesScroll[record.id] = min(max(current - event.scrollingDeltaY * factor / zoom, 0), layout.maxScroll)
        syncLayers()
        return true
    }

    // MARK: Writing a note

    fileprivate func beginNoteEditing(on card: UUID, entry: UUID?) {
        guard let record = store.notesRecord(card) else { return }
        let field = noteField ?? {
            let field = NSTextField()
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = .white
            field.focusRingType = .none
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
            field.delegate = self
            // A field reads as one with a thin ring; the board draws no other borders.
            field.wantsLayer = true
            field.layer?.cornerRadius = 8
            field.layer?.borderWidth = 1
            field.layer?.borderColor = BoardPalette.rgb(BoardPalette.accent, 0.5)
            noteField = field
            return field
        }()
        editingNote = (card, entry)
        field.placeholderString = L("Write a note…")
        field.stringValue = entry.flatMap { id in record.entries.first { $0.id == id }?.text } ?? ""
        if field.superview == nil { addSubview(field) }
        syncLayers()
        window?.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
    }

    fileprivate func placeNoteField() {
        guard let field = noteField, let editing = editingNote, let record = store.notesRecord(editing.card) else { return }
        let layout = notesLayout(record)
        var rect: CGRect
        if let entry = editing.entry {
            guard let text = layout.textFrame(of: entry, scroll: notesScroll[record.id] ?? 0) else { return }
            rect = text.insetBy(dx: -6, dy: -4)
            rect.size.height = max(rect.height, 28)
        } else {
            rect = layout.add
        }
        field.font = NSFont.systemFont(ofSize: NotesCardLayout.textFont.pointSize * zoom)
        field.frame = screen(rect.offsetBy(dx: record.frame.minX, dy: record.frame.minY))
    }

    /// Closes the field; `commit` keeps what was written (an emptied note is removed).
    fileprivate func endNoteEditing(commit: Bool) {
        guard let field = noteField, let editing = editingNote else { return }
        editingNote = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if commit, let record = store.notesRecord(editing.card) {
            if let id = editing.entry, var entry = record.entries.first(where: { $0.id == id }) {
                if text.isEmpty {
                    store.deleteNote(id, on: record.id)
                } else if text != entry.text {
                    entry.text = text
                    entry.author = nil
                    entry.authorName = ""
                    entry.updated = Date()
                    store.writeNote(entry, on: record.id)
                }
            } else if editing.entry == nil, !text.isEmpty {
                store.writeNote(NoteEntry(kind: .note, author: nil, authorName: "", text: text), on: record.id)
                // The new note is last: show it.
                notesScroll[record.id] = .greatestFiniteMagnitude
            }
        }
        if window?.firstResponder === field.currentEditor() || window?.firstResponder === field { window?.makeFirstResponder(self) }
        syncLayers()
    }

    /// Enter keeps the note, Option-Enter starts a new line, Escape drops the change.
    fileprivate func noteField(doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endNoteEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endNoteEditing(commit: false)
            return true
        default:
            return false
        }
    }
}

/// A device menu item's choice; nil device means Custom….
private final class DeviceChoice {
    let browser: UUID
    let device: BrowserDevice?

    init(browser: UUID, device: BrowserDevice?) {
        self.browser = browser
        self.device = device
    }
}

/// A profile menu item's choice; a nil profile with importData opens the import dialog.
private final class ProfileChoice {
    let browser: UUID
    let profile: UUID?
    let importData: Bool

    init(browser: UUID, profile: UUID?, importData: Bool) {
        self.browser = browser
        self.profile = profile
        self.importData = importData
    }
}

/// What the board shows: world points map to the view as `world × zoom + pan`.
private struct Camera: Equatable {
    var zoom: CGFloat
    var pan: CGPoint

    static let still = Camera(zoom: 0, pan: .zero)
}

/// A spring driving the camera toward `target`, stepped once per display refresh. Zoom and pan
/// share one spring, so starting from rest they move in step and an anchored zoom keeps its
/// anchor fixed the whole way.
private struct CameraAnimation {
    var target: Camera
    /// Per second, per component.
    var velocity: Camera
    var time: CFTimeInterval?

    private static let stiffness: CGFloat = 260
    private static let damping: CGFloat = 2 * sqrt(stiffness)

    mutating func step(_ camera: inout Camera, by elapsed: CFTimeInterval) {
        // Small fixed substeps keep the integration stable at any frame rate.
        let substeps = max(1, Int((elapsed * 480).rounded(.up)))
        let dt = CGFloat(elapsed) / CGFloat(substeps)
        func spring(_ value: inout CGFloat, _ velocity: inout CGFloat, to target: CGFloat) {
            velocity += (-Self.stiffness * (value - target) - Self.damping * velocity) * dt
            value += velocity * dt
        }
        for _ in 0..<substeps {
            spring(&camera.zoom, &velocity.zoom, to: target.zoom)
            spring(&camera.pan.x, &velocity.pan.x, to: target.pan.x)
            spring(&camera.pan.y, &velocity.pan.y, to: target.pan.y)
        }
    }

    func isSettled(_ camera: Camera) -> Bool {
        abs(camera.zoom - target.zoom) < 0.0005 && abs(velocity.zoom) < 0.005
            && hypot(camera.pan.x - target.pan.x, camera.pan.y - target.pan.y) < 0.25
            && hypot(velocity.pan.x, velocity.pan.y) < 1
    }
}

// MARK: - Layers

/// The canvas grid: minor lines every 24 points, a heavier one every fifth, scaled by the zoom.
/// Built from replicated one-pixel lines, so panning only moves a layer.
private final class GridLayer: CALayer {
    private static let spacing: CGFloat = 24
    /// Below this on-screen spacing the minor lines turn into noise and are left out.
    private static let minimumMinorSpacing: CGFloat = 10
    private var builtSize: CGSize?
    private var builtScale: CGFloat?
    private var builtZoom: CGFloat?

    func update(bounds: CGRect, pan: CGPoint, zoom: CGFloat, scale: CGFloat) {
        let period = Self.spacing * 5 * zoom
        // One period of slack on each side lets the pan offset wrap without uncovering edges.
        let size = CGSize(width: bounds.width + period * 2, height: bounds.height + period * 2)
        if builtSize != size || builtScale != scale || builtZoom != zoom { build(size: size, zoom: zoom, scale: scale) }
        func wrap(_ value: CGFloat) -> CGFloat {
            let offset = value.truncatingRemainder(dividingBy: period)
            return ((offset < 0 ? offset + period : offset) * scale).rounded() / scale - period
        }
        frame = CGRect(origin: CGPoint(x: wrap(pan.x), y: wrap(pan.y)), size: size)
    }

    private func build(size: CGSize, zoom: CGFloat, scale: CGFloat) {
        builtSize = size
        builtScale = scale
        builtZoom = zoom
        sublayers?.forEach { $0.removeFromSuperlayer() }
        let spacing = Self.spacing * zoom
        // Major lines sit on top of minor ones; their alpha makes the overlap read as 0.09.
        let minor = BoardPalette.rgb(BoardPalette.ink, 0.05), major = BoardPalette.rgb(BoardPalette.ink, 0.042)
        let lines = spacing < Self.minimumMinorSpacing
            ? [(spacing * 5, BoardPalette.rgb(BoardPalette.ink, 0.09))]
            : [(spacing, minor), (spacing * 5, major)]
        for (step, color) in lines {
            for vertical in [true, false] {
                let line = CALayer()
                line.backgroundColor = color
                line.frame = vertical ? CGRect(x: 0, y: 0, width: 1 / scale, height: size.height)
                                      : CGRect(x: 0, y: 0, width: size.width, height: 1 / scale)
                let replicator = CAReplicatorLayer()
                replicator.frame = CGRect(origin: .zero, size: size)
                replicator.instanceCount = Int(((vertical ? size.width : size.height) / step).rounded(.up)) + 1
                replicator.instanceTransform = vertical ? CATransform3DMakeTranslation(step, 0, 0) : CATransform3DMakeTranslation(0, step, 0)
                replicator.addSublayer(line)
                addSublayer(replicator)
            }
        }
    }
}

/// One agent card: chrome as Core Animation layers, the terminal as a layer showing its region
/// of the board's shared surface, which exists only while the card is on screen.
private final class CardLayer: CALayer {
    private let dot = CALayer()
    private let title = CATextLayer()
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let cursor = CALayer()
    private let dim = CALayer()
    private let status = CATextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?
    private(set) var content: CALayer?
    /// One layer per shared-surface buffer, filling `content`; the one showing the latest frame is visible.
    private(set) var buffers: [CALayer] = []
    private(set) var terminal: TerminalLayer?
    private(set) var state: AgentSession.State?
    /// Where the terminal starts below the card's top: lower on runner cards, under their strip.
    var contentTop = CardMetrics.titleHeight
    /// Title bar room kept free for controls left of close.
    var titleReserve: CGFloat = 0

    override init() {
        super.init()
        backgroundColor = BoardPalette.card
        cornerRadius = CardMetrics.radius
        shadowColor = BoardPalette.rgb(BoardPalette.ink)
        dot.cornerRadius = 3.5
        closeHover.cornerRadius = CardMetrics.closeSize / 2
        closeHover.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.12)
        cursor.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.35)
        cursor.isHidden = true
        dim.backgroundColor = BoardPalette.rgb(0xFFFFFF, 0.75)
        for text in [title, closeGlyph, status] {
            text.fontSize = 12
            text.truncationMode = .end
        }
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        closeGlyph.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeGlyph.string = "✕"
        closeGlyph.alignmentMode = .center
        status.alignmentMode = .center
        [dot, title, closeHover, closeGlyph, cursor, dim, status].forEach(addSublayer)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: CardMetrics.handleSize, height: CardMetrics.handleSize)
            handle.cornerRadius = CardMetrics.handleSize / 2
            handle.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
            // A handle is a control: the white ring sets it off from the card edge it sits on.
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

    func update(frame: CGRect, title text: String, state: AgentSession.State, focused: Bool, closeHovered: Bool,
                starting: String, message: String?, scale: CGFloat) {
        self.frame = frame
        self.state = state
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: CardMetrics.radius, cornerHeight: CardMetrics.radius, transform: nil)
        shadowOpacity = focused ? 0.16 : 0.08
        shadowRadius = focused ? 14 : 8
        shadowOffset = CGSize(width: 0, height: focused ? 12 : 5)
        for layer in [title, closeGlyph, status] { layer.contentsScale = scale }

        let ink = BoardPalette.ink
        let font = NSFont.systemFont(ofSize: 12)
        let line = ceil(font.ascender - font.descender) + 2
        let mid = CardMetrics.titleHeight / 2
        dot.frame = CGRect(x: CardMetrics.inset + 2, y: mid - 3.5, width: 7, height: 7)
        dot.backgroundColor = switch state {
        case .starting, .running: BoardPalette.rgb(BoardPalette.accent)
        case .exited, .stopped: BoardPalette.rgb(ink, 0.25)
        case .failed: BoardPalette.rgb(BoardPalette.secondary)
        }
        if state == .starting {
            if dot.animation(forKey: "pulse") == nil {
                // Breathes while the agent launches.
                let pulse = CASpringAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.3
                pulse.damping = 14
                pulse.stiffness = 40
                pulse.duration = pulse.settlingDuration
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                dot.add(pulse, forKey: "pulse")
            }
        } else {
            dot.removeAnimation(forKey: "pulse")
        }

        let close = CardMetrics.close(of: bounds)
        title.string = text
        title.foregroundColor = BoardPalette.rgb(ink, focused ? 0.9 : 0.6)
        title.frame = CGRect(x: dot.frame.maxX + 8, y: mid - line / 2, width: max(0, close.minX - dot.frame.maxX - 16 - titleReserve), height: line)
        closeHover.frame = close
        closeHover.isHidden = !closeHovered
        closeGlyph.foregroundColor = BoardPalette.rgb(ink, closeHovered ? 0.8 : 0.4)
        closeGlyph.frame = CGRect(x: close.minX, y: close.midY - line / 2, width: close.width, height: line)

        // A launching, finished or failed agent says so over its terminal.
        var area = CardMetrics.content(of: bounds)
        area = CGRect(x: area.minX, y: contentTop, width: area.width, height: max(0, area.maxY - contentTop))
        dim.frame = area
        dim.isHidden = message == nil
        let label = message ?? (state == .starting ? starting : nil)
        status.isHidden = label == nil
        status.string = label
        status.font = NSFont.systemFont(ofSize: 12, weight: message == nil ? .medium : .semibold)
        status.foregroundColor = BoardPalette.rgb(ink, message == nil ? 0.45 : 0.75)
        status.frame = CGRect(x: area.minX + 12, y: area.midY - line / 2, width: max(0, area.width - 24), height: line)
    }

    /// Shows the connection handles while the card is hovered (or a line is being drawn from it),
    /// and lights the card up as the target of a line being drawn.
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

    fileprivate static func spring(_ keyPath: String, from: Any?, to: Any, stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Gives the card a terminal surface `size` points large, drawn at `scale` pixels per
    /// point. Returns true when it needs a full redraw (new, resized or rescaled).
    func attachTerminal(device: MTLDevice, size: CGSize, scale: CGFloat) -> Bool {
        var changed = false
        if content == nil {
            let content = CALayer()
            content.isOpaque = true
            content.backgroundColor = BoardPalette.card
            insertSublayer(content, below: cursor)
            self.content = content
            buffers = (0..<2).map { _ in
                let buffer = CALayer()
                buffer.isOpaque = true
                buffer.isHidden = true
                content.addSublayer(buffer)
                return buffer
            }
            terminal = TerminalLayer(device: device)
            changed = true
        }
        guard let content else { return changed }
        let frame = CGRect(origin: CGPoint(x: CardMetrics.inset, y: contentTop), size: size)
        if content.frame != frame || buffers.first?.contentsScale != scale {
            content.frame = frame
            for buffer in buffers {
                buffer.contentsScale = scale
                buffer.frame = content.bounds
            }
            changed = true
        }
        return changed
    }

    /// Swaps in a fresh terminal layer, which uploads every cell on its next update, while the
    /// buffers keep showing the last frame.
    func renewTerminal(device: MTLDevice) {
        guard terminal != nil else { return }
        terminal = TerminalLayer(device: device)
    }

    func detachTerminal() {
        content?.removeFromSuperlayer()
        content = nil
        buffers = []
        terminal = nil
        cursor.isHidden = true
    }

    func showCursor(_ state: CursorState, enabled: Bool, cell: CGSize) {
        // Only what changed is set: every property set goes to the window server on commit.
        guard let terminal, enabled, state.visible, state.row < terminal.rows, state.column < terminal.cols else {
            if !cursor.isHidden { cursor.isHidden = true }
            return
        }
        let x = CardMetrics.inset + CGFloat(state.column) * cell.width
        let y = contentTop + CGFloat(state.row) * cell.height
        let frame = switch state.shape {
        case .block: CGRect(x: x, y: y, width: cell.width, height: cell.height)
        case .underline: CGRect(x: x, y: y + cell.height - 2, width: cell.width, height: 2)
        case .bar: CGRect(x: x, y: y, width: 2, height: cell.height)
        }
        if cursor.isHidden { cursor.isHidden = false }
        if cursor.frame != frame { cursor.frame = frame }
    }

    /// Springs up into place when the card is added.
    func animateAppearance() {
        let fade = CASpringAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 14
        rise.toValue = 0
        for spring in [fade, rise] {
            spring.stiffness = 240
            spring.damping = 24
            spring.duration = spring.settlingDuration
        }
        add(fade, forKey: "appear-fade")
        add(rise, forKey: "appear-rise")
    }
}

/// One line between two cards, in world coordinates: the routed path with rounded bends, a dot
/// where it meets each card, and, while hovered, a knob in the middle that removes it.
private final class LinkLayer: CALayer {
    private let line = CAShapeLayer()
    private let ends = CAShapeLayer()
    private let knob = CALayer()
    private let knobGlyph = CATextLayer()
    private var route: Route?
    private static let bendRadius: CGFloat = 10
    private static let knobSize: CGFloat = 20

    override init() {
        super.init()
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        ends.fillColor = BoardPalette.rgb(BoardPalette.accent)
        knob.bounds = CGRect(x: 0, y: 0, width: Self.knobSize, height: Self.knobSize)
        knob.cornerRadius = Self.knobSize / 2
        knob.backgroundColor = BoardPalette.card
        knob.shadowColor = BoardPalette.rgb(BoardPalette.ink)
        knob.shadowOpacity = 0.18
        knob.shadowRadius = 5
        knob.shadowOffset = CGSize(width: 0, height: 2)
        knob.isHidden = true
        knobGlyph.string = "✕"
        knobGlyph.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        knobGlyph.fontSize = 10
        knobGlyph.alignmentMode = .center
        knobGlyph.foregroundColor = BoardPalette.rgb(BoardPalette.ink, 0.7)
        let line = ceil(NSFont.systemFont(ofSize: 10).ascender - NSFont.systemFont(ofSize: 10).descender)
        knobGlyph.frame = CGRect(x: 0, y: (Self.knobSize - line) / 2, width: Self.knobSize, height: line)
        knob.addSublayer(knobGlyph)
        [self.line, ends, knob].forEach(addSublayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(route: Route, hovered: Bool, scale: CGFloat) {
        for layer in [line, ends, knobGlyph] { layer.contentsScale = scale }
        if route != self.route {
            self.route = route
            line.path = Self.path(route.points)
            let ends = CGMutablePath()
            for point in [route.points.first, route.points.last].compactMap({ $0 }) {
                ends.addEllipse(in: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
            }
            self.ends.path = ends
            knob.position = route.point(at: 0.5)
        }
        line.strokeColor = BoardPalette.rgb(BoardPalette.accent, hovered ? 0.95 : 0.55)
        line.lineWidth = hovered ? 2.5 : 2
        if knob.isHidden == hovered {
            knob.isHidden = !hovered
            if hovered { knob.add(CardLayer.spring("transform.scale", from: 0.6, to: 1, stiffness: 420, damping: 24), forKey: "appear") }
        }
    }

    func knobContains(_ point: CGPoint, zoom: CGFloat) -> Bool {
        guard !knob.isHidden else { return false }
        return hypot(point.x - knob.position.x, point.y - knob.position.y) <= max(Self.knobSize / 2, 10 / zoom)
    }

    /// A bright stretch of line shoots along `route` (from sender to recipient) and drains into
    /// the far end: its head and tail are springs, the tail softer so it trails.
    func pulse(along route: Route) {
        let pulse = CAShapeLayer()
        pulse.path = Self.path(route.points)
        pulse.fillColor = nil
        pulse.strokeColor = BoardPalette.rgb(BoardPalette.accent)
        pulse.lineWidth = 4
        pulse.lineCap = .round
        pulse.lineJoin = .round
        pulse.contentsScale = line.contentsScale
        pulse.strokeStart = 1
        pulse.strokeEnd = 1
        addSublayer(pulse)
        let head = CardLayer.spring("strokeEnd", from: 0, to: 1, stiffness: 40, damping: 12.6)
        let tail = CardLayer.spring("strokeStart", from: 0, to: 1, stiffness: 18, damping: 8.5)
        CATransaction.begin()
        CATransaction.setCompletionBlock { pulse.removeFromSuperlayer() }
        pulse.add(head, forKey: "head")
        pulse.add(tail, forKey: "tail")
        CATransaction.commit()
    }

    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in points.indices.dropFirst().dropLast() {
            let (before, corner, after) = (points[index - 1], points[index], points[index + 1])
            let room = min(hypot(corner.x - before.x, corner.y - before.y), hypot(after.x - corner.x, after.y - corner.y)) / 2
            path.addArc(tangent1End: corner, tangent2End: after, radius: min(bendRadius, room))
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }
}
