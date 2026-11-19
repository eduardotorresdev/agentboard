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
    static let radius: CGFloat = Theme.Radius.card
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

    /// The smallest a control's hit area gets on screen, whatever the zoom.
    static let minimumTarget: CGFloat = 20

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

    static let ink: UInt32 = Theme.Hex.ink
    static let accent: UInt32 = Theme.Hex.accent
    static let deep: UInt32 = Theme.Hex.deep
    static let card = rgb(Theme.Hex.white)
    /// A post-it's paper: a baby-blue wash (Radix Blue 3).
    static let postIt: UInt32 = Theme.Hex.accentSoft
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
    func addPostIt() { view?.addPostIt() }
    /// The style at the cursor of the post-it being written as rich text; nil when none is.
    fileprivate(set) var postItFormat: PostItFormat?
    func setPostItHeading(_ level: Int?) { view?.postItEditor?.setHeading(level) }
    func togglePostItBold() { view?.postItEditor?.toggleBold() }
    func togglePostItUnderline() { view?.postItEditor?.toggleUnderline() }
    func addFileTree() { view?.addFileTree() }
    func addImages() { view?.addImages() }
    func addVideos() { view?.addVideos() }
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
    func organize() { view?.organize() }
    /// The canvas as a template (see `CanvasTemplate`).
    func template() -> CanvasTemplate? { view?.template() }
    /// Replaces the canvas with `template`; asks first when that ends what is on it.
    func apply(_ template: CanvasTemplate) {
        guard let view else { return }
        guard view.hasCards, let window = view.window else { return view.apply(template) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Replace this canvas with the template?")
        alert.informativeText = L("Every card on it is removed, and its agents and runners stop. This can't be undone.")
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { view.apply(template) }
        }
    }
    /// A card to frame and focus once its worktree shows on the board.
    @ObservationIgnored var pendingReveal: UUID?
    func reveal(_ id: UUID) {
        pendingReveal = id
        view?.revealPending()
    }
    /// Width of the canvas's leading edge covered by the floating sidebar, kept clear when fitting.
    var leadingInset: CGFloat = 0
    /// Only the canvas and the Needs you button show: no sidebar, bars or zoom controls.
    var isZen = false
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
    let fileTrees: FileTreeStore
    let worktree: String
    let controller: BoardController

    func makeNSView(context: Context) -> BoardView {
        let view = BoardView(store: store, browsers: browsers, fileTrees: fileTrees)
        controller.view = view
        view.controller = controller
        return view
    }

    func updateNSView(_ view: BoardView, context: Context) {
        controller.view = view
        view.controller = controller
        view.worktree = worktree
        view.syncLayers()
        if controller.pendingReveal != nil { DispatchQueue.main.async { view.revealPending() } }
    }

    static func dismantleNSView(_ view: BoardView, coordinator: ()) {
        view.closeStaleForwards(leaving: true)
        view.releaseTerminals()
    }
}

/// The worktree canvas, built from Core Animation layers: the lines between cards, and
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
    fileprivate let fileTrees: FileTreeStore
    fileprivate var fileTreeCards: [UUID: FileTreeCardLayer] = [:]
    /// The SwiftUI files and file of each file tree card, over its content, and the bar that
    /// sends its notes, below it.
    fileprivate var fileTreeViews: [UUID: (host: FileTreeHost, content: NSView, bar: NSView, barHost: FileTreeHost)] = [:]
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
    private let linksLayer = CALayer()
    private let cardsLayer = CALayer()
    /// Above the cards: the line being drawn from a handle.
    private let overlayLayer = CALayer()
    private let linkPreview = CAShapeLayer()
    /// The box dragged out on the empty canvas.
    private let marqueeLayer = CAShapeLayer()
    /// Cards picked with the box; Delete removes them after asking.
    private var selection: Set<UUID> = []
    /// Where the box started and where the pointer is, in world points, and the selection it adds to.
    private var marquee: (start: CGPoint, current: CGPoint, base: Set<UUID>)?
    private var cards: [UUID: CardLayer] = [:]
    /// Runner cards' buttons, addresses and metrics, drawn over their `CardLayer`.
    private var runnerChrome: [UUID: RunnerChromeLayer] = [:]
    /// Each agent card's composer, below the card.
    private var composers: [UUID: NSView] = [:]
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
    private var nameField: NSTextField?
    /// The agent card whose name is being edited.
    private var renamingCard: UUID?
    fileprivate var postItCards: [UUID: PostItCardLayer] = [:]
    /// How far each post-it's text is scrolled.
    fileprivate var postItScroll: [UUID: CGFloat] = [:]
    /// View or Code, per post-it, as the user last chose.
    /// The post-it control under the pointer.
    fileprivate var hoveredPostIt: (card: UUID, control: PostItControl?)?
    /// The text view over the post-it being written in.
    fileprivate var postItEditor: PostItEditor?
    fileprivate var editingPostIt: UUID?
    fileprivate var imageCards: [UUID: ImageCardLayer] = [:]
    private var links: [UUID: LinkLayer] = [:]
    /// The lines hang as ropes between the handles they were drawn to; `routes` is where each
    /// one is now, for finding the line under the pointer and sending messages along it.
    private var ropes: [UUID: Rope] = [:]
    private var routes: [UUID: Route] = [:]
    /// The handles picked for lines made without them (by an agent), so their ends stay put.
    private var chosenSides: [UUID: (Side, Side)] = [:]
    /// The rope following the pointer while a line is drawn.
    private var previewRope: Rope?
    /// Steps the ropes while any of them swings; paused once they all hang still.
    private var ropeLink: CADisplayLink?
    private var ropeClock: CFTimeInterval?
    private var linkScale: CGFloat = 2
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
            closeStaleForwards()
            endAddressEditing()
            endPostItEditing()
            focusedID = nil
            cameraAnimation = nil
            releaseTerminals()
            if renderZoom != zoom {
                renderZoom = zoom
                glyphs = nil
            }
            // Called from a SwiftUI update: publish after it.
            DispatchQueue.main.async { [weak self] in self?.publishZoom() }
            // Cards still organizing on the worktree left land where they were going.
            endLayoutAnimation(atTargets: true)
        }
    }
    /// Each worktree's camera, kept across rebuilds of the board and relaunches.
    private let cameras = CameraMemory()
    private var pan: CGPoint {
        get { cameras[worktree]?.pan ?? .zero }
        set { cameras[worktree] = Camera(zoom: zoom, pan: newValue) }
    }
    private var zoom: CGFloat {
        get { cameras[worktree]?.zoom ?? 1 }
        set { cameras[worktree] = Camera(zoom: newValue, pan: pan) }
    }
    /// The zoom terminals and card text are rasterized for. Trails `zoom` while it changes.
    private var renderZoom: CGFloat = 1
    private var sharpenWork: DispatchWorkItem?
    private var cameraAnimation: CameraAnimation?
    private var cameraLink: CADisplayLink?
    /// The cards springing to where Organize put them.
    private var layoutAnimation: LayoutAnimation?
    private var layoutLink: CADisplayLink?
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
        /// The pointer, or the handle it snapped to.
        var point: CGPoint
        var target: UUID?
        /// The target's handle the end is tied to.
        var targetSide: Side?
    }

    private struct Interaction {
        enum Kind { case move, resize }
        let id: UUID
        let kind: Kind
        let start: CGPoint
        let frame: CGRect
        /// The edges an image card is resized from.
        var edges: ImageResize.Edges = [.right, .bottom]
        /// Where every selected card started, when the moved card is one of them.
        var group: [UUID: CGRect]?
    }

    init(store: AgentStore, browsers: BrowserStore, fileTrees: FileTreeStore) {
        self.store = store
        self.browsers = browsers
        self.fileTrees = fileTrees
        presenter = MTLCreateSystemDefaultDevice().flatMap { TerminalPresenter(device: $0) }
        surface = presenter.map { SharedSurface(device: $0.device) }
        super.init(frame: .zero)
        root.isGeometryFlipped = true
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
        marqueeLayer.fillColor = BoardPalette.rgb(BoardPalette.accent, 0.1)
        marqueeLayer.strokeColor = nil
        marqueeLayer.isHidden = true
        overlayLayer.addSublayer(marqueeLayer)
        layer = root
        wantsLayer = true
        store.onSessionChange = { [weak self] id in self?.sessionChanged(id) }
        store.onMessage = { [weak self] message in self?.showMessage(message) }
        store.onRunnersChange = { [weak self] in
            self?.syncLayers()
            self?.closeStaleForwards()
        }
        browsers.onPageChange = { [weak self] _ in self?.syncLayers() }
        store.onMediaChange = { [weak self] file in self?.mediaChanged(file) }
        store.onMediaNote = { [weak self] _ in self?.syncLayers() }
        registerForDraggedTypes([.fileURL])
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
        ropeLink?.invalidate()
        ropeLink = nil
        ropeClock = nil
        guard let window else { return releaseTerminals() }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        // A composer that grows or shrinks a line takes room from its terminal.
        NotificationCenter.default.addObserver(self, selector: #selector(composerLinesChanged),
                                               name: ComposerDrafts.linesChanged, object: nil)
        // Reduce Transparency and Increase Contrast change how card headers draw.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let link = displayLink(target: self, selector: #selector(refresh))
        link.isPaused = true
        pace = .background
        link.preferredFrameRateRange = Self.frameRate(pace)
        link.add(to: .main, forMode: .common)
        displayLink = link
        syncLayers()
    }

    @objc private func displayOptionsChanged() { syncLayers() }

    @objc private func composerLinesChanged() { syncLayers() }

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
        for id in observed { store.stopObserving(id, by: self) }
        observed.removeAll()
        dirty.removeAll()
        cards.values.forEach { $0.detachTerminal() }
        // Hidden, minimized or gone: no video keeps playing behind it.
        imageCards.values.forEach { $0.video?.pause() }
        surface?.release()
        displayLink?.isPaused = true
    }

    // MARK: Adding

    /// Where a card the user adds goes: the first free spot `BoardLayout` finds in the rows of
    /// groups; on an empty canvas, the middle of the screen.
    private func newCardOrigin(for size: CGSize) -> CGPoint {
        if let origin = BoardLayout.slot(for: size, among: layoutItems, connections: worktreeConnections, aspect: screenAspect) {
            return origin
        }
        let center = world(CGPoint(x: bounds.midX, y: bounds.midY))
        let top = world(CGPoint(x: 0, y: 72)).y
        return CGPoint(x: center.x - size.width / 2, y: max(top, center.y - size.height / 2))
    }

    /// Pans, at the current zoom, until `frame` is on screen, unless it already is.
    private func bringIntoView(_ frame: CGRect) {
        let inset = controller?.leadingInset ?? 0
        let area = CGRect(x: 48 + inset, y: 48, width: bounds.width - 96 - inset, height: bounds.height - 48 - 96)
        guard area.width > 0, area.height > 0, !area.contains(screen(frame)) else { return }
        let zoom = cameraAnimation?.target.zoom ?? self.zoom
        // Centered when it fits, its top-left corner in view when it doesn't.
        let x = frame.width * zoom <= area.width ? area.midX - frame.midX * zoom : area.minX - frame.minX * zoom
        let y = frame.height * zoom <= area.height ? area.midY - frame.midY * zoom : area.minY - frame.minY * zoom
        animateCamera(to: Camera(zoom: zoom, pan: CGPoint(x: x, y: y)))
    }

    private var screenAspect: CGFloat {
        bounds.height > 0 ? bounds.width / bounds.height : BoardLayout.defaultAspect
    }

    /// Every card of this worktree, as `BoardLayout` arranges it.
    private var layoutItems: [BoardLayout.Item] {
        let hubs = Set(store.agents(in: worktree).filter { $0.runner == nil }.map(\.id))
        return itemFrames.map { BoardLayout.Item(id: $0.id, frame: $0.frame, isHub: hubs.contains($0.id)) }
    }

    func addAgent(_ provider: any AgentProvider) {
        let record = store.add(provider, to: worktree, at: newCardOrigin(for: CGSize(width: 640, height: 420)))
        appearing.insert(record.id)
        bringIntoView(record.frame)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
    }

    func addRunner(command: String, name: String?, directory: String?) {
        let record = store.addRunner(command: command, name: name, directory: directory, to: worktree,
                                     at: newCardOrigin(for: AgentRecord.runnerSize))
        appearing.insert(record.id)
        bringIntoView(record.frame)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
    }

    func addBrowser(_ device: BrowserDevice) {
        let scale = BrowserStore.initialScale(for: device)
        let size = BrowserStore.frame(for: device, at: .zero, scale: scale).size
        let record = browsers.add(device, to: worktree, on: store.host?.id, at: newCardOrigin(for: size))
        appearing.insert(record.id)
        bringIntoView(record.frame)
        focusedID = record.id
        window?.makeFirstResponder(self)
        syncLayers()
        beginAddressEditing(record.id)
    }

    func addPostIt() {
        let record = store.addPostIt(to: worktree, at: newCardOrigin(for: PostItRecord.size))
        appearing.insert(record.id)
        bringIntoView(record.frame)
        focusedID = record.id
        // A new post-it opens for writing.
        syncLayers()
        beginPostItEditing(on: record.id, at: nil)
    }

    /// Asks for video files and adds a card for each; one AVFoundation can't play is refused.
    func addVideos() { addImages(videos: true) }

    /// Asks for picture files and adds a card for each.
    func addImages(videos: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = videos ? [.movie] : [.image]
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.addImages(panel.urls.map(ImageSource.file), at: nil)
        }
    }

    /// Adds a card per picture: at `point` (world), cascading, or where new cards go. A refused
    /// file is reported once all are in.
    fileprivate func addImages(_ sources: [ImageSource], at point: CGPoint?) {
        Task { await addImagesNow(sources, at: point) }
    }

    private func addImagesNow(_ sources: [ImageSource], at point: CGPoint?) async {
        var refused: [String] = []
        var added: ImageRecord?
        let worktree = worktree
        for (index, source) in sources.enumerated() {
            let step = CGFloat(index) * 32
            do {
                let origin = point.map { CGPoint(x: $0.x + step, y: $0.y + step) } ?? newCardOrigin(for: CGSize(width: ImageRecord.initialSide, height: ImageRecord.initialSide))
                let record = try await store.addImage(source, named: source.baseName, to: worktree, at: origin) { [weak self] record in
                    guard let self, record.worktree == self.worktree else { return }
                    appearing.insert(record.id)
                    bringIntoView(record.frame)
                    syncLayers()
                }
                if imageCards[record.id] == nil { appearing.insert(record.id) }
                added = record
            } catch {
                let name = if case .file(let url) = source { url.lastPathComponent } else { L("The pasted picture") }
                let reason = switch error as? ImageFiles.Failure {
                case .tooLarge where source.isVideo: L("\(name) is larger than \(ImageFiles.maximumVideoBytes / 1024 / 1024) MB.")
                case .tooLarge: L("\(name) is larger than 20 MB.")
                case .notAnImage: L("\(name) isn't a picture the board can show.")
                case .notPlayable: L("\(name) isn't a video the board can play. Use MP4, MOV or M4V.")
                case .notAFile: L("\(name) isn't a file.")
                default:
                    switch error as? HostMediaFailure {
                    case .tooLarge: L("\(name) is larger than \(HostMediaFailure.maximumBytes / 1024 / 1024) MB, the most that can be sent to another host.")
                    case .unreachable: L("\(name) couldn't be sent to \(store.host?.name ?? L("the host")).")
                    case nil: L("\(name) couldn't be read.")
                    }
                }
                refused.append(reason)
            }
        }
        // The board moved on to another worktree while a video was copied: nothing to show here.
        if let added, added.worktree == self.worktree {
            bringIntoView(added.frame)
            focusedID = added.id
            window?.makeFirstResponder(self)
            syncLayers()
        }
        guard !refused.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = refused.count == 1 ? L("Couldn't add the file") : L("Couldn't add \(refused.count) files")
        alert.informativeText = refused.joined(separator: "\n")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func addFileTree() {
        let record = fileTrees.add(to: worktree, on: store.host?.id, at: newCardOrigin(for: FileTreeRecord.size))
        appearing.insert(record.id)
        bringIntoView(record.frame)
        focusedID = record.id
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
        // A worktree on another host never shown here (its cards were placed from another
        // computer) opens on its cards, clear of the sidebar, instead of wherever they fall.
        if store.host != nil, cameras[worktree] == nil, bounds.width > 0 {
            let cards = store.agents(in: worktree).reduce(CGRect.null) { $0.union($1.frame) }
            if !cards.isNull {
                cameras[worktree] = Camera(zoom: 1, pan: .zero)
                frame(cards)
            }
        }
        let scale = scale
        let renderScale = scale * renderZoom
        let base = cellAtZoom1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        root.contentsScale = scale
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
        for (id, view) in composers where !ids.contains(id) {
            view.removeFromSuperview()
            composers[id] = nil
            // Off this worktree it keeps its draft; removed from the board it doesn't.
            if store.record(id) == nil { ComposerDrafts.forget(id) }
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
            // The same source as the sidebar.
            let status = store.cardStatus(record)
            let kind = record.runner != nil ? L("Runner") : record.provider?.title ?? record.providerID
            // The kind is left out when the name already says it ("Claude 2").
            let detail = status == .waiting || status == .crashed ? status.label
                : record.isOrchestrator ? L("\(kind) · Orchestrator") : record.name.hasPrefix(kind) ? nil : kind
            let icon: CardIcon = record.runner != nil ? .symbol("play.rectangle", color: Theme.Hex.inkMuted) : CardFrame.agentIcon(provider: record.providerID)
            card.update(frame: record.frame, title: record.name, detail: detail, icon: icon, status: status, kind: record.runner != nil ? .runner : .agent, state: state, focused: highlighted(record.id),
                        closeHovered: record.id == hoveredClose, starting: record.runner == nil ? L("Starting \(record.name)…") : "",
                        message: message, scale: renderScale)
            syncRunnerChrome(record, on: card, state: state, scale: renderScale)
            if record.runner == nil { placeComposer(for: record) }
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
        syncPostIts(scale: renderScale)
        syncImages(scale: renderScale)
        syncBrowsers(onScreen: onScreen, scale: renderScale)
        syncFileTrees(scale: renderScale)
        syncLinks(scale: renderScale)
        syncSelection()
        // Terminals that got a new place in the surface are drawn there before they show again.
        if let surface { dirty.formUnion(surface.arrange(sizes)) }
        observe(visible)
        if !dirty.isEmpty { displayLink?.isPaused = false }
    }

    /// The field at the bottom of the agent card, laid out in world points and scaled with the
    /// camera like the rest of the card.
    private func placeComposer(for record: AgentRecord) {
        let view = composers[record.id] ?? {
            let view = NSView()
            view.addSubview(NSHostingView(rootView: AgentComposer(store: store, id: record.id)))
            composers[record.id] = view
            addSubview(view)
            return view
        }()
        let rect = CardMetrics.composer(of: record)
        view.frame = screen(rect)
        view.setBoundsSize(rect.size)
        view.subviews.first?.frame = view.bounds
    }

    /// Browser cards sit above the agents, in their own stacking order.
    private func syncBrowsers(onScreen: Bool, scale: CGFloat) {
        let records = browsers.browsers(in: worktree, on: store.host?.id)
        let ids = Set(records.map(\.id))
        for (id, card) in browserCards where !ids.contains(id) {
            card.removeFromSuperlayer()
            browserCards[id] = nil
        }
        if let editingAddress, !ids.contains(editingAddress) { endAddressEditing() }
        let below = CGFloat(store.agents(in: worktree).count + store.postIts(in: worktree).count + store.images(in: worktree).count)
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
                        focused: highlighted(record.id), hovered: hoveredControl?.card == record.id ? hoveredControl?.control : nil,
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
        placeNameField()
    }

    /// Every card of this worktree, agents, post-its then browsers: bottom to top.
    private var itemFrames: [(id: UUID, frame: CGRect)] {
        store.agents(in: worktree).map { ($0.id, $0.frame) } + store.postIts(in: worktree).map { ($0.id, $0.frame) }
            + store.images(in: worktree).map { ($0.id, $0.frame) }
            + browsers.browsers(in: worktree, on: store.host?.id).map { ($0.id, $0.frame) } + fileTrees.trees(in: worktree, on: store.host?.id).map { ($0.id, $0.frame) }
    }

    /// The lines of this worktree, between any of its cards.
    private var worktreeConnections: [Connection] {
        store.connections(in: worktree, elements: Set(browsers.browsers(in: worktree, on: store.host?.id).map(\.id)).union(fileTrees.trees(in: worktree, on: store.host?.id).map(\.id)))
    }

    /// Ties each line of this worktree to its cards' handles, and the one being drawn to the
    /// pointer; ropes whose ends moved swing until they hang still again.
    private func syncLinks(scale: CGFloat) {
        linkScale = scale
        let connections = worktreeConnections
        let frames = Dictionary(itemFrames.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(connections.map(\.id))
        for (id, link) in links where !ids.contains(id) {
            link.removeFromSuperlayer()
            links[id] = nil
        }
        ropes = ropes.filter { ids.contains($0.key) }
        routes = routes.filter { ids.contains($0.key) }
        if let hoveredLink, !ids.contains(hoveredLink) { self.hoveredLink = nil }
        for connection in connections {
            guard let (a, b) = anchors(of: connection, in: frames) else { continue }
            // Lines already there when the board opens hang at rest; drawn ones keep their swing.
            var rope = ropes[connection.id] ?? .resting(from: a, to: b)
            rope.tie(a, b)
            ropes[connection.id] = rope
            if links[connection.id] == nil {
                let link = LinkLayer()
                links[connection.id] = link
                linksLayer.addSublayer(link)
            }
        }
        if let linkDrag, let frame = frames[linkDrag.from] {
            let from = Self.anchor(frame, linkDrag.side)
            let to = if let target = linkDrag.target, let side = linkDrag.targetSide, let frame = frames[target] {
                Self.anchor(frame, side)
            } else {
                RopeAnchor(point: linkDrag.point)
            }
            var rope = previewRope ?? Rope(from: from, to: RopeAnchor(point: from.point))
            rope.tie(from, to)
            previewRope = rope
        } else {
            previewRope = nil
        }
        drawLinks()
        if ropes.values.contains(where: { !$0.isSettled }) || previewRope.map({ !$0.isSettled }) == true { startRopes() }
    }

    /// Where a line meets a card on `side`: that side's handle, leaving straight out of it.
    private static func anchor(_ frame: CGRect, _ side: Side) -> RopeAnchor {
        RopeAnchor(point: CardMetrics.handles(of: frame)[side.rawValue], side: side)
    }

    /// The handles a line is tied to: the ones it was drawn between; for a line made without
    /// them, the closest pair, picked once.
    private func anchors(of connection: Connection, in frames: [UUID: CGRect]) -> (RopeAnchor, RopeAnchor)? {
        guard let a = frames[connection.a], let b = frames[connection.b] else { return nil }
        if let aSide = connection.aSide, let bSide = connection.bSide { return (Self.anchor(a, aSide), Self.anchor(b, bSide)) }
        let sides = chosenSides[connection.id] ?? {
            var best: (Side, Side, CGFloat)?
            for aSide in connection.aSide.map({ [$0] }) ?? Side.allCases {
                for bSide in connection.bSide.map({ [$0] }) ?? Side.allCases {
                    let p = CardMetrics.handles(of: a)[aSide.rawValue], q = CardMetrics.handles(of: b)[bSide.rawValue]
                    let distance = hypot(q.x - p.x, q.y - p.y)
                    if distance < best?.2 ?? .infinity { best = (aSide, bSide, distance) }
                }
            }
            let sides = best.map { ($0.0, $0.1) } ?? (.right, .left)
            chosenSides[connection.id] = sides
            return sides
        }()
        return (Self.anchor(a, sides.0), Self.anchor(b, sides.1))
    }

    /// Puts every line, and the one being drawn, where its rope is now.
    private func drawLinks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (id, rope) in ropes {
            let route = rope.route
            routes[id] = route
            links[id]?.update(route: route, hovered: id == hoveredLink, scale: linkScale)
        }
        linkPreview.contentsScale = linkScale
        if let previewRope, let linkDrag {
            linkPreview.path = LinkLayer.path(previewRope.points)
            linkPreview.lineDashPattern = linkDrag.target == nil ? [5, 5] : nil
            linkPreview.strokeColor = BoardPalette.rgb(BoardPalette.accent, linkDrag.target == nil ? 0.7 : 0.95)
            linkPreview.isHidden = false
        } else {
            linkPreview.isHidden = true
        }
    }

    private func startRopes() {
        if ropeLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(stepRopes(_:)))
            link.add(to: .main, forMode: .common)
            ropeLink = link
        }
        if ropeLink?.isPaused != false { ropeClock = nil }
        ropeLink?.isPaused = false
    }

    @objc private func stepRopes(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = CGFloat(ropeClock.map { now - $0 } ?? 1.0 / 120)
        ropeClock = now
        for id in Array(ropes.keys) { ropes[id]?.advance(by: elapsed) }
        previewRope?.advance(by: elapsed)
        drawLinks()
        if ropes.values.allSatisfy(\.isSettled), previewRope?.isSettled ?? true {
            link.isPaused = true
            ropeClock = nil
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
        for id in observed.subtracting(visible) { store.stopObserving(id, by: self) }
        for id in visible.subtracting(observed) {
            store.observe(id, by: self)
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
        frame(frames.dropFirst().reduce(first) { $0.union($1) })
    }

    /// Springs every card to where `RadialLayout` arranges this worktree, and the camera to
    /// frame the result.
    func organize() {
        let targets = RadialLayout.organize(layoutItems.filter { selection.isEmpty || selection.contains($0.id) }, connections: worktreeConnections)
        guard let first = targets.values.first else { return }
        var animation = layoutAnimation ?? LayoutAnimation()
        for (id, target) in targets {
            guard let current = frame(of: id) else { continue }
            animation.move(id, from: current.origin, to: target.origin)
        }
        layoutAnimation = animation
        if layoutLink == nil {
            let link = displayLink(target: self, selector: #selector(stepLayoutAnimation(_:)))
            link.add(to: .main, forMode: .common)
            layoutLink = link
        }
        layoutLink?.isPaused = false
        frame(targets.values.reduce(first) { $0.union($1) })
    }

    @objc private func stepLayoutAnimation(_ link: CADisplayLink) {
        guard var animation = layoutAnimation else {
            link.isPaused = true
            return
        }
        let now = link.targetTimestamp
        let elapsed = animation.time.map { min(now - $0, 1.0 / 30) } ?? 1.0 / 120
        animation.time = now
        animation.step(by: elapsed)
        layoutAnimation = animation
        if animation.isSettled { return endLayoutAnimation(atTargets: true) }
        interacted()
        for (id, motion) in animation.motions {
            guard let current = frame(of: id) else { continue }
            let origin = CGPoint(x: motion.position.x.rounded(), y: motion.position.y.rounded())
            setFrame(CGRect(origin: origin, size: current.size), for: id, persist: false)
        }
        syncLayers()
    }

    /// Stops the cards organizing, where they are or where they were going, and saves them there.
    private func endLayoutAnimation(atTargets: Bool) {
        guard let animation = layoutAnimation else { return }
        layoutAnimation = nil
        layoutLink?.isPaused = true
        for (id, motion) in animation.motions {
            guard let current = frame(of: id) else { continue }
            let origin = atTargets ? motion.target : current.origin
            setFrame(CGRect(origin: origin, size: current.size), for: id, persist: true)
        }
        syncLayers()
    }

    /// Frames and focuses the card `controller.pendingReveal` names, once it is on this board.
    func revealPending() {
        guard let id = controller?.pendingReveal, let record = record(id), record.worktree == worktree else { return }
        controller?.pendingReveal = nil
        focusedID = id
        window?.makeFirstResponder(self)
        frame(record.frame)
    }

    /// Springs the camera to show `union` whole, never past actual size.
    private func frame(_ union: CGRect) {
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

    /// The topmost agent card under a world point, unless a browser or post-it covers it.
    private func card(at point: CGPoint) -> AgentRecord? {
        guard browser(at: point) == nil, postIt(at: point) == nil, image(at: point) == nil, fileTree(at: point) == nil else { return nil }
        return store.agents(in: worktree).last { $0.frame.contains(point) }
    }

    /// The topmost browser card under a world point.
    private func browser(at point: CGPoint) -> BrowserRecord? {
        guard fileTree(at: point) == nil else { return nil }
        return browsers.browsers(in: worktree, on: store.host?.id).last { $0.frame.contains(point) }
    }

    /// The topmost file tree card under a world point; their files float above every other card.
    fileprivate func fileTree(at point: CGPoint) -> FileTreeRecord? {
        fileTrees.trees(in: worktree, on: store.host?.id).last { $0.frame.contains(point) }
    }

    /// The topmost post-it under a world point, unless a browser card covers it.
    fileprivate func postIt(at point: CGPoint) -> PostItRecord? {
        guard browser(at: point) == nil, fileTree(at: point) == nil, image(at: point) == nil else { return nil }
        return store.postIts(in: worktree).last { $0.frame.contains(point) }
    }

    /// The topmost image under a world point; images sit above post-its, below browsers.
    fileprivate func image(at point: CGPoint) -> ImageRecord? {
        guard browser(at: point) == nil, fileTree(at: point) == nil else { return nil }
        return store.images(in: worktree).last { $0.frame.contains(point) }
    }

    /// The topmost card of any kind under a world point.
    private func item(at point: CGPoint) -> UUID? {
        fileTree(at: point)?.id ?? browser(at: point)?.id ?? image(at: point)?.id ?? postIt(at: point)?.id ?? card(at: point)?.id
    }

    private func frame(of id: UUID) -> CGRect? {
        record(id)?.frame ?? store.postIt(id)?.frame ?? store.image(id)?.frame ?? browsers.record(id)?.frame ?? fileTrees.record(id)?.frame
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

    static func modifiers(_ event: NSEvent) -> KeyModifiers {
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
        // Grabbing the board stops the cards organizing where they are.
        endLayoutAnimation(atTargets: false)
        let point = convert(event.locationInWindow, from: nil)
        let location = world(point)
        window?.makeFirstResponder(self)
        if let id = item(at: location), id != focusedID, !event.modifierFlags.intersection([.shift, .command]).isEmpty, handle(at: location) == nil {
            // Shift- or Command-clicking a card adds it to the selection or takes it out; the focused
            // card keeps those clicks for its own text selection.
            selection = CanvasSelection.toggling(id, in: selection)
            focusedID = nil
            return syncLayers()
        }
        if let id = item(at: location), !selection.contains(id) {
            // Clicking a card outside the selection ends it; a selected one keeps it, to move them together.
            selection = []
        }
        if let hoveredCard, let (id, index) = handle(at: location), id == hoveredCard {
            // Drawing a line from this card.
            linkDrag = LinkDrag(from: id, side: Side(rawValue: index) ?? .right, point: location)
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
        if let tree = fileTree(at: location) {
            endAddressEditing()
            endPostItEditing()
            fileTreeMouseDown(tree, at: location, point: point)
            syncLayers()
            return
        }
        if let browser = browser(at: location) {
            endAddressEditing()
            endPostItEditing()
            browserMouseDown(browser, at: location, event: event)
            syncLayers()
            return
        }
        endAddressEditing()
        if let image = image(at: location) {
            endPostItEditing()
            imageMouseDown(image, at: location, event: event)
            syncLayers()
            return
        }
        endCardRename()
        if let postIt = postIt(at: location) {
            postItMouseDown(postIt, at: location, event: event)
            syncLayers()
            return
        }
        endPostItEditing()
        let previousFocus = focusedID
        defer {
            // The cursor shows only on the focused card.
            for id in [previousFocus, focusedID].compactMap({ $0 }) where observed.contains(id) { dirty.insert(id) }
            if !dirty.isEmpty { displayLink?.isPaused = false }
        }
        guard let record = card(at: location) else {
            focusedID = nil
            if event.modifierFlags.contains(.option) {
                // Option-dragging the empty canvas pans it.
                beginPanDrag(at: point)
            } else {
                // Dragging the empty canvas draws a selection box; Shift adds to the selection.
                let base = event.modifierFlags.contains(.shift) ? selection : []
                selection = base
                marquee = (location, location, base)
            }
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
        } else if CardMetrics.close(of: frame).target(zoom: zoom).contains(location) {
            store.remove(record.id)
            observed.remove(record.id)
            focusedID = nil
        } else if location.x > frame.maxX - handle && location.y > frame.maxY - handle {
            interaction = Interaction(id: record.id, kind: .resize, start: point, frame: record.frame)
        } else if event.clickCount == 2, location.y < frame.minY + CardMetrics.titleHeight {
            // Double-clicking the title renames the card.
            beginCardRename(record.id)
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
        if var box = marquee {
            box.current = world(point)
            marquee = box
            let rect = Self.rect(box.start, box.current)
            selection = CanvasSelection.hits(itemFrames, in: rect, adding: box.base)
            return syncLayers()
        }
        if var drag = linkDrag {
            let location = world(point)
            if let snap = snapHandle(near: location, excluding: drag.from) {
                drag.point = snap.point
                drag.target = snap.card
                drag.targetSide = snap.side
            } else if let target = item(at: location), target != drag.from, let frame = frame(of: target) {
                // Over a card: the line goes to its handle nearest the pointer, and stays there.
                let handles = CardMetrics.handles(of: frame)
                let index = handles.indices.min { hypot(handles[$0].x - location.x, handles[$0].y - location.y)
                    < hypot(handles[$1].x - location.x, handles[$1].y - location.y) } ?? 0
                drag.point = handles[index]
                drag.target = target
                drag.targetSide = Side(rawValue: index)
            } else {
                drag.point = location
                drag.target = nil
                drag.targetSide = nil
            }
            linkDrag = drag
            return syncLayers()
        }
        if interaction?.kind == .move, interaction?.group == nil, let id = interaction?.id, selection.count > 1, selection.contains(id) {
            interaction?.group = Dictionary(itemFrames.filter { selection.contains($0.id) }.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }
        guard let interaction else { return }
        let dx = (point.x - interaction.start.x) / zoom, dy = (point.y - interaction.start.y) / zoom
        if let group = interaction.group {
            for (id, frame) in CanvasSelection.moved(group, by: CGSize(width: dx, height: dy)) { setFrame(frame, for: id, persist: false) }
            return syncLayers()
        }
        var frame = interaction.frame
        switch interaction.kind {
        case .move:
            frame.origin.x += dx
            frame.origin.y += dy
        case .resize:
            if let record = store.image(interaction.id) {
                frame = ImageResize.frame(resizing: frame, edges: interaction.edges, by: CGSize(width: dx, height: dy), pixelSize: record.pixelSize)
            } else if let record = browsers.record(interaction.id) {
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
        if marquee != nil {
            marquee = nil
            return syncLayers()
        }
        if let drag = linkDrag {
            let drawn = previewRope
            linkDrag = nil
            previewRope = nil
            NSCursor.pop()
            // The new line keeps the rope that was drawn, swing and all.
            if let target = drag.target, let connection = store.connect(drag.from, target, sides: (drag.side, drag.targetSide)) {
                ropes[connection.id] = drawn
            }
            return syncLayers()
        }
        guard let interaction, let frame = frame(of: interaction.id) else { return }
        for id in interaction.group?.keys.filter({ $0 != interaction.id }) ?? [] {
            if let moved = self.frame(of: id) { setFrame(moved, for: id, persist: true) }
        }
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
        if let card, CardMetrics.close(of: card.frame).target(zoom: zoom).contains(point) {
            hovered = card.id
        }
        let tree = fileTree(at: point)
        if let tree, CardMetrics.close(of: tree.frame).target(zoom: zoom).contains(point) {
            hovered = tree.id
        }
        let image = image(at: point)
        if let image, ImageCardLayout(size: image.frame.size).close.target(zoom: zoom).contains(local(point, in: image.frame)) {
            hovered = image.id
        }
        let browser = browser(at: point)
        let control = browser.flatMap { record in Self.control(at: point, in: record, zoom: zoom).map { (record.id, $0) } }
        if let browser, browser.id == focusedID, BrowserCardLayout(frame: browser.frame, record: browser).content.contains(point) {
            // Hover effects on the page follow the pointer while its card is focused.
            let page = pagePoint(point, in: browser)
            browsers.input(browser.id, ["kind": "move", "x": page.x, "y": page.y])
        }
        let postIt = postIt(at: point)
        let postItHover = postIt.map { record in
            (card: record.id, control: PostItCardLayout(size: record.frame.size).control(at: local(point, in: record.frame), zoom: zoom))
        }
        if postItHover?.card != hoveredPostIt?.card || postItHover?.control != hoveredPostIt?.control {
            hoveredPostIt = postItHover
            syncLayers()
        }
        let handle = handle(at: point)
        let showing = handle?.card ?? tree?.id ?? browser?.id ?? image?.id ?? postIt?.id ?? card?.id
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
                || hoveredPostIt != nil else { return }
        hoveredPostIt = nil
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
        if let postIt = postIt(at: location), scrollPostIt(postIt, by: event) { return }
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

    // MARK: Selection

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Focused and selected cards wear the same lifted, accent-capped frame.
    private func highlighted(_ id: UUID) -> Bool { id == focusedID || selection.contains(id) }

    /// Draws the box being dragged; selected cards show it on their own frame.
    private func syncSelection() {
        let frames = itemFrames
        let ids = Set(frames.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if let marquee {
            let rect = Self.rect(marquee.start, marquee.current)
            let corner = min(4 / zoom, rect.width / 2, rect.height / 2)
            marqueeLayer.path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            marqueeLayer.isHidden = false
        } else {
            marqueeLayer.isHidden = true
        }
    }

    /// Asks before removing the selected cards; agents and runners stop with their card.
    private func confirmDeleteSelection() {
        let ids = selection
        guard !ids.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ids.count == 1 ? L("Delete the selected card?") : L("Delete \(ids.count) selected cards?")
        alert.informativeText = L("Agents and runners in the selection stop. This can't be undone.")
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteCards(ids)
        }
    }

    private func deleteCards(_ ids: Set<UUID>) {
        endPostItEditing()
        endAddressEditing()
        endCardRename()
        for id in ids {
            if record(id) != nil {
                store.remove(id)
                observed.remove(id)
            } else if store.postIt(id) != nil {
                store.removePostIt(id)
            } else if store.image(id) != nil {
                store.removeImage(id)
            } else if browsers.record(id) != nil {
                browsers.remove(id)
            } else if fileTrees.record(id) != nil {
                fileTrees.remove(id)
            }
        }
        if let focusedID, ids.contains(focusedID) { self.focusedID = nil }
        hoveredClose = nil
        hoveredCard = nil
        hoveredControl = nil
        hoveredPostIt = nil
        selection.subtract(ids)
        syncLayers()
        window?.makeFirstResponder(self)
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
        if !selection.isEmpty, focusedID == nil {
            switch event.keyCode {
            case 51, 117: return confirmDeleteSelection()  // Delete, Forward Delete
            case 53: selection = []; return syncLayers()  // Escape
            default: break
            }
        }
        if let id = focusedBrowser { return browserKeyDown(event, to: id) }
        if let id = focusedID, let video = imageCards[id]?.video, video.handleKey(event) { return }
        guard let session = focusedSession else { return super.keyDown(with: event) }
        interacted()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let key = Self.terminalKey(event) {
            let modifiers = Self.modifiers(event)
            session.send(session.withTerminal { $0.encode(key, modifiers: modifiers) })
        } else if flags == .control, event.charactersIgnoringModifiers == "v", store.host != nil, let id = focusedID,
                  case let attachments = AgentStore.attachments(on: .general), !attachments.isEmpty {
            // The agent there reads its own clipboard, which doesn't have this Mac's picture.
            attach(attachments, to: id)
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
        // With no terminal focused and no text being edited, a pasted picture becomes a card.
        if flags == .command, event.charactersIgnoringModifiers == "v", focusedSession == nil, window?.firstResponder === self,
           let source = ImageSource.read(from: .general) {
            addImages([source], at: nil)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "c", window?.firstResponder === self,
           let id = focusedID, let record = store.image(id) {
            ImageSource.copy(record, in: store.dataFolder, to: .general)
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
        guard let id = focusedID, let session = focusedSession else { return }
        interacted()
        let pasteboard = NSPasteboard.general
        let files = AgentStore.attachments(on: pasteboard).filter { if case .file = $0 { true } else { false } }
        if let text = pasteboard.string(forType: .string), files.isEmpty {
            session.send(session.withTerminal { $0.encodePaste(text) })
        } else {
            attach(files.isEmpty ? AgentStore.attachments(on: pasteboard) : files, to: id)
        }
    }

    /// Types the paths of `sources` into the terminal, as on its machine (copied to its host first).
    private func attach(_ sources: [ImageSource], to card: UUID) {
        guard !sources.isEmpty, let session = store.sessions[card] else { return }
        let store = store
        Task {
            let paths = await store.attachmentPaths(sources, for: card)
            guard !paths.isEmpty else { return NSSound.beep() }
            session.send(session.withTerminal { $0.encodePaste(AgentStore.typed(paths)) })
        }
    }

    static func terminalKey(_ event: NSEvent) -> TerminalKey? {
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

    static func controlKey(_ event: NSEvent) -> [UInt8]? {
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
    fileprivate var hasCards: Bool { !itemFrames.isEmpty }

    /// The worktree's canvas as a template.
    fileprivate func template() -> CanvasTemplate {
        typealias Card = CanvasTemplate.Card
        let host = store.host?.id
        var cards: [(UUID, Card)] = store.agents(in: worktree).map { record in
            let runner = record.runner.map {
                Card(kind: .runner, name: record.name, frame: record.frame, command: $0.command,
                     directory: CanvasTemplate.relative($0.directory, to: worktree))
            }
            return (record.id, runner ?? Card(kind: .agent, name: record.name, frame: record.frame, provider: record.providerID,
                                              orchestrates: record.orchestrates))
        }
        cards += store.postIts(in: worktree).map { ($0.id, Card(kind: .postIt, name: $0.name, frame: $0.frame, text: $0.text)) }
        cards += browsers.browsers(in: worktree, on: host).map {
            ($0.id, Card(kind: .browser, name: $0.name, frame: $0.frame, device: $0.device.stored, url: $0.url, profile: $0.profile))
        }
        cards += fileTrees.trees(in: worktree, on: host).map { ($0.id, Card(kind: .fileTree, name: $0.name, frame: $0.frame)) }
        return CanvasTemplate(cards: cards.map(\.1), lines: CanvasTemplate.lines(worktreeConnections, among: cards.map(\.0)))
    }

    /// Removes every card of the worktree and lays `template` out in their place: agents start
    /// fresh, runners wait to be started.
    fileprivate func apply(_ template: CanvasTemplate) {
        deleteCards(Set(itemFrames.map(\.id)))
        let host = store.host?.id
        let ids = template.cards.map { card -> UUID in
            switch card.kind {
            case .agent, .runner:
                let runner = card.command.map { RunnerSpec(command: $0, directory: CanvasTemplate.resolve(card.directory ?? "", in: worktree), owner: nil) }
                let record = AgentRecord(id: UUID(), worktree: worktree, providerID: card.provider ?? AgentRecord.runnerProviderID,
                                         name: AgentRecord.uniqueName(card.name, among: store.agents(in: worktree)), frame: card.frame,
                                         runner: runner, organization: store.organizationID, orchestrates: card.orchestrates)
                store.insert(record)
                return record.id
            case .postIt:
                let record = PostItRecord(id: UUID(), worktree: worktree, name: card.name, frame: card.frame, text: card.text ?? "",
                                          organization: store.organizationID)
                store.postIts.append(record)
                store.send(.addPostIt(record))
                return record.id
            case .browser:
                let device = card.device.flatMap(BrowserDevice.init(stored:)) ?? .desktop
                // A profile deleted since falls back to the default one.
                return browsers.add(device, to: worktree, on: host, at: card.frame.origin, named: card.name, url: card.url ?? "",
                                    profile: browsers.profile(card.profile ?? BrowserProfile.defaultID).id, frame: card.frame).id
            case .fileTree:
                let record = fileTrees.add(to: worktree, on: host, at: card.frame.origin)
                fileTrees.setFrame(card.frame, for: record.id, persist: true)
                return record.id
            }
        }
        appearing.formUnion(ids)
        for line in template.lines where ids.indices.contains(line.a) && ids.indices.contains(line.b) {
            store.connect(ids[line.a], ids[line.b], sides: (line.aSide, line.bSide))
        }
        syncLayers()
        fitAgents()
    }
}

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
        let layout = RunnerChromeLayout(bounds: CGRect(origin: .zero, size: record.frame.size), command: record.runner?.shownCommand ?? "",
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
        chrome.update(bounds: CGRect(origin: .zero, size: record.frame.size), layout: layout, command: runner.shownCommand, running: running,
                      metrics: metrics, hovered: hoveredRunnerControl?.card == record.id ? hoveredRunnerControl?.control : nil, scale: scale)
    }

    /// The runner control under a world point on a runner card.
    fileprivate func runnerControl(at point: CGPoint, in record: AgentRecord) -> RunnerControl? {
        guard record.runner != nil else { return nil }
        let state = store.sessions[record.id]?.state ?? .stopped
        let local = CGPoint(x: point.x - record.frame.minX, y: point.y - record.frame.minY)
        return runnerLayout(record, state: state).0.control(at: local)
    }

    /// A port opened here for a runner's link (see `HostProxy.forward`) stays only while a
    /// runner of the worktree shown serves it there.
    func closeStaleForwards(leaving: Bool = false) {
        guard let host = store.host?.id else { return }
        let served = leaving ? [] : store.agents(in: worktree).flatMap { store.runnerStats[$0.id]?.ports ?? [] }.map { UInt16(clamping: $0.port) }
        browsers.proxy?.keepForwards(Set(served), on: host)
    }

    fileprivate func perform(_ control: RunnerControl, on record: AgentRecord) {
        switch control {
        case .toggle:
            let state = store.sessions[record.id]?.state
            if state == .running || state == .starting { store.stopRunner(record.id) } else { store.startRunner(record.id) }
        case .restart:
            store.restartRunner(record.id)
        case .link(let address):
            // Another host's localhost isn't this Mac's: it opens on a port here that leads there.
            if let host = store.host?.id, let forwarded = browsers.proxy?.forwarded(address, on: host) {
                NSWorkspace.shared.open(forwarded)
            } else if let url = URL(string: address) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: Browsers

extension BoardView {
    fileprivate var focusedBrowser: UUID? {
        focusedID.flatMap { browsers.record($0)?.id }
    }

    fileprivate func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        if store.image(id) != nil {
            store.setImageFrame(frame, for: id, persist: persist)
        } else if fileTrees.record(id) != nil {
            fileTrees.setFrame(frame, for: id, persist: persist)
        } else if browsers.record(id) != nil {
            browsers.setFrame(frame, for: id, persist: persist)
        } else if store.postIt(id) != nil {
            store.setPostItFrame(frame, for: id, persist: persist)
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

    fileprivate static func control(at point: CGPoint, in record: BrowserRecord, zoom: CGFloat) -> BrowserCardLayer.Control? {
        let layout = BrowserCardLayout(frame: record.frame, record: record)
        if layout.device.contains(point) { return .device }
        if layout.back.contains(point) { return .back }
        if layout.forward.contains(point) { return .forward }
        if layout.reload.contains(point) { return .reload }
        if layout.close.target(zoom: zoom).contains(point) { return .close }
        return nil
    }

    fileprivate func browserMouseDown(_ record: BrowserRecord, at location: CGPoint, event: NSEvent) {
        let frame = record.frame
        let layout = BrowserCardLayout(frame: frame, record: record)
        focusedID = record.id
        browsers.raise(record.id)
        let handle = CardMetrics.resizeHandle / zoom
        switch Self.control(at: location, in: record, zoom: zoom) {
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

    // MARK: Card menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = world(convert(event.locationInWindow, from: nil))
        guard let record = card(at: location), record.runner == nil else { return super.menu(for: event) }
        let menu = NSMenu()
        let rename = NSMenuItem(title: L("Rename"), action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.representedObject = record.id
        rename.target = self
        menu.addItem(rename)
        let orchestrator = NSMenuItem(title: L("Orchestrator"), action: #selector(toggleOrchestrator(_:)), keyEquivalent: "")
        orchestrator.representedObject = record.id
        orchestrator.target = self
        orchestrator.state = record.isOrchestrator ? .on : .off
        orchestrator.toolTip = L("Agents connected to it report their finished turns to it instead of to Needs you.")
        menu.addItem(orchestrator)
        return menu
    }

    @objc fileprivate func renameFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { beginCardRename(id) }
    }

    @objc fileprivate func toggleOrchestrator(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let record = record(id) else { return }
        store.setOrchestrator(id, !record.isOrchestrator)
    }

    // MARK: Card name

    fileprivate func beginCardRename(_ id: UUID) {
        guard let name = record(id)?.name ?? store.image(id)?.name else { return }
        let field = nameField ?? {
            let field = NSTextField()
            field.font = .systemFont(ofSize: Theme.Font.bodySize, weight: .semibold)
            field.focusRingType = .none
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.placeholderString = L("Agent name")
            nameField = field
            return field
        }()
        renamingCard = id
        field.placeholderString = store.image(id) != nil ? L("Image name") : L("Agent name")
        field.stringValue = name
        if field.superview == nil { addSubview(field) }
        placeNameField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    fileprivate func placeNameField() {
        guard let field = nameField, let id = renamingCard, let frame = record(id)?.frame ?? store.image(id)?.frame else { return }
        let height = store.image(id) != nil ? ImageRecord.titleHeight : CardMetrics.titleHeight
        let title = CGRect(x: frame.minX + CardMetrics.inset, y: frame.minY,
                           width: frame.width - CardMetrics.inset * 2 - CardMetrics.closeSize - 8, height: height)
        let rect = screen(title)
        field.frame = CGRect(x: rect.minX, y: rect.midY - 11, width: max(120, rect.width), height: 22)
    }

    /// Ends editing; the name is kept when `commit` and not empty.
    fileprivate func endCardRename(commit: Bool = true) {
        guard let field = nameField, let id = renamingCard else { return }
        renamingCard = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if commit, !name.isEmpty {
            if store.image(id) != nil { store.renameImage(id, to: name) } else { store.rename(id, to: name) }
        }
        window?.makeFirstResponder(self)
        syncLayers()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextField) === nameField, renamingCard != nil { endCardRename() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === nameField, renamingCard != nil {
            if selector == #selector(NSResponder.insertNewline(_:)) { endCardRename(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { endCardRename(commit: false); return true }
            return false
        }
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

// MARK: Post-its

extension BoardView {
    /// A world point in a card's own coordinates.
    fileprivate func local(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// Post-its sit above the agents and below the browsers, in their own stacking order.
    fileprivate func syncPostIts(scale: CGFloat) {
        let records = store.postIts(in: worktree)
        let ids = Set(records.map(\.id))
        for (id, card) in postItCards where !ids.contains(id) {
            card.removeFromSuperlayer()
            postItCards[id] = nil
            postItScroll[id] = nil
        }
        if let editing = editingPostIt, !ids.contains(editing) { endPostItEditing() }
        let agentCount = CGFloat(store.agents(in: worktree).count)
        for (index, record) in records.enumerated() {
            let card = postItCards[record.id] ?? {
                let card = PostItCardLayer()
                postItCards[record.id] = card
                cardsLayer.addSublayer(card)
                if appearing.remove(record.id) != nil { card.animateAppearance() }
                return card
            }()
            let layout = PostItCardLayout(size: record.frame.size)
            let editing = editingPostIt == record.id
            // What an agent wrote shows in the editor too, unless the user has typed since.
            if editing, let editor = postItEditor, !editor.isDirty, editor.text != record.text { editor.show(record.text) }
            card.zPosition = agentCount + CGFloat(index)
            card.update(frame: record.frame, record: record, layout: layout, scroll: postItScroll[record.id] ?? 0,
                        focused: highlighted(record.id), hovered: hoveredPostIt?.card == record.id ? hoveredPostIt?.control : nil,
                        editing: editing, scale: scale)
            // The text may have shrunk since it was scrolled.
            let maxScroll = max(0, card.contentHeight - layout.content.height)
            if let scroll = postItScroll[record.id], scroll > maxScroll {
                postItScroll[record.id] = maxScroll
                card.update(frame: record.frame, record: record, layout: layout, scroll: maxScroll,
                            focused: highlighted(record.id), hovered: hoveredPostIt?.card == record.id ? hoveredPostIt?.control : nil,
                            editing: editing, scale: scale)
            }
            let showsHandles = linkDrag != nil || record.id == hoveredCard
            let lit: Int? = if let linkDrag {
                linkDrag.from == record.id ? linkDrag.side.rawValue : linkDrag.target == record.id ? linkDrag.targetSide?.rawValue : nil
            } else {
                record.id == hoveredCard ? hoveredHandle : nil
            }
            card.updateHandles(visible: showsHandles, hovered: lit, linkTarget: linkDrag?.target == record.id)
        }
        placePostItEditor()
    }

    fileprivate func postItMouseDown(_ record: PostItRecord, at location: CGPoint, event: NSEvent) {
        let frame = record.frame
        let layout = PostItCardLayout(size: frame.size)
        let point = local(location, in: frame)
        let start = convert(event.locationInWindow, from: nil)
        focusedID = record.id
        store.raisePostIt(record.id)
        let handle = CardMetrics.resizeHandle / zoom
        if location.x > frame.maxX - handle && location.y > frame.maxY - handle {
            endPostItEditing()
            interaction = Interaction(id: record.id, kind: .resize, start: start, frame: frame)
            return
        }
        // Where the click falls in the text, unscrolled.
        let textPoint = CGPoint(x: point.x - layout.content.minX, y: point.y - layout.content.minY + (postItScroll[record.id] ?? 0))
        switch layout.control(at: point, zoom: zoom) {
        case .close:
            endPostItEditing()
            store.removePostIt(record.id)
            focusedID = nil
            hoveredPostIt = nil
        case .text:
            endPostItEditing()
            if let url = postItCards[record.id]?.link(at: point, layout: layout, scroll: postItScroll[record.id] ?? 0) {
                NSWorkspace.shared.open(url)
            } else if event.clickCount == 2 {
                // Double-clicking the rendered text writes it, where it was clicked.
                beginPostItEditing(on: record.id, at: textPoint)
            } else {
                interaction = Interaction(id: record.id, kind: .move, start: start, frame: frame)
            }
        case nil:
            // The title bar and the paper around the text move the card.
            endPostItEditing()
            interaction = Interaction(id: record.id, kind: .move, start: start, frame: frame)
        }
    }

    /// Scrolls a post-it's text when it overflows; false when it doesn't, so the board pans.
    fileprivate func scrollPostIt(_ record: PostItRecord, by event: NSEvent) -> Bool {
        let layout = PostItCardLayout(size: record.frame.size)
        let location = world(convert(event.locationInWindow, from: nil))
        let maxScroll = max(0, (postItCards[record.id]?.contentHeight ?? 0) - layout.content.height)
        guard maxScroll > 0, layout.content.contains(local(location, in: record.frame)) else { return false }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let current = postItScroll[record.id] ?? 0
        postItScroll[record.id] = min(max(current - event.scrollingDeltaY * factor / zoom, 0), maxScroll)
        syncLayers()
        return true
    }

    // MARK: Writing

    /// Opens the text view over the post-it, the cursor at `point` (text coordinates) or at the end.
    fileprivate func beginPostItEditing(on id: UUID, at point: CGPoint?) {
        guard let record = store.postIt(id) else { return }
        if editingPostIt != id { endPostItEditing() }
        let editor = postItEditor ?? {
            let editor = PostItEditor()
            editor.onEscape = { [weak self] in
                self?.endPostItEditing()
                self?.syncLayers()
            }
            postItEditor = editor
            return editor
        }()
        editor.onWrite = { [weak self] text in self?.store.writePostIt(text, on: id) }
        editor.onFormat = { [weak self] format in
            if self?.controller?.postItFormat != format { self?.controller?.postItFormat = format }
        }
        if editingPostIt != id {
            editingPostIt = id
            editor.show(record.text)
        }
        if editor.scrollView.superview == nil { addSubview(editor.scrollView) }
        syncLayers()
        editor.scroll = postItScroll[id] ?? 0
        editor.placeCursor(at: point)
        window?.makeFirstResponder(editor.textView)
    }

    fileprivate func placePostItEditor() {
        guard let editor = postItEditor, let id = editingPostIt, let record = store.postIt(id) else { return }
        let content = PostItCardLayout(size: record.frame.size).content
        editor.place(screen(content.offsetBy(dx: record.frame.minX, dy: record.frame.minY)), zoom: zoom)
    }

    /// Sends what was written and closes the text view; the card shows the text again.
    fileprivate func endPostItEditing() {
        guard let editor = postItEditor, let id = editingPostIt else { return }
        editor.flush()
        postItScroll[id] = editor.scroll
        editingPostIt = nil
        controller?.postItFormat = nil
        let responder = window?.firstResponder
        editor.scrollView.removeFromSuperview()
        if responder === editor.textView { window?.makeFirstResponder(self) }
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
/// Where the board looked in each worktree, saved in the user defaults shortly after it moves.
@MainActor
private final class CameraMemory {
    private static let key = "boardCameras"
    private var cameras: [String: Camera]
    private var saveWork: DispatchWorkItem?

    init() {
        let stored = AppDefaults.shared.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        cameras = stored.compactMapValues { values in
            values.count == 3 ? Camera(zoom: values[0], pan: CGPoint(x: values[1], y: values[2])) : nil
        }
    }

    subscript(worktree: String) -> Camera? {
        get { cameras[worktree] }
        set {
            guard cameras[worktree] != newValue else { return }
            cameras[worktree] = newValue
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        let stored = cameras.mapValues { [Double($0.zoom), Double($0.pan.x), Double($0.pan.y)] }
        AppDefaults.shared.set(stored, forKey: Self.key)
    }
}

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

/// Springs driving cards toward where Organize put them, one per card, stepped once per
/// display refresh. A touch under critical damping, so they settle with a soft overshoot.
private struct LayoutAnimation {
    struct Motion {
        var position: CGPoint
        var velocity: CGVector = .zero
        var target: CGPoint
    }

    var motions: [UUID: Motion] = [:]
    var time: CFTimeInterval?

    private static let stiffness: CGFloat = 200
    private static let damping: CGFloat = 0.85 * 2 * sqrt(stiffness)

    /// Sends `id` toward `target`, keeping its speed if it was already moving.
    mutating func move(_ id: UUID, from position: CGPoint, to target: CGPoint) {
        if motions[id] != nil {
            motions[id]?.target = target
        } else {
            motions[id] = Motion(position: position, target: target)
        }
    }

    mutating func step(by elapsed: CFTimeInterval) {
        let substeps = max(1, Int((elapsed * 480).rounded(.up)))
        let dt = CGFloat(elapsed) / CGFloat(substeps)
        for id in motions.keys {
            guard var motion = motions[id] else { continue }
            for _ in 0..<substeps {
                motion.velocity.dx += (-Self.stiffness * (motion.position.x - motion.target.x) - Self.damping * motion.velocity.dx) * dt
                motion.velocity.dy += (-Self.stiffness * (motion.position.y - motion.target.y) - Self.damping * motion.velocity.dy) * dt
                motion.position.x += motion.velocity.dx * dt
                motion.position.y += motion.velocity.dy * dt
            }
            motions[id] = motion
        }
    }

    var isSettled: Bool {
        motions.values.allSatisfy {
            hypot($0.position.x - $0.target.x, $0.position.y - $0.target.y) < 0.5 && hypot($0.velocity.dx, $0.velocity.dy) < 2
        }
    }
}

// MARK: - Layers

/// One agent card: chrome as Core Animation layers, the terminal as a layer showing its region
/// of the board's shared surface, which exists only while the card is on screen.
private final class CardLayer: CALayer {
    private let bar = CardTitleBar()
    private var focused = false
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
        cursor.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.35)
        cursor.isHidden = true
        dim.backgroundColor = BoardPalette.rgb(Theme.Hex.white, 0.75)
        status.fontSize = Theme.Font.labelSize
        status.truncationMode = .end
        status.alignmentMode = .center
        [bar, closeHover, closeGlyph, cursor, dim, status].forEach(addSublayer)
        CardFrame.reveal([closeHover, closeGlyph], visible: false)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: CardMetrics.handleSize, height: CardMetrics.handleSize)
            handle.cornerRadius = CardMetrics.handleSize / 2
            handle.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
            // A handle is a control: the white ring sets it off from the card edge it sits on.
            handle.borderColor = BoardPalette.card
            handle.borderWidth = 2
            handle.isHidden = true
            handle.zPosition = 10
            addSublayer(handle)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(frame: CGRect, title text: String, detail: String?, icon: CardIcon, status cardStatus: CardStatus, kind: CardStatus.Kind, state: AgentSession.State,
                focused: Bool, closeHovered: Bool, starting: String, message: String?, scale: CGFloat) {
        self.frame = frame
        self.state = state
        self.focused = focused
        CardFrame.style(self, focused: focused)
        status.contentsScale = scale

        let ink = BoardPalette.ink
        let font = NSFont.systemFont(ofSize: Theme.Font.labelSize)
        let line = ceil(font.ascender - font.descender) + 2
        let close = CardMetrics.close(of: bounds)
        bar.update(size: bounds.size, icon: icon, status: cardStatus, kind: kind, title: text, detail: detail, focused: focused,
                   reserve: bounds.width - close.minX + titleReserve + 8, scale: scale)
        CardFrame.closeButton(closeHover, closeGlyph, in: close, hovered: closeHovered, scale: scale)

        // A launching, finished or failed agent says so over its terminal.
        var area = CardMetrics.content(of: bounds)
        area = CGRect(x: area.minX, y: contentTop, width: area.width, height: max(0, area.maxY - contentTop))
        dim.frame = area
        dim.isHidden = message == nil
        let label = message ?? (state == .starting ? starting : nil)
        status.isHidden = label == nil
        status.string = label
        status.font = NSFont.systemFont(ofSize: Theme.Font.labelSize, weight: message == nil ? .medium : .semibold)
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
        // A line's target lights up with the highlighted ring, like focus.
        CardFrame.style(self, focused: focused || linkTarget)
        CardFrame.reveal([closeHover, closeGlyph], visible: visible || focused)
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

/// One line between two cards, in world coordinates: the rope as a smooth curve, a dot where it
/// meets each card, and, while hovered, a knob in the middle that removes it.
private final class LinkLayer: CALayer {
    private let line = CAShapeLayer()
    private let ends = CAShapeLayer()
    private let knob = CALayer()
    private let knobGlyph = CATextLayer()
    private var route: Route?
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
        knob.shadowOpacity = Theme.Shadow.opacity
        knob.shadowRadius = Theme.Shadow.radius
        knob.shadowOffset = CGSize(width: 0, height: Theme.Shadow.y)
        knob.isHidden = true
        knobGlyph.string = "✕"
        knobGlyph.font = NSFont.systemFont(ofSize: Theme.Font.captionSize, weight: .semibold)
        knobGlyph.fontSize = Theme.Font.captionSize
        knobGlyph.alignmentMode = .center
        knobGlyph.foregroundColor = BoardPalette.rgb(BoardPalette.ink, 0.7)
        let line = ceil(NSFont.systemFont(ofSize: Theme.Font.captionSize).ascender - NSFont.systemFont(ofSize: Theme.Font.captionSize).descender)
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

    /// A smooth curve through `points` (Catmull-Rom, as cubic Béziers).
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 0..<points.count - 1 {
            let p0 = points[max(index - 1, 0)], p1 = points[index], p2 = points[index + 1], p3 = points[min(index + 2, points.count - 1)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}

// MARK: - File trees

extension BoardView {
    /// File tree cards sit above every other card: their files are views over the board.
    fileprivate func syncFileTrees(scale: CGFloat) {
        let records = fileTrees.trees(in: worktree, on: store.host?.id)
        let ids = Set(records.map(\.id))
        for (id, card) in fileTreeCards where !ids.contains(id) {
            card.removeFromSuperlayer()
            fileTreeCards[id] = nil
        }
        for (id, views) in fileTreeViews where !ids.contains(id) {
            views.content.removeFromSuperview()
            views.bar.removeFromSuperview()
            fileTreeViews[id] = nil
        }
        let below = CGFloat(store.agents(in: worktree).count + store.postIts(in: worktree).count + store.images(in: worktree).count
            + browsers.browsers(in: worktree, on: store.host?.id).count)
        for (index, record) in records.enumerated() {
            let card = fileTreeCards[record.id] ?? {
                let card = FileTreeCardLayer()
                fileTreeCards[record.id] = card
                cardsLayer.addSublayer(card)
                if appearing.remove(record.id) != nil { card.animateAppearance() }
                return card
            }()
            card.zPosition = below + CGFloat(index)
            card.update(frame: record.frame, name: record.name, focused: highlighted(record.id), closeHovered: hoveredClose == record.id,
                        scale: scale)
            let lit: Int? = if let linkDrag {
                linkDrag.from == record.id ? linkDrag.side.rawValue : linkDrag.target == record.id ? linkDrag.targetSide?.rawValue : nil
            } else {
                record.id == hoveredCard ? hoveredHandle : nil
            }
            card.updateHandles(visible: linkDrag != nil || record.id == hoveredCard, hovered: lit, linkTarget: linkDrag?.target == record.id)

            let views = fileTreeViews[record.id] ?? {
                let host = FileTreeHost()
                let content = NSHostingView(rootView: Zoomed(host: host) {
                    FileTreeView(store: fileTrees, id: record.id, model: fileTrees.browser(for: record))
                })
                let barHost = FileTreeHost()
                let bar = NSHostingView(rootView: Zoomed(host: barHost) { SendAnnotationsBar(store: fileTrees, id: record.id) })
                let views = (host: host, content: content as NSView, bar: bar as NSView, barHost: barHost)
                fileTreeViews[record.id] = views
                return views
            }()
            if views.content.superview == nil { addSubview(views.content) }
            let content = CardMetrics.content(of: record.frame)
            if views.host.size != content.size { views.host.size = content.size }
            if views.host.zoom != zoom { views.host.zoom = zoom }
            views.content.frame = screen(content)

            let hasNotes = !(fileTrees.annotations[record.id]?.isEmpty ?? true)
            if hasNotes {
                let bar = CGRect(x: record.frame.midX - 140, y: record.frame.maxY + 12, width: 280, height: 44)
                if views.barHost.size != bar.size { views.barHost.size = bar.size }
                if views.barHost.zoom != zoom { views.barHost.zoom = zoom }
                if views.bar.superview == nil { addSubview(views.bar) }
                views.bar.frame = screen(bar)
            } else if views.bar.superview != nil {
                views.bar.removeFromSuperview()
            }
        }
    }

    fileprivate func fileTreeMouseDown(_ record: FileTreeRecord, at location: CGPoint, point: CGPoint) {
        focusedID = record.id
        fileTrees.raise(record.id)
        let frame = record.frame
        let handle = CardMetrics.resizeHandle / zoom
        if CardMetrics.close(of: frame).target(zoom: zoom).contains(location) {
            fileTrees.remove(record.id)
            focusedID = nil
            hoveredClose = nil
        } else if location.x > frame.maxX - handle && location.y > frame.maxY - handle {
            interaction = Interaction(id: record.id, kind: .resize, start: point, frame: frame)
        } else {
            // The title bar and the card's margins move it.
            interaction = Interaction(id: record.id, kind: .move, start: point, frame: frame)
        }
    }
}

// MARK: Images

extension BoardView {
    /// A host's picture arrived, or couldn't: its cards are made again, to load it from the start.
    fileprivate func mediaChanged(_ file: String) {
        for record in store.images where record.file == file {
            imageCards[record.id]?.forget()
            imageCards[record.id]?.removeFromSuperlayer()
            imageCards[record.id] = nil
        }
        syncLayers()
    }

    /// Images sit above the post-its and below the browsers, in their own stacking order.
    fileprivate func syncImages(scale: CGFloat) {
        let records = store.images(in: worktree)
        let ids = Set(records.map(\.id))
        for (id, card) in imageCards where !ids.contains(id) {
            card.video?.pause()
            if store.image(id) == nil { card.forget() }
            card.removeFromSuperlayer()
            imageCards[id] = nil
        }
        let below = CGFloat(store.agents(in: worktree).count + store.postIts(in: worktree).count)
        for (index, record) in records.enumerated() {
            let card = imageCards[record.id] ?? {
                let card = ImageCardLayer()
                imageCards[record.id] = card
                cardsLayer.addSublayer(card)
                if appearing.remove(record.id) != nil { card.animateAppearance() }
                return card
            }()
            card.zPosition = below + CGFloat(index)
            let visible = screen(record.frame).intersects(bounds)
            // A picture kept on another host is brought here the first time its card shows.
            if visible { store.fetchMedia(record) }
            card.update(frame: record.frame, record: record, dataFolder: store.dataFolder, focused: highlighted(record.id),
                        closeHovered: hoveredClose == record.id, renaming: renamingCard == record.id, scale: scale,
                        visible: visible, note: store.mediaNotes[record.file], sending: store.sendingMedia.contains(record.file))
            let showsHandles = linkDrag != nil || record.id == hoveredCard
            let lit: Int? = if let linkDrag {
                linkDrag.from == record.id ? linkDrag.side.rawValue : linkDrag.target == record.id ? linkDrag.targetSide?.rawValue : nil
            } else {
                record.id == hoveredCard ? hoveredHandle : nil
            }
            card.updateHandles(visible: showsHandles, hovered: lit, linkTarget: linkDrag?.target == record.id)
        }
    }

    fileprivate func imageMouseDown(_ record: ImageRecord, at location: CGPoint, event: NSEvent) {
        let frame = record.frame
        let start = convert(event.locationInWindow, from: nil)
        focusedID = record.id
        store.raiseImage(record.id)
        let point = local(location, in: frame)
        let edges = ImageResize.edges(at: location, in: frame, reach: 8 / zoom)
        let corner = CardMetrics.resizeHandle / zoom
        if ImageCardLayout(size: frame.size).close.target(zoom: zoom).contains(point) {
            endCardRename()
            store.removeImage(record.id)
            focusedID = nil
            hoveredClose = nil
        } else if record.isVideo, let card = imageCards[record.id],
                  card.video?.click(at: point, picture: ImageCardLayout(size: frame.size).picture, dragged: { seek in
                      trackMouse { seek(self.local(self.world(self.convert($0.locationInWindow, from: nil)), in: frame)) }
                  }) == true {
            // A video control: play, mute, loop or the scrub track.
            endCardRename()
        } else if !edges.isEmpty || (location.x > frame.maxX - corner && location.y > frame.maxY - corner) {
            endCardRename()
            interaction = Interaction(id: record.id, kind: .resize, start: start, frame: frame, edges: edges.isEmpty ? [.right, .bottom] : edges)
        } else if event.clickCount == 2, point.y < ImageRecord.titleHeight {
            // Double-clicking the title renames the image.
            beginCardRename(record.id)
        } else {
            endCardRename()
            interaction = Interaction(id: record.id, kind: .move, start: start, frame: frame)
        }
    }

    /// VoiceOver reaches the controls of the video cards, which are layers, through these.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard let window else { return children }
        for record in store.images(in: worktree) where record.isVideo {
            guard let video = imageCards[record.id]?.video else { continue }
            let picture = ImageCardLayout(size: record.frame.size).picture.offsetBy(dx: record.frame.minX, dy: record.frame.minY)
            children += video.accessibilityElements(parent: self, name: record.name) { local in
                window.convertToScreen(self.convert(self.screen(local.offsetBy(dx: picture.minX, dy: picture.minY)), to: nil))
            }
        }
        return children + headerAccessibility(in: window)
    }

    /// The title-bar controls of agent, runner and browser cards, which are layers, for
    /// VoiceOver and keyboard access; each card's close button also says the card's state.
    private func headerAccessibility(in window: NSWindow) -> [NSAccessibilityElement] {
        let onScreen = { (rect: CGRect) in window.convertToScreen(self.convert(self.screen(rect), to: nil)) }
        func button(_ label: String, _ rect: CGRect, _ press: @escaping () -> Void) -> VideoAccessibilityControl {
            VideoAccessibilityControl(role: .button, label: label, frame: onScreen(rect), parent: self, press: press)
        }
        var elements: [NSAccessibilityElement] = []
        for record in store.agents(in: worktree) {
            let id = record.id
            let close = button(L("Close \(record.name)"), CardMetrics.close(of: record.frame)) { [weak self] in
                self?.store.remove(id)
                self?.observed.remove(id)
            }
            close.setAccessibilityValue(store.cardStatus(record).label)
            elements.append(close)
            guard record.runner != nil else { continue }
            let state = store.sessions[id]?.state ?? .stopped
            let layout = runnerLayout(record, state: state).0
            let running = state == .running || state == .starting
            let origin = record.frame.origin
            elements.append(button(running ? L("Stop \(record.name)") : L("Start \(record.name)"), layout.toggle.offsetBy(dx: origin.x, dy: origin.y)) { [weak self] in
                self?.perform(.toggle, on: record)
            })
            elements.append(button(L("Restart \(record.name)"), layout.restart.offsetBy(dx: origin.x, dy: origin.y)) { [weak self] in
                self?.perform(.restart, on: record)
            })
        }
        for record in browsers.browsers(in: worktree, on: store.host?.id) {
            let id = record.id
            let layout = BrowserCardLayout(frame: record.frame, record: record)
            elements.append(button(L("Back"), layout.back) { [weak self] in self?.browsers.go("back", on: id) })
            elements.append(button(L("Forward"), layout.forward) { [weak self] in self?.browsers.go("forward", on: id) })
            elements.append(button(L("Reload"), layout.reload) { [weak self] in self?.browsers.go("reload", on: id) })
            elements.append(button(L("Close \(record.name)"), layout.close) { [weak self] in self?.browsers.remove(id) })
        }
        return elements
    }

    /// Follows the pressed mouse until it goes up, handing over each drag.
    fileprivate func trackMouse(_ moved: (NSEvent) -> Void) {
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged { moved(event) }
    }

    // MARK: Dropping files

    private func droppedImages(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(ImageSource.isMediaFile)
    }

    /// The terminal card a drop lands on, if any.
    private func droppedCard(_ info: NSDraggingInfo) -> UUID? {
        guard let id = card(at: world(convert(info.draggingLocation, from: nil)))?.id, store.sessions[id] != nil else { return nil }
        return id
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        if droppedCard(info) != nil, !AgentStore.attachments(on: info.draggingPasteboard).isEmpty { return .copy }
        return droppedImages(info).isEmpty ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Onto a terminal, any file is handed to its program, as a terminal types a dropped path.
        if let id = droppedCard(sender) {
            let attachments = AgentStore.attachments(on: sender.draggingPasteboard)
            guard !attachments.isEmpty else { return false }
            attach(attachments, to: id)
            return true
        }
        let urls = droppedImages(sender)
        guard !urls.isEmpty else { return false }
        addImages(urls.map(ImageSource.file), at: world(convert(sender.draggingLocation, from: nil)))
        return true
    }
}
