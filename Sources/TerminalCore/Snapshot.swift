// A terminal's whole state as bytes, so another process can pick up where this one is: the
// screens, the scrollback, the cursor and pen, the modes, the cluster table, and the parser's
// position inside a sequence (a snapshot taken between two halves of one finishes it right).
// Restoring a snapshot into a terminal makes it render and answer exactly like the one it was
// taken from.
//
// Not stored: the colors reported to programs (the owner sets those).

extension Terminal {
    private static let snapshotMagic: UInt32 = 0x4142_5453  // "ABTS"
    private static let snapshotVersion = 2

    /// The terminal's state; `restore` reads it back.
    public func snapshot() -> [UInt8] {
        var out = SnapshotWriter()
        out.u32(Self.snapshotMagic)
        out.varint(Self.snapshotVersion)
        out.varint(cols)
        out.varint(rows)
        out.u32(modes.rawValue)
        out.byte(mouseTracking.rawValue)
        out.byte(mouseEncoding.rawValue)
        out.byte(cursorShape.rawValue)
        out.string(title)
        out.optionalString(workingDirectory)
        out.varint(cursorX)
        out.varint(cursorY)
        out.bool(pendingWrap)
        out.pen(pen)
        out.varint(scrollTop)
        out.varint(scrollBottom)
        out.bools(tabStops)
        out.byte(charsets[0].rawValue)
        out.byte(charsets[1].rawValue)
        out.varint(activeCharset)
        out.savedCursor(savedMain)
        out.savedCursor(savedAlternate)
        out.u32(lastPrinted)
        out.bool(joinNext)

        let clusterScalars = clusters.allScalars
        out.varint(clusterScalars.count)
        for scalars in clusterScalars {
            out.varint(scalars.count)
            scalars.forEach { out.varint(Int($0)) }
        }

        out.varint(scrollback.count)
        scrollback.forEachLine(cols: cols) { cells, wrapped in
            cells.withUnsafeBufferPointer { out.row($0.baseAddress!, cols: cols, wrapped: wrapped) }
        }
        out.grid(main)
        out.bool(alternate != nil)
        if let alternate { out.grid(alternate) }
        out.bool(isAlternateScreen)
        out.parser(parser.position)
        return out.bytes
    }

    /// Replaces this terminal's state with `snapshot`'s, size included. Returns false, and
    /// changes nothing, when the bytes aren't a snapshot this version can read.
    @discardableResult
    public func restore(_ snapshot: [UInt8]) -> Bool {
        guard let state = try? DecodedSnapshot(snapshot) else { return false }
        cols = state.cols
        rows = state.rows
        modes = state.modes
        mouseTracking = state.mouseTracking
        mouseEncoding = state.mouseEncoding
        cursorShape = state.cursorShape
        title = state.title
        workingDirectory = state.workingDirectory
        cursorX = state.cursorX
        cursorY = state.cursorY
        pendingWrap = state.pendingWrap
        pen = state.pen
        scrollTop = state.scrollTop
        scrollBottom = state.scrollBottom
        tabStops = state.tabStops
        charsets = state.charsets
        activeCharset = state.activeCharset
        savedMain = state.savedMain
        savedAlternate = state.savedAlternate
        lastPrinted = state.lastPrinted
        joinNext = state.joinNext

        clusters.removeAll()
        for scalars in state.clusters { _ = clusters.intern(scalars) }

        scrollback.removeAll()
        for line in state.scrollback {
            line.cells.withUnsafeBufferPointer { scrollback.push($0.baseAddress!, cols: cols, wrapped: line.wrapped) }
        }
        main.resize(cols: cols, rows: rows)
        Self.fill(main, with: state.main)
        if let rowsOfAlternate = state.alternate {
            let fresh = Grid(cols: cols, rows: rows)
            Self.fill(fresh, with: rowsOfAlternate)
            alternate = fresh
        } else {
            alternate = nil
        }
        grid = state.onAlternate ? alternate ?? main : main
        var parser = self.parser
        _ = parser.move(to: state.parser)
        self.parser = parser
        grid.markAllDirty()
        layoutVersion &+= 1
        return true
    }

    private static func fill(_ grid: Grid, with rows: [SnapshotRow]) {
        for (y, line) in rows.enumerated() where y < grid.rows {
            line.cells.withUnsafeBufferPointer { grid.row(y).update(from: $0.baseAddress!, count: grid.cols) }
            grid.setWrapped(y, line.wrapped)
        }
        grid.markAllDirty()
    }
}

// MARK: Encoding

/// A row's cells and whether it soft-wraps into the next one.
private struct SnapshotRow {
    var cells: [Cell]
    var wrapped: Bool
}

/// Little-endian fixed-width integers and LEB128 varints.
private struct SnapshotWriter {
    var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) { bytes.append(value) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    mutating func varint(_ value: Int) {
        var value = UInt(bitPattern: value)
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func string(_ value: String) {
        varint(value.utf8.count)
        bytes.append(contentsOf: value.utf8)
    }

    mutating func optionalString(_ value: String?) {
        bool(value != nil)
        if let value { string(value) }
    }

    mutating func bools(_ values: [Bool]) {
        varint(values.count)
        values.forEach { bool($0) }
    }

    mutating func pen(_ pen: Pen) {
        u32(pen.contentBits)
        u32(pen.fg)
        u32(pen.bg)
    }

    mutating func savedCursor(_ saved: Terminal.SavedCursor?) {
        bool(saved != nil)
        guard let saved else { return }
        varint(saved.x)
        varint(saved.y)
        bool(saved.pendingWrap)
        pen(saved.pen)
        bool(saved.origin)
        byte(saved.charsets[0].rawValue)
        byte(saved.charsets[1].rawValue)
        varint(saved.activeCharset)
    }

    mutating func parser(_ position: VTParser.Position) {
        byte(position.state)
        varint(position.params.count)
        position.params.forEach { varint(Int($0)) }
        varint(position.currentParam)
        bool(position.hasParam)
        u32(UInt32(truncatingIfNeeded: position.colonMask))
        u32(UInt32(truncatingIfNeeded: position.colonMask >> 32))
        u32(position.collected)
        varint(position.string.count)
        bytes.append(contentsOf: position.string)
        u32(position.utf8Scalar)
        varint(position.utf8Remaining)
        u32(position.utf8Minimum)
    }

    mutating func grid(_ grid: Grid) {
        for y in 0..<grid.rows { row(grid.row(y), cols: grid.cols, wrapped: grid.isWrapped(y)) }
    }

    /// Trailing default blanks trimmed, then runs of one style (the content's high bits, fg,
    /// bg) followed by one varint per cell for its scalar or cluster id.
    mutating func row(_ cells: UnsafePointer<Cell>, cols: Int, wrapped: Bool) {
        var used = cols
        while used > 0, cells[used - 1].content | cells[used - 1].fg | cells[used - 1].bg == 0 { used -= 1 }
        bool(wrapped)
        varint(used)
        var x = 0
        while x < used {
            let high = cells[x].content >> 21, fg = cells[x].fg, bg = cells[x].bg
            var end = x + 1
            while end < used, cells[end].content >> 21 == high, cells[end].fg == fg, cells[end].bg == bg { end += 1 }
            varint(end - x)
            u32(high)
            u32(fg)
            u32(bg)
            for index in x..<end { varint(Int(cells[index].content & 0x1F_FFFF)) }
            x = end
        }
    }
}

private struct SnapshotReader {
    struct Truncated: Error {}

    let bytes: [UInt8]
    var offset = 0

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw Truncated() }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bool() throws -> Bool { try byte() != 0 }

    mutating func u32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) { value |= UInt32(try byte()) << UInt32(shift) }
        return value
    }

    mutating func varint() throws -> Int {
        var value: UInt = 0, shift: UInt = 0
        while true {
            let next = try byte()
            guard shift < 64 else { throw Truncated() }
            value |= UInt(next & 0x7F) << shift
            if next < 0x80 { return Int(bitPattern: value) }
            shift += 7
        }
    }

    /// A count that can't be larger than what is left to read, so a corrupt one fails fast.
    mutating func count(atMost limit: Int = .max) throws -> Int {
        let value = try varint()
        guard value >= 0, value <= min(limit, bytes.count - offset) else { throw Truncated() }
        return value
    }

    mutating func string() throws -> String {
        let length = try count()
        defer { offset += length }
        return String(decoding: bytes[offset..<offset + length], as: UTF8.self)
    }

    mutating func optionalString() throws -> String? { try bool() ? try string() : nil }

    mutating func bools() throws -> [Bool] { try (0..<count()).map { _ in try bool() } }

    mutating func pen() throws -> Pen { Pen(contentBits: try u32(), fg: try u32(), bg: try u32()) }

    mutating func charset() throws -> Terminal.Charset {
        guard let charset = Terminal.Charset(rawValue: try byte()) else { throw Truncated() }
        return charset
    }

    mutating func parser() throws -> VTParser.Position {
        var position = VTParser.Position()
        position.state = try byte()
        position.params = try (0..<count(atMost: 32)).map { _ in UInt16(truncatingIfNeeded: try varint()) }
        position.currentParam = try varint()
        position.hasParam = try bool()
        position.colonMask = UInt64(try u32()) | UInt64(try u32()) << 32
        position.collected = try u32()
        position.string = try (0..<count(atMost: 64 * 1024)).map { _ in try byte() }
        position.utf8Scalar = try u32()
        position.utf8Remaining = try varint()
        position.utf8Minimum = try u32()
        return position
    }

    mutating func savedCursor() throws -> Terminal.SavedCursor? {
        guard try bool() else { return nil }
        return Terminal.SavedCursor(x: try varint(), y: try varint(), pendingWrap: try bool(), pen: try pen(),
                                    origin: try bool(), charsets: [try charset(), try charset()], activeCharset: try varint())
    }

    mutating func row(cols: Int) throws -> SnapshotRow {
        let wrapped = try bool()
        let used = try count(atMost: cols)
        var cells = [Cell](repeating: .blank(), count: cols)
        var x = 0
        while x < used {
            let length = try count(atMost: used - x)
            guard length > 0 else { throw Truncated() }
            let high = try u32(), fg = try u32(), bg = try u32()
            for index in x..<x + length {
                cells[index] = Cell(content: high << 21 | UInt32(truncatingIfNeeded: try varint()) & 0x1F_FFFF, fg: fg, bg: bg)
            }
            x += length
        }
        return SnapshotRow(cells: cells, wrapped: wrapped)
    }
}

private struct DecodedSnapshot {
    var cols = 0, rows = 0
    var modes = TerminalModes.defaults
    var mouseTracking = MouseTracking.none
    var mouseEncoding = MouseEncoding.x10
    var cursorShape = CursorShape.block
    var title = ""
    var workingDirectory: String?
    var cursorX = 0, cursorY = 0
    var pendingWrap = false
    var pen = Pen()
    var scrollTop = 0, scrollBottom = 0
    var tabStops: [Bool] = []
    var charsets: [Terminal.Charset] = [.ascii, .ascii]
    var activeCharset = 0
    var savedMain: Terminal.SavedCursor?
    var savedAlternate: Terminal.SavedCursor?
    var lastPrinted: UInt32 = 0
    var joinNext = false
    var clusters: [[UInt32]] = []
    var scrollback: [SnapshotRow] = []
    var main: [SnapshotRow] = []
    var alternate: [SnapshotRow]?
    var onAlternate = false
    /// At rest for a version 1 snapshot, which didn't store it.
    var parser = VTParser.Position()

    init(_ bytes: [UInt8]) throws {
        var input = SnapshotReader(bytes: bytes)
        guard try input.u32() == 0x4142_5453 else { throw SnapshotReader.Truncated() }
        let version = try input.varint()
        guard version == 1 || version == 2 else { throw SnapshotReader.Truncated() }
        cols = try input.varint()
        rows = try input.varint()
        guard cols >= 2, rows >= 1, cols <= 4096, rows <= 4096 else { throw SnapshotReader.Truncated() }
        modes = TerminalModes(rawValue: try input.u32())
        guard let tracking = MouseTracking(rawValue: try input.byte()), let encoding = MouseEncoding(rawValue: try input.byte()),
              let shape = CursorShape(rawValue: try input.byte()) else { throw SnapshotReader.Truncated() }
        mouseTracking = tracking
        mouseEncoding = encoding
        cursorShape = shape
        title = try input.string()
        workingDirectory = try input.optionalString()
        cursorX = min(max(0, try input.varint()), cols - 1)
        cursorY = min(max(0, try input.varint()), rows - 1)
        pendingWrap = try input.bool()
        pen = try input.pen()
        scrollTop = try input.varint()
        scrollBottom = try input.varint()
        guard 0 <= scrollTop, scrollTop <= scrollBottom, scrollBottom < rows else { throw SnapshotReader.Truncated() }
        tabStops = try input.bools()
        guard tabStops.count == cols else { throw SnapshotReader.Truncated() }
        charsets = [try input.charset(), try input.charset()]
        activeCharset = min(max(0, try input.varint()), 1)
        savedMain = try input.savedCursor()
        savedAlternate = try input.savedCursor()
        lastPrinted = try input.u32()
        joinNext = try input.bool()
        clusters = try (0..<input.count()).map { _ in try (0..<input.count()).map { _ in UInt32(truncatingIfNeeded: try input.varint()) } }
        scrollback = try (0..<input.count()).map { _ in try input.row(cols: cols) }
        main = try (0..<rows).map { _ in try input.row(cols: cols) }
        alternate = try input.bool() ? try (0..<rows).map { _ in try input.row(cols: cols) } : nil
        onAlternate = try input.bool() && alternate != nil
        if version >= 2 { parser = try input.parser() }
    }
}
