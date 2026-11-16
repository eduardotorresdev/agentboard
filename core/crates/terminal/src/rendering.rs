//! What an owner reads off the screen. The Swift file also hands rows and damage to its
//! renderer; nothing draws here, so only the cursor and the text are ported.

use crate::cell::{Cell, CellWidth};
use crate::swift_string::trim_trailing_spaces;
use crate::terminal::{CursorShape, Terminal, TerminalModes};

/// Where and how to draw the cursor.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct CursorState {
    pub column: usize,
    pub row: usize,
    pub visible: bool,
    pub shape: CursorShape,
}

impl Terminal {
    pub fn cursor(&self) -> CursorState {
        CursorState { column: self.cursor_x, row: self.cursor_y, visible: self.modes.contains(TerminalModes::CURSOR_VISIBLE), shape: self.cursor_shape }
    }

    /// The cell at a logical position of the active screen.
    pub fn cell(&self, column: usize, row: usize) -> Cell {
        self.grid().row(row)[column]
    }

    /// The text of a cell (its scalar or cluster), or `None` when empty or a wide tail.
    pub fn text_of(&self, cell: Cell) -> Option<String> {
        if cell.is_empty() || cell.width() == CellWidth::Tail {
            return None;
        }
        if cell.is_cluster() {
            return Some(self.cluster_string(cell.scalar()));
        }
        char::from_u32(cell.scalar()).map(String::from)
    }

    fn plain(&self, cells: &[Cell]) -> String {
        let mut line = String::new();
        for &cell in cells.iter().filter(|cell| cell.width() != CellWidth::Tail) {
            match self.text_of(cell) {
                Some(text) => line += &text,
                None => line.push(' '),
            }
        }
        line
    }

    /// The active screen as plain text, one string per row, trailing blanks trimmed.
    pub fn screen_text(&self) -> Vec<String> {
        (0..self.rows)
            .map(|y| {
                let mut line = self.plain(self.grid().row(y));
                trim_trailing_spaces(&mut line);
                line
            })
            .collect()
    }

    /// The last `count` lines of the main screen's output, scrollback included, as plain text.
    /// Rows the program soft-wrapped are joined back into one line; trailing empty lines are left out.
    pub fn recent_text(&self, count: usize) -> Vec<String> {
        if count == 0 {
            return Vec::new();
        }
        let mut rows = Vec::new();
        // Wrapped rows join, so a few more rows than lines may be needed.
        for index in self.scrollback.count().saturating_sub(count.saturating_mul(2))..self.scrollback.count() {
            if let Some((cells, wrapped)) = self.scrollback.line(index, self.cols) {
                rows.push((self.plain(&cells), wrapped));
            }
        }
        for y in 0..self.rows {
            rows.push((self.plain(self.main.row(y)), self.main.is_wrapped(y)));
        }
        let mut lines = Vec::new();
        let mut current = String::new();
        for (text, wrapped) in rows {
            current += &text;
            if !wrapped {
                trim_trailing_spaces(&mut current);
                lines.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            lines.push(current);
        }
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        lines.split_off(lines.len().saturating_sub(count))
    }
}
