/// One screen's cells (main or alternate). Rows are addressed through `rowMap`
/// (logical → physical), so scrolling rotates row indices instead of moving cells, and a
/// renderer can mirror a scroll by re-reading a few hundred bytes of map.
///
/// Damage is tracked per physical row; `mapVersion` changes whenever the mapping does.
final class Grid {
    @exclusivity(unchecked) private(set) var cols: Int
    @exclusivity(unchecked) private(set) var rows: Int
    @exclusivity(unchecked) private(set) var cells: UnsafeMutablePointer<Cell>
    /// Logical row → physical row.
    @exclusivity(unchecked) private(set) var rowMap: UnsafeMutablePointer<Int32>
    /// By physical row: the line continues on the next row (soft wrap).
    @exclusivity(unchecked) private(set) var wrapped: UnsafeMutablePointer<Bool>
    /// By physical row: changed since the renderer last looked.
    @exclusivity(unchecked) private(set) var dirty: UnsafeMutablePointer<Bool>
    @exclusivity(unchecked) var anyDirty = true
    @exclusivity(unchecked) private(set) var mapVersion = 0

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        cells = .allocate(capacity: cols * rows)
        cells.initialize(repeating: .blank(), count: cols * rows)
        rowMap = .allocate(capacity: rows)
        wrapped = .allocate(capacity: rows)
        wrapped.initialize(repeating: false, count: rows)
        dirty = .allocate(capacity: rows)
        dirty.initialize(repeating: true, count: rows)
        for y in 0..<rows { rowMap[y] = Int32(y) }
    }

    deinit {
        cells.deallocate()
        rowMap.deallocate()
        wrapped.deallocate()
        dirty.deallocate()
    }

    /// Bytes held by this grid.
    var memoryUsage: Int { cols * rows * MemoryLayout<Cell>.stride + rows * (4 + 1 + 1) }

    @inline(__always) func row(_ y: Int) -> UnsafeMutablePointer<Cell> { cells + Int(rowMap[y]) * cols }
    @inline(__always) func physicalRow(_ physical: Int) -> UnsafeMutablePointer<Cell> { cells + physical * cols }

    @inline(__always) func markDirty(_ y: Int) {
        dirty[Int(rowMap[y])] = true
        anyDirty = true
    }

    func markAllDirty() {
        dirty.update(repeating: true, count: rows)
        anyDirty = true
    }

    @inline(__always) func isWrapped(_ y: Int) -> Bool { wrapped[Int(rowMap[y])] }
    @inline(__always) func setWrapped(_ y: Int, _ value: Bool) { wrapped[Int(rowMap[y])] = value }

    /// Erases columns `from..<to` of logical row `y`.
    func clear(row y: Int, from start: Int = 0, to end: Int? = nil, background: UInt32) {
        let end = min(end ?? cols, cols), start = max(0, start)
        guard start < end else { return }
        (row(y) + start).update(repeating: .blank(background: background), count: end - start)
        if start == 0 && end == cols { setWrapped(y, false) }
        markDirty(y)
    }

    /// Moves rows `top...bottom` up by `count`, pushing each row that leaves the top into
    /// `scrollback` (when given) before it is recycled as a blank row at the bottom.
    func scrollUp(top: Int, bottom: Int, count: Int, background: UInt32, into scrollback: Scrollback? = nil) {
        guard top <= bottom else { return }
        let count = min(count, bottom - top + 1)
        for _ in 0..<count {
            let recycled = rowMap[top]
            scrollback?.push(physicalRow(Int(recycled)), cols: cols, wrapped: wrapped[Int(recycled)])
            (rowMap + top).update(from: rowMap + top + 1, count: bottom - top)
            rowMap[bottom] = recycled
            physicalRow(Int(recycled)).update(repeating: .blank(background: background), count: cols)
            wrapped[Int(recycled)] = false
            dirty[Int(recycled)] = true
        }
        mapVersion &+= 1
        anyDirty = true
    }

    /// Moves rows `top...bottom` down by `count`, inserting blank rows at the top.
    func scrollDown(top: Int, bottom: Int, count: Int, background: UInt32) {
        guard top <= bottom else { return }
        let count = min(count, bottom - top + 1)
        for _ in 0..<count {
            let recycled = rowMap[bottom]
            // Overlapping move toward higher addresses: go through a temporary.
            for y in stride(from: bottom, to: top, by: -1) { rowMap[y] = rowMap[y - 1] }
            rowMap[top] = recycled
            physicalRow(Int(recycled)).update(repeating: .blank(background: background), count: cols)
            wrapped[Int(recycled)] = false
            dirty[Int(recycled)] = true
        }
        mapVersion &+= 1
        anyDirty = true
    }

    /// Rebuilds the grid at a new size, keeping logical rows `firstRow...` at the top and
    /// truncating or padding columns. Everything is dirty afterwards.
    func resize(cols newCols: Int, rows newRows: Int, firstRow: Int = 0) {
        let newCells = UnsafeMutablePointer<Cell>.allocate(capacity: newCols * newRows)
        newCells.initialize(repeating: .blank(), count: newCols * newRows)
        let newWrapped = UnsafeMutablePointer<Bool>.allocate(capacity: newRows)
        newWrapped.initialize(repeating: false, count: newRows)
        let copyCols = min(cols, newCols)
        for y in 0..<newRows where firstRow + y < rows {
            let source = row(firstRow + y), target = newCells + y * newCols
            target.update(from: source, count: copyCols)
            // Never leave half of a wide character at the new right edge.
            if copyCols < cols, copyCols > 0, target[copyCols - 1].width == .wide { target[copyCols - 1] = .blank() }
            newWrapped[y] = newCols == cols && isWrapped(firstRow + y)
        }
        cells.deallocate()
        wrapped.deallocate()
        dirty.deallocate()
        rowMap.deallocate()
        cells = newCells
        wrapped = newWrapped
        dirty = .allocate(capacity: newRows)
        dirty.initialize(repeating: true, count: newRows)
        rowMap = .allocate(capacity: newRows)
        for y in 0..<newRows { rowMap[y] = Int32(y) }
        cols = newCols
        rows = newRows
        mapVersion &+= 1
        anyDirty = true
    }
}
