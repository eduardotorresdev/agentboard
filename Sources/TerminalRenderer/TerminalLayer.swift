import Metal
import TerminalCore

/// One terminal's copy on the GPU: cells in physical row order plus the row map, so a frame
/// uploads only the rows that changed and a scroll uploads only the map (a few hundred bytes).
///
/// Create one per terminal that is on screen and drop it when the terminal leaves the screen;
/// the next `update` after creation uploads everything once.
public final class TerminalLayer {
    /// Matches `Cell` in `TerminalPipeline.source`.
    struct GPUCell {
        var glyph: UInt32
        var fg: UInt32
        var bg: UInt32
        var flags: UInt32
    }

    enum Flag {
        static let underline: UInt32 = 1
        static let doubleUnderline: UInt32 = 2
        static let curlyUnderline: UInt32 = 4
        static let strikethrough: UInt32 = 8
        static let overline: UInt32 = 16
    }

    @exclusivity(unchecked) public private(set) var cols = 0
    @exclusivity(unchecked) public private(set) var rows = 0
    @exclusivity(unchecked) public private(set) var cursor = CursorState(column: 0, row: 0, visible: false, shape: .block)
    @exclusivity(unchecked) private(set) var cells: MTLBuffer?
    @exclusivity(unchecked) private(set) var rowMap: MTLBuffer?
    private let device: MTLDevice
    @exclusivity(unchecked) private var layoutVersion = -1
    @exclusivity(unchecked) private var mapVersion = -1
    @exclusivity(unchecked) private var glyphGeneration = -1
    @exclusivity(unchecked) private var theme: TerminalTheme?

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Bytes of GPU memory held by this layer.
    public var memoryUsage: Int { (cells?.length ?? 0) + (rowMap?.length ?? 0) }

    /// Copies what changed in `terminal` since the last call: everything after a resize, a
    /// screen switch, a theme change or an atlas reset, otherwise just the damaged rows. Call
    /// with the terminal's lock held. Returns the number of rows uploaded.
    @discardableResult
    public func update(from terminal: Terminal, theme: TerminalTheme, glyphs: GlyphCache) -> Int {
        var full = terminal.layoutVersion != layoutVersion || glyphs.generation != glyphGeneration || theme != self.theme
        if terminal.cols != cols || terminal.rows != rows || cells == nil {
            cols = terminal.cols
            rows = terminal.rows
            cells = device.makeBuffer(length: cols * rows * MemoryLayout<GPUCell>.stride, options: .storageModeShared)
            rowMap = device.makeBuffer(length: rows * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            full = true
        }
        guard let cells, let rowMap else { return 0 }
        let target = cells.contents().bindMemory(to: GPUCell.self, capacity: cols * rows)
        var uploaded = 0
        let generation = glyphs.generation
        terminal.consumeDamage(all: full) { physical, row in
            convert(row, into: target + physical * cols, terminal: terminal, theme: theme, glyphs: glyphs)
            uploaded += 1
        }
        // Rasterizing a new glyph can reset a full atlas mid-update; redo everything next time.
        glyphGeneration = glyphs.generation == generation ? generation : -1
        if full || terminal.rowMapVersion != mapVersion {
            terminal.copyRowMap(into: rowMap.contents().bindMemory(to: UInt32.self, capacity: rows))
            mapVersion = terminal.rowMapVersion
        }
        layoutVersion = terminal.layoutVersion
        self.theme = theme
        cursor = terminal.cursor
        return uploaded
    }

    private func convert(_ row: UnsafeBufferPointer<Cell>, into target: UnsafeMutablePointer<GPUCell>,
                         terminal: Terminal, theme: TerminalTheme, glyphs: GlyphCache) {
        var previousGlyph: UInt32 = 0
        for x in 0..<row.count {
            let cell = row[x]
            let colors = theme.colors(of: cell)
            var glyph: UInt32 = 0
            switch cell.width {
            case .tail:
                // The right half of the wide glyph rasterized into the slot after the head's.
                glyph = previousGlyph == 0 ? 0 : previousGlyph + 1
            case .narrow, .wide:
                if !cell.isEmpty, !cell.attributes.contains(.invisible) { glyph = glyphs.glyph(for: cell, in: terminal) }
            }
            previousGlyph = cell.width == .wide ? glyph : 0
            var flags: UInt32 = 0
            let attributes = cell.attributes
            if !attributes.isDisjoint(with: CellAttributes.underlines.union([.strikethrough, .overline])) {
                if attributes.contains(.underline) { flags |= Flag.underline }
                if attributes.contains(.doubleUnderline) { flags |= Flag.doubleUnderline }
                if attributes.contains(.curlyUnderline) { flags |= Flag.curlyUnderline }
                if attributes.contains(.strikethrough) { flags |= Flag.strikethrough }
                if attributes.contains(.overline) { flags |= Flag.overline }
            }
            target[x] = GPUCell(glyph: glyph, fg: colors.fg, bg: colors.bg, flags: flags)
        }
    }
}
