/// Lines that scrolled off the top of the main screen.
///
/// Lines are packed as they arrive: trailing blanks trimmed, styles run-length encoded
/// (10 bytes per run) and characters as varints (one byte for ASCII). Packed lines are
/// appended to 16 KB pages; the oldest page is freed once all its lines have expired. Typical
/// output costs a little over one byte per character instead of 12 bytes per cell.
public final class Scrollback {
    public let limit: Int
    @exclusivity(unchecked) public private(set) var count = 0

    private struct Page {
        let base: UnsafeMutableRawPointer
        let capacity: Int
        var used = 0
        var lines = 0
    }

    @exclusivity(unchecked) private var pages: [Page] = []
    /// Lines of `pages[0]` that already expired, and the byte offset of the first live one.
    @exclusivity(unchecked) private var headExpired = 0
    @exclusivity(unchecked) private var headOffset = 0
    /// Reused packing buffers for one line's style runs and characters, sized for `scratchCells`.
    @exclusivity(unchecked) private var runScratch: UnsafeMutableRawPointer?
    @exclusivity(unchecked) private var scalarScratch: UnsafeMutableRawPointer?
    @exclusivity(unchecked) private var scratchCells = 0
    private static let pageSize = 16 * 1024
    /// Worst case per cell: a run (3-byte length + 10 bytes of style) and a 3-byte character.
    private static let runBytesPerCell = 13, scalarBytesPerCell = 3

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    deinit {
        pages.forEach { $0.base.deallocate() }
        runScratch?.deallocate()
        scalarScratch?.deallocate()
    }

    /// Bytes held by the pages and the packing buffers.
    public var memoryUsage: Int {
        pages.reduce(0) { $0 + $1.capacity } + scratchCells * (Self.runBytesPerCell + Self.scalarBytesPerCell)
    }

    public func removeAll() {
        pages.forEach { $0.base.deallocate() }
        pages.removeAll()
        headExpired = 0
        headOffset = 0
        count = 0
    }

    func push(_ row: UnsafePointer<Cell>, cols: Int, wrapped: Bool) {
        guard limit > 0 else { return }
        let (header, runCount, runs, scalars) = encode(row, cols: cols, wrapped: wrapped)
        let body = Self.varintSize(header) + Self.varintSize(runCount) + runs + scalars
        let total = Self.varintSize(body) + body
        if pages.isEmpty || pages[pages.count - 1].capacity - pages[pages.count - 1].used < total {
            let capacity = max(Self.pageSize, total)
            pages.append(Page(base: .allocate(byteCount: capacity, alignment: 8), capacity: capacity))
        }
        let index = pages.count - 1
        var cursor = pages[index].base + pages[index].used
        Self.writeVarint(body, to: &cursor)
        Self.writeVarint(header, to: &cursor)
        Self.writeVarint(runCount, to: &cursor)
        cursor.copyMemory(from: runScratch!, byteCount: runs)
        (cursor + runs).copyMemory(from: scalarScratch!, byteCount: scalars)
        pages[index].used += total
        pages[index].lines += 1
        count += 1
        if count > limit { dropOldest() }
    }

    /// The line `index` lines after the oldest one, unpacked to `cols` cells, and whether it
    /// soft-wraps into the next line.
    public func line(_ index: Int, cols: Int) -> (cells: [Cell], wrapped: Bool)? {
        guard index >= 0, index < count else { return nil }
        var remaining = index
        for (pageIndex, page) in pages.enumerated() {
            let live = pageIndex == 0 ? page.lines - headExpired : page.lines
            if remaining >= live { remaining -= live; continue }
            var cursor = UnsafeRawPointer(page.base) + (pageIndex == 0 ? headOffset : 0)
            for _ in 0..<remaining { let length = Self.readVarint(&cursor); cursor += length }
            let length = Self.readVarint(&cursor)
            return decode(UnsafeRawBufferPointer(start: cursor, count: length), cols: cols)
        }
        return nil
    }

    private func dropOldest() {
        var cursor = UnsafeRawPointer(pages[0].base) + headOffset
        let length = Self.readVarint(&cursor)
        headOffset = cursor + length - UnsafeRawPointer(pages[0].base)
        headExpired += 1
        count -= 1
        if headExpired == pages[0].lines {
            pages[0].base.deallocate()
            pages.removeFirst()
            headExpired = 0
            headOffset = 0
        }
    }

    // MARK: Packing

    /// Layout: varint (cells << 1 | wrapped), varint runs, runs of (varint length, u16 content
    /// high bits, u32 fg, u32 bg), then one varint per cell for its scalar.
    ///
    /// One pass over the row writes runs and characters into the scratch buffers; returns the
    /// header, the run count and the bytes used in each buffer.
    private func encode(_ row: UnsafePointer<Cell>, cols: Int, wrapped: Bool)
        -> (header: Int, runCount: Int, runBytes: Int, scalarBytes: Int) {
        if cols > scratchCells {
            runScratch?.deallocate()
            scalarScratch?.deallocate()
            runScratch = .allocate(byteCount: cols * Self.runBytesPerCell, alignment: 8)
            scalarScratch = .allocate(byteCount: cols * Self.scalarBytesPerCell, alignment: 8)
            scratchCells = cols
        }
        // Trim trailing blanks; a default blank cell is all zero bits.
        var used = cols
        while used > 0, row[used - 1].content | row[used - 1].fg | row[used - 1].bg == 0 { used -= 1 }
        let header = used << 1 | (wrapped ? 1 : 0)
        guard used > 0 else { return (header, 0, 0, 0) }

        var runs = runScratch!, scalars = scalarScratch!
        var runCount = 0
        var high = row[0].content >> 21, fg = row[0].fg, bg = row[0].bg, length = 0
        func closeRun() {
            Self.writeVarint(length, to: &runs)
            runs.storeBytes(of: UInt16(high).littleEndian, as: UInt16.self)
            (runs + 2).storeBytes(of: fg.littleEndian, as: UInt32.self)
            (runs + 6).storeBytes(of: bg.littleEndian, as: UInt32.self)
            runs += 10
            runCount += 1
        }
        for x in 0..<used {
            let cell = row[x]
            let cellHigh = cell.content >> 21
            if cellHigh != high || cell.fg != fg || cell.bg != bg {
                closeRun()
                high = cellHigh
                fg = cell.fg
                bg = cell.bg
                length = 0
            }
            length += 1
            let scalar = cell.content & 0x1F_FFFF
            if scalar < 0x80 {
                scalars.storeBytes(of: UInt8(scalar), as: UInt8.self)
                scalars += 1
            } else {
                Self.writeVarint(Int(scalar), to: &scalars)
            }
        }
        closeRun()
        return (header, runCount, runs - runScratch!, scalars - scalarScratch!)
    }

    private func decode(_ data: UnsafeRawBufferPointer, cols: Int) -> (cells: [Cell], wrapped: Bool) {
        var cursor = data.baseAddress!
        let header = Self.readVarint(&cursor)
        let used = header >> 1
        var cells = [Cell](repeating: .blank(), count: max(cols, used))
        let runCount = Self.readVarint(&cursor)
        var styles: [(length: Int, high: UInt32, fg: UInt32, bg: UInt32)] = []
        for _ in 0..<runCount {
            let length = Self.readVarint(&cursor)
            let high = UInt32(cursor.loadUnaligned(as: UInt16.self))
            let fg = (cursor + 2).loadUnaligned(as: UInt32.self), bg = (cursor + 6).loadUnaligned(as: UInt32.self)
            cursor += 10
            styles.append((length, high, fg, bg))
        }
        var x = 0
        for style in styles {
            for _ in 0..<style.length {
                cells[x] = Cell(content: style.high << 21 | UInt32(Self.readVarint(&cursor)), fg: style.fg, bg: style.bg)
                x += 1
            }
        }
        return (Array(cells.prefix(cols)), header & 1 == 1)
    }

    private static func varintSize(_ value: Int) -> Int {
        var size = 1, value = value
        while value >= 0x80 { value >>= 7; size += 1 }
        return size
    }

    private static func writeVarint(_ value: Int, to cursor: inout UnsafeMutableRawPointer) {
        var value = value
        while value >= 0x80 {
            cursor.storeBytes(of: UInt8(value & 0x7F) | 0x80, as: UInt8.self)
            cursor += 1
            value >>= 7
        }
        cursor.storeBytes(of: UInt8(value), as: UInt8.self)
        cursor += 1
    }

    private static func readVarint(_ cursor: inout UnsafeRawPointer) -> Int {
        var value = 0, shift = 0
        while true {
            let byte = cursor.load(as: UInt8.self)
            cursor += 1
            value |= Int(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }
}
