use crate::cell::Cell;
use crate::scrollback::Scrollback;

/// One screen's cells (main or alternate). Rows are addressed through `row_map`
/// (logical → physical), so scrolling rotates row indices instead of moving cells.
///
/// The Swift grid also tracks damage per row and a map version for its renderer; a headless
/// owner draws nothing, so those are left out.
pub(crate) struct Grid {
    pub cols: usize,
    pub rows: usize,
    cells: Vec<Cell>,
    /// Logical row → physical row.
    row_map: Vec<usize>,
    /// By physical row: the line continues on the next row (soft wrap).
    wrapped: Vec<bool>,
}

impl Grid {
    pub fn new(cols: usize, rows: usize) -> Self {
        Self { cols, rows, cells: vec![Cell::default(); cols * rows], row_map: (0..rows).collect(), wrapped: vec![false; rows] }
    }

    pub fn row(&self, y: usize) -> &[Cell] {
        let start = self.row_map[y] * self.cols;
        &self.cells[start..start + self.cols]
    }

    pub fn row_mut(&mut self, y: usize) -> &mut [Cell] {
        self.physical_row_mut(self.row_map[y])
    }

    fn physical_row_mut(&mut self, physical: usize) -> &mut [Cell] {
        let start = physical * self.cols;
        &mut self.cells[start..start + self.cols]
    }

    pub fn is_wrapped(&self, y: usize) -> bool {
        self.wrapped[self.row_map[y]]
    }

    pub fn set_wrapped(&mut self, y: usize, value: bool) {
        let physical = self.row_map[y];
        self.wrapped[physical] = value;
    }

    /// Erases columns `start..end` of logical row `y`.
    pub fn clear(&mut self, y: usize, start: usize, end: usize, background: u32) {
        let end = end.min(self.cols);
        if start >= end {
            return;
        }
        self.row_mut(y)[start..end].fill(Cell::blank(background));
        if start == 0 && end == self.cols {
            self.set_wrapped(y, false);
        }
    }

    pub fn clear_row(&mut self, y: usize, background: u32) {
        self.clear(y, 0, self.cols, background);
    }

    /// Moves rows `top..=bottom` up by `count`, pushing each row that leaves the top into
    /// `scrollback` (when given) before it is recycled as a blank row at the bottom.
    pub fn scroll_up(&mut self, top: usize, bottom: usize, count: usize, background: u32, mut scrollback: Option<&mut Scrollback>) {
        if top > bottom {
            return;
        }
        for _ in 0..count.min(bottom - top + 1) {
            let recycled = self.row_map[top];
            if let Some(scrollback) = scrollback.as_deref_mut() {
                scrollback.push(&self.cells[recycled * self.cols..(recycled + 1) * self.cols], self.wrapped[recycled]);
            }
            self.row_map[top..=bottom].rotate_left(1);
            self.physical_row_mut(recycled).fill(Cell::blank(background));
            self.wrapped[recycled] = false;
        }
    }

    /// Moves rows `top..=bottom` down by `count`, inserting blank rows at the top.
    pub fn scroll_down(&mut self, top: usize, bottom: usize, count: usize, background: u32) {
        if top > bottom {
            return;
        }
        for _ in 0..count.min(bottom - top + 1) {
            let recycled = self.row_map[bottom];
            self.row_map[top..=bottom].rotate_right(1);
            self.physical_row_mut(recycled).fill(Cell::blank(background));
            self.wrapped[recycled] = false;
        }
    }

    /// Rebuilds the grid at a new size, keeping logical rows `first_row..` at the top and
    /// truncating or padding columns.
    pub fn resize(&mut self, new_cols: usize, new_rows: usize, first_row: usize) {
        let mut new_cells = vec![Cell::default(); new_cols * new_rows];
        let mut new_wrapped = vec![false; new_rows];
        let copy_cols = self.cols.min(new_cols);
        for y in 0..new_rows {
            if first_row + y >= self.rows {
                break;
            }
            let target = &mut new_cells[y * new_cols..(y + 1) * new_cols];
            target[..copy_cols].copy_from_slice(&self.row(first_row + y)[..copy_cols]);
            // Never leave half of a wide character at the new right edge.
            if copy_cols < self.cols && copy_cols > 0 && target[copy_cols - 1].width() == crate::cell::CellWidth::Wide {
                target[copy_cols - 1] = Cell::default();
            }
            new_wrapped[y] = new_cols == self.cols && self.is_wrapped(first_row + y);
        }
        *self = Self { cols: new_cols, rows: new_rows, cells: new_cells, row_map: (0..new_rows).collect(), wrapped: new_wrapped };
    }
}
