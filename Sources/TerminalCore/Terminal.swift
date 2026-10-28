/// Terminal modes a program can switch (DEC private and ANSI).
public struct TerminalModes: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let applicationCursor = TerminalModes(rawValue: 1 << 0)      // DECCKM (?1)
    public static let reverseVideo = TerminalModes(rawValue: 1 << 1)           // DECSCNM (?5)
    public static let origin = TerminalModes(rawValue: 1 << 2)                 // DECOM (?6)
    public static let autowrap = TerminalModes(rawValue: 1 << 3)               // DECAWM (?7)
    public static let cursorBlink = TerminalModes(rawValue: 1 << 4)            // ?12
    public static let cursorVisible = TerminalModes(rawValue: 1 << 5)          // DECTCEM (?25)
    public static let applicationKeypad = TerminalModes(rawValue: 1 << 6)      // DECNKM (?66), DECKPAM
    public static let focusEvents = TerminalModes(rawValue: 1 << 7)            // ?1004
    public static let alternateScroll = TerminalModes(rawValue: 1 << 8)        // ?1007
    public static let bracketedPaste = TerminalModes(rawValue: 1 << 9)         // ?2004
    public static let synchronizedOutput = TerminalModes(rawValue: 1 << 10)    // ?2026
    public static let insert = TerminalModes(rawValue: 1 << 11)                // IRM (4)
    public static let linefeedNewline = TerminalModes(rawValue: 1 << 12)       // LNM (20)

    public static let defaults: TerminalModes = [.autowrap, .cursorVisible]
}

public enum MouseTracking: Sendable {
    case none
    /// ?9: presses only.
    case x10
    /// ?1000: presses and releases.
    case normal
    /// ?1002: plus motion while a button is down.
    case buttonEvent
    /// ?1003: plus all motion.
    case anyEvent
}

public enum MouseEncoding: Sendable {
    case x10, utf8, sgr, urxvt, sgrPixels
}

public enum CursorShape: Sendable {
    case block, underline, bar
}

/// Things a program signalled that the host may want to act on (attention, window title).
public struct TerminalEvents: Sendable {
    public var bells = 0
    public var titleChanged = false
    /// OSC 9 and OSC 777 desktop notifications, in order.
    public var notifications: [String] = []

    public var isEmpty: Bool { bells == 0 && !titleChanged && notifications.isEmpty }
}

/// A terminal emulator: feed it what a program writes, read back its screen for rendering and
/// its replies for the program. Not thread-safe; callers serialize access.
///
/// Speaks the xterm dialect that TUIs such as Claude Code rely on: cursor addressing, scroll
/// regions, the alternate screen, SGR with 256 and 24-bit color, wide characters and grapheme
/// clusters, bracketed paste, focus and mouse reporting, synchronized output, and the device
/// queries those programs send at startup.
public final class Terminal: VTHandler {
    @exclusivity(unchecked) public private(set) var cols: Int
    @exclusivity(unchecked) public private(set) var rows: Int
    public let scrollback: Scrollback
    @exclusivity(unchecked) public internal(set) var modes = TerminalModes.defaults
    @exclusivity(unchecked) public private(set) var mouseTracking = MouseTracking.none
    @exclusivity(unchecked) public private(set) var mouseEncoding = MouseEncoding.x10
    @exclusivity(unchecked) public private(set) var cursorShape = CursorShape.block
    @exclusivity(unchecked) public private(set) var title = ""
    @exclusivity(unchecked) public private(set) var workingDirectory: String?
    /// Colors reported to programs that ask (OSC 10/11), as 0xRRGGBB.
    @exclusivity(unchecked) public var reportedForeground: UInt32 = 0x26213A
    @exclusivity(unchecked) public var reportedBackground: UInt32 = 0xFFFFFF
    /// Bumped on screen switches, resizes and resets: renderers must re-read every row.
    @exclusivity(unchecked) public private(set) var layoutVersion = 0

    @exclusivity(unchecked) public internal(set) var cursorX = 0
    @exclusivity(unchecked) public internal(set) var cursorY = 0

    let main: Grid
    @exclusivity(unchecked) private(set) var alternate: Grid?
    @exclusivity(unchecked) private(set) var grid: Grid
    @exclusivity(unchecked) var pendingWrap = false
    @exclusivity(unchecked) var pen = Pen()
    @exclusivity(unchecked) var scrollTop = 0
    @exclusivity(unchecked) var scrollBottom: Int
    @exclusivity(unchecked) var tabStops: [Bool]
    @exclusivity(unchecked) var charsets: [Charset] = [.ascii, .ascii]
    @exclusivity(unchecked) var activeCharset = 0
    @exclusivity(unchecked) var savedMain: SavedCursor?
    @exclusivity(unchecked) var savedAlternate: SavedCursor?
    @exclusivity(unchecked) var lastPrinted: UInt32 = 0
    /// After a zero-width joiner, the next character joins the same cluster.
    @exclusivity(unchecked) var joinNext = false
    let clusters = ClusterTable()
    @exclusivity(unchecked) private var parser = VTParser()
    @exclusivity(unchecked) private var output: [UInt8] = []
    @exclusivity(unchecked) private var events = TerminalEvents()

    enum Charset { case ascii, decSpecialGraphics }

    struct SavedCursor {
        var x: Int, y: Int
        var pendingWrap: Bool
        var pen: Pen
        var origin: Bool
        var charsets: [Charset]
        var activeCharset: Int
    }

    public init(cols: Int, rows: Int, scrollback: Int = 5000) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        self.scrollback = Scrollback(limit: scrollback)
        main = Grid(cols: self.cols, rows: self.rows)
        grid = main
        scrollBottom = self.rows - 1
        tabStops = Self.defaultTabStops(self.cols)
    }

    deinit { parser.deallocate() }

    public var isAlternateScreen: Bool { grid !== main }
    public var isSynchronizing: Bool { modes.contains(.synchronizedOutput) }

    /// Approximate bytes held by this terminal (grids, scrollback, clusters).
    public var memoryUsage: Int {
        main.memoryUsage + (alternate?.memoryUsage ?? 0) + scrollback.memoryUsage + clusters.memoryUsage + tabStops.count
    }

    // MARK: Input from the program

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        // Work on a local copy (the parser's storage is a pointer, so this copies no state):
        // advancing the stored property in place would hold an access to it across every
        // callback, and Swift would check each property access the callbacks make against it.
        var parser = self.parser
        parser.advance(bytes, self)
        self.parser = parser
    }

    public func feed(_ bytes: [UInt8]) { bytes.withUnsafeBytes { feed($0) } }
    public func feed(_ text: String) { feed(Array(text.utf8)) }

    /// Bytes the terminal owes the program (query replies), if any.
    public func takeOutput() -> [UInt8]? {
        guard !output.isEmpty else { return nil }
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    /// Events since the last call.
    public func takeEvents() -> TerminalEvents {
        defer { events = TerminalEvents() }
        return events
    }

    func respond(_ text: String) { output.append(contentsOf: text.utf8) }

    // MARK: Printing

    func printASCII(_ bytes: UnsafePointer<UInt8>, _ count: Int) {
        if activeCharsetIsSpecial || joinNext || modes.contains(.insert) {
            for index in 0..<count { print(UInt32(bytes[index])) }
            return
        }
        let contentBits = pen.contentBits, fg = pen.fg, bg = pen.bg
        let autowrap = modes.contains(.autowrap)
        var source = bytes, remaining = count
        while remaining > 0 {
            if pendingWrap { wrap() }
            let row = grid.row(cursorY)
            let n = min(remaining, cols - cursorX)
            let last = cursorX + n - 1
            if row[cursorX].width == .tail, cursorX > 0 { row[cursorX - 1] = .blank(background: row[cursorX - 1].bg) }
            if row[last].width == .wide, last + 1 < cols { row[last + 1] = .blank(background: row[last + 1].bg) }
            let target = row + cursorX
            for index in 0..<n {
                target[index] = Cell(content: UInt32(source[index]) | contentBits, fg: fg, bg: bg)
            }
            grid.markDirty(cursorY)
            source += n
            remaining -= n
            if cursorX + n >= cols {
                cursorX = cols - 1
                if autowrap {
                    pendingWrap = true
                } else if remaining > 0 {
                    // Without autowrap the rest overwrites the last column; the final one stays.
                    row[cols - 1] = Cell(content: UInt32(source[remaining - 1]) | contentBits, fg: fg, bg: bg)
                    remaining = 0
                }
            } else {
                cursorX += n
            }
        }
        lastPrinted = UInt32(bytes[count - 1])
    }

    func print(_ scalar: UInt32) {
        var value = scalar
        if value < 0x80 {
            if activeCharsetIsSpecial, value >= 0x5F, value <= 0x7E { value = Self.decSpecialGraphics[Int(value - 0x5F)] }
        } else if value < 0xA0 {
            return  // C1 controls decoded from UTF-8 have no glyph
        }
        var width = value < 0x7F ? 1 : CharacterWidth.of(value)
        if joinNext {
            joinNext = false
            if width > 0 {
                combine(value)
                return
            }
        }
        if width == 0 {
            combine(value)
            if value == 0x200D { joinNext = true }
            return
        }
        if pendingWrap { wrap() }
        if width == 2, cols < 2 { width = 1 }
        if width == 2, cursorX == cols - 1 {
            guard modes.contains(.autowrap) else { return }
            // A wide character never splits across lines: pad and wrap first.
            grid.row(cursorY)[cursorX] = .blank(background: pen.bg)
            grid.markDirty(cursorY)
            pendingWrap = true
            wrap()
        }
        if modes.contains(.insert) { insertBlanks(width) }
        let row = grid.row(cursorY)
        if row[cursorX].width == .tail, cursorX > 0 { row[cursorX - 1] = .blank(background: row[cursorX - 1].bg) }
        let last = cursorX + width - 1
        if row[last].width == .wide, last + 1 < cols { row[last + 1] = .blank(background: row[last + 1].bg) }
        if width == 1 {
            row[cursorX] = Cell(content: value | pen.contentBits, fg: pen.fg, bg: pen.bg)
        } else {
            row[cursorX] = Cell(content: value | UInt32(CellWidth.wide.rawValue) << Cell.widthShift | pen.contentBits, fg: pen.fg, bg: pen.bg)
            row[cursorX + 1] = Cell(content: UInt32(CellWidth.tail.rawValue) << Cell.widthShift | pen.contentBits, fg: pen.fg, bg: pen.bg)
        }
        grid.markDirty(cursorY)
        lastPrinted = value
        if cursorX + width >= cols {
            cursorX = cols - 1
            if modes.contains(.autowrap) { pendingWrap = true }
        } else {
            cursorX += width
        }
    }

    /// Appends a zero-width scalar (combining mark, joiner, variation selector) to the
    /// character before the cursor, turning it into a grapheme cluster.
    private func combine(_ value: UInt32) {
        var x = pendingWrap ? cursorX : cursorX - 1, y = cursorY
        if x < 0 {
            guard y > 0, grid.isWrapped(y - 1) else { return }
            y -= 1
            x = cols - 1
        }
        let row = grid.row(y)
        if row[x].width == .tail, x > 0 { x -= 1 }
        var cell = row[x]
        guard !cell.isEmpty, Unicode.Scalar(value) != nil else { return }
        var scalars = cell.isCluster ? clusters.scalars(cell.scalar) : [cell.scalar]
        scalars.append(value)
        guard let id = clusters.intern(scalars) else { return }
        cell.content = cell.content & ~(Cell.scalarMask | Cell.clusterFlag) | id | Cell.clusterFlag
        row[x] = cell
        grid.markDirty(y)
    }

    /// The text of a cluster cell (see `Cell.isCluster`).
    public func clusterString(_ id: UInt32) -> String { clusters.string(id) }

    private var activeCharsetIsSpecial: Bool { charsets[activeCharset] == .decSpecialGraphics }

    // MARK: Cursor and scrolling

    func wrap() {
        pendingWrap = false
        grid.setWrapped(cursorY, true)
        cursorX = 0
        index()
    }

    /// Moves down one line, scrolling the region when at its bottom.
    func index() {
        pendingWrap = false
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    func reverseIndex() {
        pendingWrap = false
        if cursorY == scrollTop {
            grid.scrollDown(top: scrollTop, bottom: scrollBottom, count: 1, background: pen.bg)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    func scrollUp(_ count: Int) {
        // Only full-width scrolls of the main screen's top feed the scrollback, like xterm.
        let history = grid === main && scrollTop == 0 ? scrollback : nil
        grid.scrollUp(top: scrollTop, bottom: scrollBottom, count: count, background: pen.bg, into: history)
    }

    func scrollDown(_ count: Int) {
        grid.scrollDown(top: scrollTop, bottom: scrollBottom, count: count, background: pen.bg)
    }

    /// Absolute move; rows are relative to the scroll region in origin mode.
    func moveCursor(x: Int, y: Int) {
        pendingWrap = false
        cursorX = min(max(0, x), cols - 1)
        if modes.contains(.origin) {
            cursorY = min(max(scrollTop, y + scrollTop), scrollBottom)
        } else {
            cursorY = min(max(0, y), rows - 1)
        }
    }

    func cursorUp(_ count: Int) {
        pendingWrap = false
        let limit = cursorY >= scrollTop ? scrollTop : 0
        cursorY = max(limit, cursorY - count)
    }

    func cursorDown(_ count: Int) {
        pendingWrap = false
        let limit = cursorY <= scrollBottom ? scrollBottom : rows - 1
        cursorY = min(limit, cursorY + count)
    }

    func saveCursor() {
        let saved = SavedCursor(x: cursorX, y: cursorY, pendingWrap: pendingWrap, pen: pen, origin: modes.contains(.origin),
                                charsets: charsets, activeCharset: activeCharset)
        if isAlternateScreen { savedAlternate = saved } else { savedMain = saved }
    }

    func restoreCursor() {
        guard let saved = isAlternateScreen ? savedAlternate : savedMain else {
            moveCursor(x: 0, y: 0)
            return
        }
        cursorX = min(saved.x, cols - 1)
        cursorY = min(saved.y, rows - 1)
        pendingWrap = saved.pendingWrap && cursorX == cols - 1
        pen = saved.pen
        if saved.origin { modes.insert(.origin) } else { modes.remove(.origin) }
        charsets = saved.charsets
        activeCharset = saved.activeCharset
    }

    // MARK: Editing

    func insertBlanks(_ count: Int) {
        pendingWrap = false
        let row = grid.row(cursorY), n = min(count, cols - cursorX)
        (row + cursorX + n).update(from: row + cursorX, count: cols - cursorX - n)
        (row + cursorX).update(repeating: .blank(background: pen.bg), count: n)
        if row[cols - 1].width == .wide { row[cols - 1] = .blank(background: pen.bg) }
        grid.markDirty(cursorY)
    }

    func deleteChars(_ count: Int) {
        pendingWrap = false
        let row = grid.row(cursorY), n = min(count, cols - cursorX)
        if row[cursorX].width == .tail, cursorX > 0 { row[cursorX - 1] = .blank(background: pen.bg) }
        (row + cursorX).update(from: row + cursorX + n, count: cols - cursorX - n)
        (row + cols - n).update(repeating: .blank(background: pen.bg), count: n)
        if row[cursorX].width == .tail { row[cursorX] = .blank(background: pen.bg) }
        grid.markDirty(cursorY)
    }

    func eraseChars(_ count: Int) {
        pendingWrap = false
        let end = min(cols, cursorX + count)
        repairWideEdges(row: cursorY, from: cursorX, to: end)
        grid.clear(row: cursorY, from: cursorX, to: end, background: pen.bg)
    }

    func eraseLine(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            repairWideEdges(row: cursorY, from: cursorX, to: cols)
            grid.clear(row: cursorY, from: cursorX, background: pen.bg)
            grid.setWrapped(cursorY, false)
        case 1:
            repairWideEdges(row: cursorY, from: 0, to: cursorX + 1)
            grid.clear(row: cursorY, to: cursorX + 1, background: pen.bg)
        case 2:
            grid.clear(row: cursorY, background: pen.bg)
        default: break
        }
    }

    func eraseDisplay(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            eraseLine(0)
            for y in (cursorY + 1)..<max(cursorY + 1, rows) { grid.clear(row: y, background: pen.bg) }
        case 1:
            for y in 0..<cursorY { grid.clear(row: y, background: pen.bg) }
            eraseLine(1)
        case 2:
            for y in 0..<rows { grid.clear(row: y, background: pen.bg) }
        case 3:
            scrollback.removeAll()
        default: break
        }
    }

    /// Clearing half of a wide character clears the other half too.
    private func repairWideEdges(row y: Int, from start: Int, to end: Int) {
        let row = grid.row(y)
        if start > 0, start < cols, row[start].width == .tail { row[start - 1] = .blank(background: pen.bg) }
        if end > 0, end < cols, row[end - 1].width == .wide { row[end] = .blank(background: pen.bg) }
    }

    func insertLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        grid.scrollDown(top: cursorY, bottom: scrollBottom, count: count, background: pen.bg)
        cursorX = 0
        pendingWrap = false
    }

    func deleteLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        grid.scrollUp(top: cursorY, bottom: scrollBottom, count: count, background: pen.bg)
        cursorX = 0
        pendingWrap = false
    }

    // MARK: Screens

    func enterAlternateScreen(clear: Bool) {
        if grid === main {
            if let alternate, alternate.cols == cols, alternate.rows == rows {
                grid = alternate
            } else {
                let fresh = Grid(cols: cols, rows: rows)
                alternate = fresh
                grid = fresh
            }
            layoutVersion &+= 1
        }
        if clear { for y in 0..<rows { grid.clear(row: y, background: pen.bg) } }
        grid.markAllDirty()
    }

    func leaveAlternateScreen() {
        guard grid !== main else { return }
        grid = main
        // Programs repaint the alternate screen whenever they enter it; don't keep it around.
        alternate = nil
        savedAlternate = nil
        main.markAllDirty()
        layoutVersion &+= 1
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }
        // Keep the main screen's cursor line visible: rows above it scroll into the history.
        let mainCursor = isAlternateScreen ? (savedMain?.y ?? 0) : cursorY
        let shift = max(0, mainCursor - (newRows - 1))
        for y in 0..<shift { scrollback.push(main.row(y), cols: cols, wrapped: main.isWrapped(y)) }
        main.resize(cols: newCols, rows: newRows, firstRow: shift)
        if isAlternateScreen {
            savedMain?.y -= shift
            alternate?.resize(cols: newCols, rows: newRows, firstRow: max(0, cursorY - (newRows - 1)))
            cursorY = min(cursorY, newRows - 1)
        } else {
            cursorY -= shift
        }
        cols = newCols
        rows = newRows
        cursorX = min(cursorX, cols - 1)
        cursorY = min(max(0, cursorY), rows - 1)
        pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = (0..<cols).map { $0 < tabStops.count ? tabStops[$0] : $0 % 8 == 0 && $0 > 0 }
        layoutVersion &+= 1
    }

    func fullReset() {
        leaveAlternateScreen()
        modes = .defaults
        mouseTracking = .none
        mouseEncoding = .x10
        cursorShape = .block
        pen = Pen()
        charsets = [.ascii, .ascii]
        activeCharset = 0
        savedMain = nil
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(cols)
        title = ""
        for y in 0..<rows { grid.clear(row: y, background: 0) }
        moveCursor(x: 0, y: 0)
        layoutVersion &+= 1
    }

    static func defaultTabStops(_ cols: Int) -> [Bool] { (0..<cols).map { $0 % 8 == 0 && $0 > 0 } }

    // MARK: Mode and event plumbing used by the control-sequence handlers

    func setMode(_ mode: TerminalModes, _ on: Bool) {
        if on { modes.insert(mode) } else { modes.remove(mode) }
    }

    func setMouse(tracking: MouseTracking? = nil, encoding: MouseEncoding? = nil) {
        if let tracking { mouseTracking = tracking }
        if let encoding { mouseEncoding = encoding }
    }

    func setCursorShape(_ shape: CursorShape) { cursorShape = shape }

    func setTitle(_ text: String) {
        title = text
        events.titleChanged = true
    }

    func setWorkingDirectory(_ path: String) { workingDirectory = path }
    func bell() { events.bells += 1 }
    func notify(_ text: String) { events.notifications.append(text) }

    /// DEC Special Graphics for 0x5F–0x7E (line drawing in `ESC ( 0`).
    private static let decSpecialGraphics: [UInt32] = [
        0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C,
        0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265,
        0x03C0, 0x2260, 0x00A3, 0x00B7,
    ]
}

/// Interned grapheme clusters (base + combining marks, ZWJ emoji), shared by a terminal's
/// screens and scrollback. Ids are stable for the terminal's lifetime.
final class ClusterTable {
    @exclusivity(unchecked) private var entries: [(scalars: [UInt32], text: String)] = []
    /// Keyed by raw scalars: hashing a `String` normalizes it to NFC first, which made
    /// interning the hottest part of printing accented text.
    @exclusivity(unchecked) private var ids: [[UInt32]: UInt32] = [:]

    func intern(_ scalars: [UInt32]) -> UInt32? {
        if let id = ids[scalars] { return id }
        guard entries.count < Int(Cell.scalarMask) else { return nil }
        let id = UInt32(entries.count)
        var text = ""
        for value in scalars { if let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) } }
        entries.append((scalars, text))
        ids[scalars] = id
        return id
    }

    func scalars(_ id: UInt32) -> [UInt32] { Int(id) < entries.count ? entries[Int(id)].scalars : [] }

    func string(_ id: UInt32) -> String { Int(id) < entries.count ? entries[Int(id)].text : "" }

    var memoryUsage: Int { entries.reduce(0) { $0 + $1.scalars.count * 8 + $1.text.utf8.count + 64 } }
}
