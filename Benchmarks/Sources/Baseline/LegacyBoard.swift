import AppKit
import EngineKit
import Metal
import SwiftTerm

/// SwiftTerm's headless `Terminal`, as the app used it before the rewrite.
public final class LegacyTerminal: TerminalUnderTest, TerminalDelegate {
    private var terminal: Terminal!

    public init(cols: Int, rows: Int, scrollback: Int) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        terminal.feed(buffer: ArraySlice(bytes.bindMemory(to: UInt8.self)))
    }

    public func screenText() -> [String] {
        terminal.contentSnapshot(region: .viewport).rows.map { row in
            var text = ""
            for cell in row.cells where cell.width > 0 { text += Self.visible(cell.text) }
            return String(text.reversed().drop { $0 == " " }.reversed())
        }
    }

    public func screenStyles() -> [[String]] {
        terminal.contentSnapshot(region: .viewport).rows.map { row in
            row.cells.filter { $0.width > 0 }.map { cell in
                let a = cell.attribute
                func hex(_ c: SIMD4<Float>) -> String { String(format: "%02x%02x%02x", Int(c.x * 255 + 0.5), Int(c.y * 255 + 0.5), Int(c.z * 255 + 0.5)) }
                var fg = LegacyPalette.color(a.fg, isForeground: true), bg = LegacyPalette.color(a.bg, isForeground: false)
                if a.style.contains(.inverse) { swap(&fg, &bg) }
                return "\(Self.visible(cell.text))|\(hex(fg))|\(hex(bg))|\(a.style.contains(.bold) ? "b" : "")"
            }
        }
    }

    /// SwiftTerm stores never-written cells as NUL; on screen they are blanks.
    private static func visible(_ text: String) -> String {
        text.isEmpty || text == "\u{0}" ? " " : text
    }

    public var cursor: (col: Int, row: Int) {
        let snapshot = terminal.contentSnapshot(region: .viewport)
        return (snapshot.cursorColumn, snapshot.cursorRow - (snapshot.rows.first?.absoluteRow ?? 0))
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// The board as `BoardView.draw(in:)` built it before the rewrite: every frame collects grid,
/// chrome and cell quads on the CPU (cells re-snapshotted per dirty session) and uploads them all.
public final class LegacyBoard: BoardUnderTest {
    private let offscreen: Offscreen
    private let renderer: LegacyRenderer
    private let atlas: LegacyAtlas
    private let scale: CGFloat
    private let frames: [CGRect]
    private var sessions: [LegacySession] = []
    private var cells: [Int: [LegacyQuad]] = [:]
    public private(set) var needsDisplay = true
    public var cardsVisible = true
    /// The whole board, chrome included, renders into one target.
    public static let surfaces = ["board"]

    public init(offscreen: Offscreen, cards: [CGRect], scale: CGFloat, scrollback: Int, surface: String) {
        self.offscreen = offscreen
        self.scale = scale
        frames = cards
        renderer = LegacyRenderer(device: offscreen.device, pixelFormat: .bgra8Unorm)!
        atlas = LegacyAtlas(device: offscreen.device, scale: scale)!
        for frame in cards {
            let content = Self.content(of: frame)
            let cols = max(2, Int(content.width * scale) / atlas.cellWidth)
            let rows = max(1, Int(content.height * scale) / atlas.cellHeight)
            let session = LegacySession(cols: cols, rows: rows)
            // The old AgentStore forwarded every session change to the board, visible or not.
            session.onChange = { [weak self] in self?.needsDisplay = true }
            sessions.append(session)
        }
    }

    public func feed(card: Int, _ bytes: UnsafeRawBufferPointer) {
        sessions[card].dataReceived(slice: ArraySlice(bytes.bindMemory(to: UInt8.self)))
        needsDisplay = true
    }

    public func launch(card: Int, executable: String, arguments: [String]) {
        sessions[card].start(executable: executable, args: arguments, directory: FileManager.default.currentDirectoryPath,
                             path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    }

    public func stop() { sessions.forEach { $0.stop() } }

    public func gridSize(card: Int) -> (cols: Int, rows: Int) {
        (sessions[card].terminal.cols, sessions[card].terminal.rows)
    }

    public func render() -> MTLCommandBuffer {
        needsDisplay = false
        var quads: [LegacyQuad] = []
        quads.reserveCapacity(4096)
        appendGrid(to: &quads)
        if cardsVisible {
            for index in frames.indices { appendCard(index, to: &quads) }
        }
        let viewport = SIMD2(Float(offscreen.texture.width), Float(offscreen.texture.height))
        return renderer.draw(quads, atlas: atlas, pass: offscreen.pass, viewport: viewport)!
    }

    // MARK: Verbatim from the old BoardView

    private static func content(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + 12, y: frame.minY + 34, width: frame.width - 24, height: frame.height - 34 - 12)
    }

    private func appendGrid(to quads: inout [LegacyQuad]) {
        let step = 24 * scale
        let size = CGSize(width: offscreen.texture.width, height: offscreen.texture.height)
        let minor = LegacyPalette.rgb(0x2E, 0x1F, 0x6B, 0.05), major = LegacyPalette.rgb(0x2E, 0x1F, 0x6B, 0.09)
        for i in 0...Int(ceil(size.width / step)) {
            quads.append(LegacyQuad(.solid, SIMD4(Float(CGFloat(i) * step), 0, 1, Float(size.height)), color: i % 5 == 0 ? major : minor))
        }
        for i in 0...Int(ceil(size.height / step)) {
            quads.append(LegacyQuad(.solid, SIMD4(0, Float(CGFloat(i) * step), Float(size.width), 1), color: i % 5 == 0 ? major : minor))
        }
    }

    private func appendCard(_ index: Int, to quads: inout [LegacyQuad]) {
        let frame = frames[index], session = sessions[index]
        let s = Float(scale)
        func px(_ rect: CGRect) -> SIMD4<Float> { SIMD4(Float(rect.minX) * s, Float(rect.minY) * s, Float(rect.width) * s, Float(rect.height) * s) }
        let ink = LegacyPalette.rgb(0x2E, 0x1F, 0x6B)
        quads.append(LegacyQuad(.shadow, px(frame.offsetBy(dx: 0, dy: 5)), color: SIMD4(ink.x, ink.y, ink.z, 0.08), radius: 14 * s, softness: 14 * s))
        quads.append(LegacyQuad(.rounded, px(frame), color: LegacyPalette.background, radius: 14 * s))
        let dot = CGRect(x: frame.minX + 14, y: frame.minY + 17 - 3.5, width: 7, height: 7)
        quads.append(LegacyQuad(.rounded, px(dot), color: LegacyPalette.rgb(0x6E, 0x56, 0xCF), radius: 3.5 * s))
        appendLabel("Claude", face: .labelBold, at: CGPoint(x: dot.maxX + 8, y: frame.minY + 17), to: &quads)
        appendLabel("✕", face: .label, at: CGPoint(x: frame.maxX - 18, y: frame.minY + 17), to: &quads)

        let origin = SIMD2(Float((frame.minX + 12) * scale).rounded(), Float((frame.minY + 34) * scale).rounded())
        if session.takeDirty() || cells[index] == nil {
            cells[index] = buildCells(session.snapshot(), showCursor: index == 0 && session.cursorVisible)
        }
        for quad in cells[index] ?? [] { quads.append(quad.offset(by: origin, alpha: 1)) }
    }

    private func appendLabel(_ text: String, face: LegacyAtlas.Face, at point: CGPoint, to quads: inout [LegacyQuad]) {
        guard let entry = atlas.entry(text, face: face) else { return }
        let x = Float(point.x * scale), y = Float(point.y * scale) - entry.uv.w / 2
        quads.append(LegacyQuad(.glyph, SIMD4(x.rounded(), y.rounded(), entry.uv.z, entry.uv.w), color: LegacyPalette.rgb(0x2E, 0x1F, 0x6B, 0.6), uv: entry.uv))
    }

    private func buildCells(_ snapshot: TerminalContentSnapshot, showCursor: Bool) -> [LegacyQuad] {
        var backgrounds: [LegacyQuad] = []
        var glyphs: [LegacyQuad] = []
        let cw = Float(atlas.cellWidth), ch = Float(atlas.cellHeight)
        for (rowIndex, row) in snapshot.rows.enumerated() {
            let y = Float(rowIndex) * ch
            var run: (start: Int, end: Int, color: SIMD4<Float>)?
            func flushRun() {
                guard let r = run else { return }
                backgrounds.append(LegacyQuad(.solid, SIMD4(Float(r.start) * cw, y, Float(r.end - r.start) * cw, ch), color: r.color))
                run = nil
            }
            for (column, cell) in row.cells.enumerated() {
                let attribute = cell.attribute
                var fg = LegacyPalette.color(attribute.fg, isForeground: true)
                var bg = LegacyPalette.color(attribute.bg, isForeground: false)
                if attribute.style.contains(.inverse) { swap(&fg, &bg) }
                if attribute.style.contains(.dim) { fg.w = 0.55 }

                if bg != LegacyPalette.background {
                    if let r = run, r.end == column, r.color == bg { run?.end = column + 1 } else { flushRun(); run = (column, column + 1, bg) }
                } else {
                    flushRun()
                }

                let x = Float(column) * cw
                if let blocks = Self.blockRects(cell.text) {
                    for (rect, opacity) in blocks {
                        glyphs.append(LegacyQuad(.solid, SIMD4(x + rect.x * cw, y + rect.y * ch, rect.z * cw, rect.w * ch),
                                                 color: SIMD4(fg.x, fg.y, fg.z, fg.w * opacity)))
                    }
                    continue
                }
                guard cell.width > 0, !cell.text.isEmpty, cell.text != " ", !attribute.style.contains(.invisible),
                      let entry = atlas.entry(cell.text, face: attribute.style.contains(.bold) ? .monoBold : .mono, cells: cell.width)
                else { continue }
                glyphs.append(LegacyQuad(.glyph, SIMD4(x, y, entry.uv.z, entry.uv.w), color: fg, uv: entry.uv))
                if attribute.style.contains(.underline) {
                    glyphs.append(LegacyQuad(.solid, SIMD4(x, y + ch - 2, cw * Float(cell.width), 1), color: fg))
                }
            }
            flushRun()
        }
        if showCursor, let top = snapshot.rows.first?.absoluteRow {
            let row = snapshot.cursorRow - top
            if row >= 0 && row < snapshot.rows.count {
                backgrounds.append(LegacyQuad(.solid, SIMD4(Float(snapshot.cursorColumn) * cw, Float(row) * ch, cw, ch),
                                              color: LegacyPalette.rgb(0x6E, 0x56, 0xCF, 0.35)))
            }
        }
        return backgrounds + glyphs
    }

    private static func blockRects(_ text: String) -> [(SIMD4<Float>, Float)]? {
        guard text.unicodeScalars.count == 1, let v = text.unicodeScalars.first?.value, (0x2580...0x259F).contains(v) else { return nil }
        let e: Float = 1.0 / 8
        switch v {
        case 0x2580: return [(SIMD4(0, 0, 1, 0.5), 1)]
        case 0x2581...0x2588:
            let h = Float(v - 0x2580) * e
            return [(SIMD4(0, 1 - h, 1, h), 1)]
        case 0x2589...0x258F: return [(SIMD4(0, 0, Float(0x2590 - v) * e, 1), 1)]
        case 0x2590: return [(SIMD4(0.5, 0, 0.5, 1), 1)]
        case 0x2591...0x2593: return [(SIMD4(0, 0, 1, 1), Float(v - 0x2590) * 0.25)]
        case 0x2594: return [(SIMD4(0, 0, 1, e), 1)]
        case 0x2595: return [(SIMD4(1 - e, 0, e, 1), 1)]
        default:
            let masks: [UInt32: Int] = [0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 13, 0x259A: 9,
                                        0x259B: 7, 0x259C: 11, 0x259D: 2, 0x259E: 6, 0x259F: 14]
            let mask = masks[v] ?? 0
            let quadrants: [(Int, SIMD4<Float>)] = [(1, SIMD4(0, 0, 0.5, 0.5)), (2, SIMD4(0.5, 0, 0.5, 0.5)),
                                                    (4, SIMD4(0, 0.5, 0.5, 0.5)), (8, SIMD4(0.5, 0.5, 0.5, 0.5))]
            return quadrants.filter { mask & $0.0 != 0 }.map { ($0.1, 1) }
        }
    }
}
