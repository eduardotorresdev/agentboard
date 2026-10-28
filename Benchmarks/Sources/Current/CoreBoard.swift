import AgentRuntime
import AppKit
import EngineKit
import Metal
import TerminalCore
import TerminalRenderer

/// The app's terminal engine (`TerminalCore`), fed bytes directly.
public final class CoreTerminal: TerminalUnderTest {
    private let terminal: Terminal
    private let theme = TerminalTheme.light

    public init(cols: Int, rows: Int, scrollback: Int) {
        terminal = Terminal(cols: cols, rows: rows, scrollback: scrollback)
    }

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        terminal.feed(bytes)
        _ = terminal.takeOutput()
    }

    public func screenText() -> [String] { terminal.screenText() }

    public func screenStyles() -> [[String]] {
        (0..<terminal.rows).map { y in
            (0..<terminal.cols).compactMap { x -> String? in
                let cell = terminal.cell(column: x, row: y)
                guard cell.width != .tail else { return nil }
                let colors = theme.colors(of: cell)
                func hex(_ color: UInt32) -> String { String(format: "%06x", TerminalTheme.hex(color)) }
                let text = terminal.text(of: cell) ?? " "
                return "\(text)|\(hex(colors.fg))|\(hex(colors.bg))|\(cell.attributes.contains(.bold) ? "b" : "")"
            }
        }
    }

    public var cursor: (col: Int, row: Int) { (terminal.cursor.column, terminal.cursor.row) }
}

/// The board as `BoardView` renders it: a frame redraws only the terminals that changed. With
/// the `shared` surface they all go into one `SharedSurface` in one render pass; with `own`
/// each has its own surface of exactly its size (a `CAMetalLayer` drawable in the app, a
/// texture here).
/// The chrome (cards, shadows, grid, cursor) is Core Animation layers composited by the window
/// server, so it costs this process no rendering.
public final class CoreBoard: BoardUnderTest {
    public static let surfaces = ["shared", "own"]
    private let offscreen: Offscreen
    private let presenter: TerminalPresenter
    private let glyphs: GlyphCache
    private let theme = TerminalTheme.light
    private let scale: CGFloat
    private let frames: [CGRect]
    private var sessions: [AgentSession] = []
    private var layers: [Int: TerminalLayer] = [:]
    private var surfaces: [Int: MTLTexture] = [:]
    private let shared: SharedSurface<Int>?
    private var dirty = Set<Int>()
    public var needsDisplay: Bool { !dirty.isEmpty }
    public var cardsVisible = true {
        didSet {
            sessions.forEach { $0.isObserved = cardsVisible }
            if cardsVisible {
                dirty = Set(frames.indices)
            } else {
                layers.removeAll()
                surfaces.removeAll()
                shared?.release()
                dirty.removeAll()
            }
        }
    }

    public init(offscreen: Offscreen, cards: [CGRect], scale: CGFloat, scrollback: Int, surface: String) {
        self.offscreen = offscreen
        self.scale = scale
        frames = cards
        presenter = TerminalPresenter(device: offscreen.device)!
        shared = surface == "shared" ? SharedSurface(device: offscreen.device) : nil
        glyphs = GlyphCache(device: offscreen.device, font: NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular))!
        for (index, frame) in cards.enumerated() {
            let content = Self.content(of: frame)
            let cols = max(2, Int(content.width * scale) / glyphs.cellWidth)
            let rows = max(1, Int(content.height * scale) / glyphs.cellHeight)
            let session = AgentSession(cols: cols, rows: rows)
            session.onChange = { [weak self] in self?.dirty.insert(index) }
            session.isObserved = true
            sessions.append(session)
            dirty.insert(index)
        }
    }

    public func feed(card: Int, _ bytes: UnsafeRawBufferPointer) {
        sessions[card].withTerminal {
            $0.feed(bytes)
            _ = $0.takeOutput()
        }
        if cardsVisible { dirty.insert(card) }
    }

    public func launch(card: Int, executable: String, arguments: [String]) {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        sessions[card].start(LaunchSpec(executable: executable, arguments: arguments, environment: environment,
                                        directory: FileManager.default.currentDirectoryPath))
    }

    public func stop() { sessions.forEach { $0.stop() } }

    public func gridSize(card: Int) -> (cols: Int, rows: Int) {
        sessions[card].withTerminal { ($0.cols, $0.rows) }
    }

    /// Redraws the terminals that changed since the last frame, each into its own surface.
    public func render() -> MTLCommandBuffer {
        presenter.beginFrame()
        var targets: [TerminalPresenter.Target] = []
        var pending = Set<Int>()
        var shownFrom: [Int: Int] = [:]
        if let shared, cardsVisible {
            let sizes = Dictionary(uniqueKeysWithValues: sessions.indices.map { index in
                (index, sessions[index].withTerminal { ($0.cols * glyphs.cellWidth, $0.rows * glyphs.cellHeight) })
            })
            dirty.formUnion(shared.arrange(sizes))
        }
        for index in dirty.sorted() {
            let session = sessions[index]
            if session.isMidUpdate {
                pending.insert(index)
                continue
            }
            let layer = layers[index] ?? TerminalLayer(device: offscreen.device)
            layers[index] = layer
            let size = session.withTerminalForDisplay { terminal -> (Int, Int) in
                _ = layer.update(from: terminal, theme: theme, glyphs: glyphs)
                return (terminal.cols * glyphs.cellWidth, terminal.rows * glyphs.cellHeight)
            }
            if let shared, let target = shared.target(for: index) {
                targets.append(TerminalPresenter.Target(layer: layer, texture: target.texture,
                                                        origin: SIMD2(target.region.x, target.region.y)))
                shownFrom[index] = target.buffer
                continue
            }
            let surface = surface(index, width: size.0, height: size.1)
            targets.append(TerminalPresenter.Target(layer: layer, texture: surface))
        }
        dirty = pending
        // The app shows each drawn terminal from its new buffer once the GPU is done.
        if let shared {
            for (index, buffer) in shownFrom { _ = shared.show(index, from: buffer) }
        }
        // An empty frame still hands back a finished command buffer, like the app's idle tick.
        if let commands = presenter.render(targets, glyphs: glyphs, background: theme.clearColor) { return commands }
        let idle = offscreen.queue.makeCommandBuffer()!
        idle.commit()
        return idle
    }

    /// Copies every card's surface onto the offscreen target at its place on the board.
    public func renderSnapshot() -> MTLCommandBuffer {
        dirty = Set(frames.indices)
        render().waitUntilCompleted()
        let commands = offscreen.queue.makeCommandBuffer()!
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = offscreen.texture
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = offscreen.pass.colorAttachments[0].clearColor
        commands.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        let blit = commands.makeBlitCommandEncoder()!
        func copy(_ texture: MTLTexture, from source: MTLOrigin, size: MTLSize, card index: Int) {
            let origin = Self.content(of: frames[index]).origin
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: source, sourceSize: size, to: offscreen.texture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: Int(origin.x * scale), y: Int(origin.y * scale), z: 0))
        }
        for (index, surface) in surfaces {
            copy(surface, from: MTLOrigin(), size: MTLSize(width: surface.width, height: surface.height, depth: 1), card: index)
        }
        if let shared {
            for index in frames.indices {
                // Read back from the buffer the terminal is shown from: the one not targeted next.
                guard let next = shared.target(for: index) else { continue }
                let region = next.region
                copy(shared.buffers[1 - next.buffer].texture, from: MTLOrigin(x: region.x, y: region.y, z: 0),
                     size: MTLSize(width: region.width, height: region.height, depth: 1), card: index)
            }
        }
        blit.endEncoding()
        commands.commit()
        return commands
    }

    private func surface(_ index: Int, width: Int, height: Int) -> MTLTexture {
        if let surface = surfaces[index], surface.width == width, surface.height == height { return surface }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let surface = offscreen.device.makeTexture(descriptor: descriptor)!
        surfaces[index] = surface
        return surface
    }

    private static func content(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + 12, y: frame.minY + 34, width: frame.width - 24, height: frame.height - 34 - 12)
    }
}
