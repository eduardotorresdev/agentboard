/// Where and how to draw the cursor.
public struct CursorState: Equatable, Sendable {
    public var column: Int
    public var row: Int
    public var visible: Bool
    public var shape: CursorShape

    public init(column: Int, row: Int, visible: Bool, shape: CursorShape) {
        self.column = column
        self.row = row
        self.visible = visible
        self.shape = shape
    }
}

extension Terminal {
    public var cursor: CursorState {
        CursorState(column: cursorX, row: cursorY, visible: modes.contains(.cursorVisible), shape: cursorShape)
    }

    /// Version of the active screen's row mapping; changes when rows scroll.
    public var rowMapVersion: Int { grid.mapVersion }

    /// Logical row → physical row of the active screen, as consumed by `copyRowMap`.
    public func copyRowMap(into target: UnsafeMutablePointer<UInt32>) {
        for y in 0..<rows { target[y] = UInt32(bitPattern: grid.rowMap[y]) }
    }

    /// Whether anything on the active screen changed since the last `consumeDamage`.
    public var hasDamage: Bool { grid.anyDirty }

    /// Calls `body` with every physical row of the active screen that changed since the last
    /// call (or every row when `all`), then forgets the damage. Rows are addressed physically:
    /// map them with `copyRowMap`.
    public func consumeDamage(all: Bool = false, _ body: (_ physicalRow: Int, _ cells: UnsafeBufferPointer<Cell>) -> Void) {
        guard all || grid.anyDirty else { return }
        for physical in 0..<rows where all || grid.dirty[physical] {
            grid.dirty[physical] = false
            body(physical, UnsafeBufferPointer(start: grid.physicalRow(physical), count: cols))
        }
        grid.anyDirty = false
    }

    /// The cell at a logical position of the active screen.
    public func cell(column: Int, row: Int) -> Cell {
        grid.row(row)[column]
    }

    /// The text of a cell (its scalar or cluster), or nil when empty or a wide tail.
    public func text(of cell: Cell) -> String? {
        if cell.isEmpty || cell.width == .tail { return nil }
        if cell.isCluster { return clusterString(cell.scalar) }
        return Unicode.Scalar(cell.scalar).map { String(Character($0)) }
    }

    /// The active screen as plain text, one string per row, trailing blanks trimmed.
    public func screenText() -> [String] {
        (0..<rows).map { y in
            var line = ""
            let row = grid.row(y)
            for x in 0..<cols where row[x].width != .tail {
                line += text(of: row[x]) ?? " "
            }
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    /// The last `count` lines of the main screen's output, scrollback included, as plain text.
    /// Rows the program soft-wrapped are joined back into one line; trailing empty lines are left out.
    public func recentText(lines count: Int) -> [String] {
        guard count > 0 else { return [] }
        func plain(_ cells: UnsafeBufferPointer<Cell>) -> String {
            var line = ""
            for cell in cells where cell.width != .tail { line += text(of: cell) ?? " " }
            return line
        }
        var rows: [(text: String, wrapped: Bool)] = []
        // Wrapped rows join, so a few more rows than lines may be needed.
        for index in max(0, scrollback.count - count * 2)..<scrollback.count {
            guard let line = scrollback.line(index, cols: cols) else { continue }
            rows.append(line.cells.withUnsafeBufferPointer { (plain($0), line.wrapped) })
        }
        for y in 0..<self.rows {
            rows.append((plain(UnsafeBufferPointer(start: main.row(y), count: cols)), main.isWrapped(y)))
        }
        var lines: [String] = []
        var current = ""
        for row in rows {
            current += row.text
            if !row.wrapped {
                while current.last == " " { current.removeLast() }
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(count))
    }
}
