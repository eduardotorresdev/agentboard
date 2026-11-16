use std::collections::HashMap;

use crate::cell::{option_set, Cell, CellWidth, Pen};
use crate::character_width;
use crate::grid::Grid;
use crate::parser::{VtHandler, VtParser};
use crate::scrollback::Scrollback;

/// Terminal modes a program can switch (DEC private and ANSI).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct TerminalModes(pub u32);
option_set!(TerminalModes, u32);

impl TerminalModes {
    pub const APPLICATION_CURSOR: Self = Self(1 << 0); // DECCKM (?1)
    pub const REVERSE_VIDEO: Self = Self(1 << 1); // DECSCNM (?5)
    pub const ORIGIN: Self = Self(1 << 2); // DECOM (?6)
    pub const AUTOWRAP: Self = Self(1 << 3); // DECAWM (?7)
    pub const CURSOR_BLINK: Self = Self(1 << 4); // ?12
    pub const CURSOR_VISIBLE: Self = Self(1 << 5); // DECTCEM (?25)
    pub const APPLICATION_KEYPAD: Self = Self(1 << 6); // DECNKM (?66), DECKPAM
    pub const FOCUS_EVENTS: Self = Self(1 << 7); // ?1004
    pub const ALTERNATE_SCROLL: Self = Self(1 << 8); // ?1007
    pub const BRACKETED_PASTE: Self = Self(1 << 9); // ?2004
    pub const SYNCHRONIZED_OUTPUT: Self = Self(1 << 10); // ?2026
    pub const INSERT: Self = Self(1 << 11); // IRM (4)
    pub const LINEFEED_NEWLINE: Self = Self(1 << 12); // LNM (20)

    pub const DEFAULTS: Self = Self(1 << 3 | 1 << 5);
}

// The raw values of these three are part of the snapshot format.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MouseTracking {
    None = 0,
    /// ?9: presses only.
    X10 = 1,
    /// ?1000: presses and releases.
    Normal = 2,
    /// ?1002: plus motion while a button is down.
    ButtonEvent = 3,
    /// ?1003: plus all motion.
    AnyEvent = 4,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MouseEncoding {
    X10 = 0,
    Utf8 = 1,
    Sgr = 2,
    Urxvt = 3,
    SgrPixels = 4,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CursorShape {
    Block = 0,
    Underline = 1,
    Bar = 2,
}

impl MouseTracking {
    pub(crate) fn from_raw(value: u8) -> Option<Self> {
        [Self::None, Self::X10, Self::Normal, Self::ButtonEvent, Self::AnyEvent].get(value as usize).copied()
    }
}

impl MouseEncoding {
    pub(crate) fn from_raw(value: u8) -> Option<Self> {
        [Self::X10, Self::Utf8, Self::Sgr, Self::Urxvt, Self::SgrPixels].get(value as usize).copied()
    }
}

impl CursorShape {
    pub(crate) fn from_raw(value: u8) -> Option<Self> {
        [Self::Block, Self::Underline, Self::Bar].get(value as usize).copied()
    }
}

/// Things a program signalled that the host may want to act on (attention, window title).
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct TerminalEvents {
    pub bells: usize,
    pub title_changed: bool,
    /// OSC 9 and OSC 777 desktop notifications, in order.
    pub notifications: Vec<String>,
}

impl TerminalEvents {
    pub fn is_empty(&self) -> bool {
        self.bells == 0 && !self.title_changed && self.notifications.is_empty()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Charset {
    Ascii = 0,
    DecSpecialGraphics = 1,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) struct SavedCursor {
    pub x: usize,
    pub y: usize,
    pub pending_wrap: bool,
    pub pen: Pen,
    pub origin: bool,
    pub charsets: [Charset; 2],
    pub active_charset: usize,
}

/// A terminal emulator: feed it what a program writes, read back its screen and its replies
/// for the program. Not thread-safe; callers serialize access.
///
/// Speaks the xterm dialect that TUIs such as Claude Code rely on: cursor addressing, scroll
/// regions, the alternate screen, SGR with 256 and 24-bit color, wide characters and grapheme
/// clusters, bracketed paste, focus and mouse reporting, synchronized output, and the device
/// queries those programs send at startup.
pub struct Terminal {
    pub(crate) cols: usize,
    pub(crate) rows: usize,
    pub(crate) scrollback: Scrollback,
    pub(crate) modes: TerminalModes,
    pub(crate) mouse_tracking: MouseTracking,
    pub(crate) mouse_encoding: MouseEncoding,
    pub(crate) cursor_shape: CursorShape,
    pub(crate) title: String,
    pub(crate) working_directory: Option<String>,
    /// Colors reported to programs that ask (OSC 10/11), as 0xRRGGBB.
    pub reported_foreground: u32,
    pub reported_background: u32,

    pub(crate) cursor_x: usize,
    pub(crate) cursor_y: usize,

    pub(crate) main: Grid,
    pub(crate) alternate: Option<Grid>,
    /// The active screen is `alternate`; never set without one.
    pub(crate) on_alternate: bool,
    pub(crate) pending_wrap: bool,
    pub(crate) pen: Pen,
    pub(crate) scroll_top: usize,
    pub(crate) scroll_bottom: usize,
    pub(crate) tab_stops: Vec<bool>,
    pub(crate) charsets: [Charset; 2],
    pub(crate) active_charset: usize,
    pub(crate) saved_main: Option<SavedCursor>,
    pub(crate) saved_alternate: Option<SavedCursor>,
    pub(crate) last_printed: u32,
    /// After a zero-width joiner, the next character joins the same cluster.
    pub(crate) join_next: bool,
    pub(crate) clusters: ClusterTable,
    pub(crate) parser: VtParser,
    output: Vec<u8>,
    events: TerminalEvents,
}

impl Terminal {
    /// A terminal with the 5000 lines of history every session keeps.
    pub fn new(cols: usize, rows: usize) -> Self {
        Self::with_scrollback(cols, rows, 5000)
    }

    pub fn with_scrollback(cols: usize, rows: usize, scrollback: usize) -> Self {
        let (cols, rows) = (cols.max(2), rows.max(1));
        Self {
            cols,
            rows,
            scrollback: Scrollback::new(scrollback),
            modes: TerminalModes::DEFAULTS,
            mouse_tracking: MouseTracking::None,
            mouse_encoding: MouseEncoding::X10,
            cursor_shape: CursorShape::Block,
            title: String::new(),
            working_directory: None,
            reported_foreground: 0x14233D,
            reported_background: 0xFFFFFF,
            cursor_x: 0,
            cursor_y: 0,
            main: Grid::new(cols, rows),
            alternate: None,
            on_alternate: false,
            pending_wrap: false,
            pen: Pen::default(),
            scroll_top: 0,
            scroll_bottom: rows - 1,
            tab_stops: Self::default_tab_stops(cols),
            charsets: [Charset::Ascii; 2],
            active_charset: 0,
            saved_main: None,
            saved_alternate: None,
            last_printed: 0,
            join_next: false,
            clusters: ClusterTable::default(),
            parser: VtParser::default(),
            output: Vec::new(),
            events: TerminalEvents::default(),
        }
    }

    pub fn cols(&self) -> usize {
        self.cols
    }
    pub fn rows(&self) -> usize {
        self.rows
    }
    pub fn scrollback(&self) -> &Scrollback {
        &self.scrollback
    }
    pub fn modes(&self) -> TerminalModes {
        self.modes
    }
    pub fn mouse_tracking(&self) -> MouseTracking {
        self.mouse_tracking
    }
    pub fn mouse_encoding(&self) -> MouseEncoding {
        self.mouse_encoding
    }
    pub fn cursor_shape(&self) -> CursorShape {
        self.cursor_shape
    }
    pub fn title(&self) -> &str {
        &self.title
    }
    pub fn working_directory(&self) -> Option<&str> {
        self.working_directory.as_deref()
    }
    pub fn is_alternate_screen(&self) -> bool {
        self.on_alternate
    }
    pub fn is_synchronizing(&self) -> bool {
        self.modes.contains(TerminalModes::SYNCHRONIZED_OUTPUT)
    }

    /// The active screen.
    pub(crate) fn grid(&self) -> &Grid {
        match &self.alternate {
            Some(alternate) if self.on_alternate => alternate,
            _ => &self.main,
        }
    }

    pub(crate) fn grid_mut(&mut self) -> &mut Grid {
        match &mut self.alternate {
            Some(alternate) if self.on_alternate => alternate,
            _ => &mut self.main,
        }
    }

    // Input from the program

    pub fn feed(&mut self, bytes: &[u8]) {
        // The parser calls back into the terminal, so it steps out of it while it runs.
        let mut parser = std::mem::take(&mut self.parser);
        parser.advance(bytes, self);
        self.parser = parser;
    }

    /// Bytes the terminal owes the program (query replies), if any.
    pub fn take_output(&mut self) -> Option<Vec<u8>> {
        if self.output.is_empty() {
            return None;
        }
        Some(std::mem::take(&mut self.output))
    }

    /// Events since the last call.
    pub fn take_events(&mut self) -> TerminalEvents {
        std::mem::take(&mut self.events)
    }

    pub(crate) fn respond(&mut self, text: &str) {
        self.output.extend_from_slice(text.as_bytes());
    }

    // Printing

    /// Appends a zero-width scalar (combining mark, joiner, variation selector) to the
    /// character before the cursor, turning it into a grapheme cluster.
    fn combine(&mut self, value: u32) {
        let (mut x, mut y) = (self.cursor_x, self.cursor_y);
        if !self.pending_wrap {
            if x > 0 {
                x -= 1;
            } else {
                if !(y > 0 && self.grid().is_wrapped(y - 1)) {
                    return;
                }
                y -= 1;
                x = self.cols - 1;
            }
        }
        if self.grid().row(y)[x].width() == CellWidth::Tail && x > 0 {
            x -= 1;
        }
        let mut cell = self.grid().row(y)[x];
        if cell.is_empty() {
            return;
        }
        let mut scalars = if cell.is_cluster() { self.clusters.scalars(cell.scalar()).to_vec() } else { vec![cell.scalar()] };
        scalars.push(value);
        let Some(id) = self.clusters.intern(scalars) else { return };
        cell.content = cell.content & !(Cell::SCALAR_MASK | Cell::CLUSTER_FLAG) | id | Cell::CLUSTER_FLAG;
        self.grid_mut().row_mut(y)[x] = cell;
    }

    /// The text of a cluster cell (see `Cell::is_cluster`).
    pub fn cluster_string(&self, id: u32) -> String {
        self.clusters.string(id)
    }

    fn active_charset_is_special(&self) -> bool {
        self.charsets[self.active_charset] == Charset::DecSpecialGraphics
    }

    // Cursor and scrolling

    pub(crate) fn wrap(&mut self) {
        self.pending_wrap = false;
        let y = self.cursor_y;
        self.grid_mut().set_wrapped(y, true);
        self.cursor_x = 0;
        self.index();
    }

    /// Moves down one line, scrolling the region when at its bottom.
    pub(crate) fn index(&mut self) {
        self.pending_wrap = false;
        if self.cursor_y == self.scroll_bottom {
            self.scroll_up(1);
        } else if self.cursor_y < self.rows - 1 {
            self.cursor_y += 1;
        }
    }

    pub(crate) fn reverse_index(&mut self) {
        self.pending_wrap = false;
        if self.cursor_y == self.scroll_top {
            self.scroll_down(1);
        } else if self.cursor_y > 0 {
            self.cursor_y -= 1;
        }
    }

    pub(crate) fn scroll_up(&mut self, count: usize) {
        let (top, bottom, background) = (self.scroll_top, self.scroll_bottom, self.pen.bg);
        // Only full-width scrolls of the main screen's top feed the scrollback, like xterm.
        if !self.on_alternate && top == 0 {
            self.main.scroll_up(top, bottom, count, background, Some(&mut self.scrollback));
        } else {
            self.grid_mut().scroll_up(top, bottom, count, background, None);
        }
    }

    pub(crate) fn scroll_down(&mut self, count: usize) {
        let (top, bottom, background) = (self.scroll_top, self.scroll_bottom, self.pen.bg);
        self.grid_mut().scroll_down(top, bottom, count, background);
    }

    /// Absolute move; rows are relative to the scroll region in origin mode.
    pub(crate) fn move_cursor(&mut self, x: usize, y: usize) {
        self.pending_wrap = false;
        self.cursor_x = x.min(self.cols - 1);
        self.cursor_y = if self.modes.contains(TerminalModes::ORIGIN) {
            (y + self.scroll_top).min(self.scroll_bottom)
        } else {
            y.min(self.rows - 1)
        };
    }

    pub(crate) fn cursor_up(&mut self, count: usize) {
        self.pending_wrap = false;
        let limit = if self.cursor_y >= self.scroll_top { self.scroll_top } else { 0 };
        self.cursor_y = self.cursor_y.saturating_sub(count).max(limit);
    }

    pub(crate) fn cursor_down(&mut self, count: usize) {
        self.pending_wrap = false;
        let limit = if self.cursor_y <= self.scroll_bottom { self.scroll_bottom } else { self.rows - 1 };
        self.cursor_y = (self.cursor_y + count).min(limit);
    }

    pub(crate) fn save_cursor(&mut self) {
        let saved = SavedCursor {
            x: self.cursor_x,
            y: self.cursor_y,
            pending_wrap: self.pending_wrap,
            pen: self.pen,
            origin: self.modes.contains(TerminalModes::ORIGIN),
            charsets: self.charsets,
            active_charset: self.active_charset,
        };
        if self.on_alternate {
            self.saved_alternate = Some(saved);
        } else {
            self.saved_main = Some(saved);
        }
    }

    pub(crate) fn restore_cursor(&mut self) {
        let Some(saved) = (if self.on_alternate { self.saved_alternate } else { self.saved_main }) else {
            self.move_cursor(0, 0);
            return;
        };
        self.cursor_x = saved.x.min(self.cols - 1);
        self.cursor_y = saved.y.min(self.rows - 1);
        self.pending_wrap = saved.pending_wrap && self.cursor_x == self.cols - 1;
        self.pen = saved.pen;
        self.set_mode(TerminalModes::ORIGIN, saved.origin);
        self.charsets = saved.charsets;
        self.active_charset = saved.active_charset;
    }

    // Editing

    pub(crate) fn insert_blanks(&mut self, count: usize) {
        self.pending_wrap = false;
        let (x, y, cols, blank) = (self.cursor_x, self.cursor_y, self.cols, Cell::blank(self.pen.bg));
        let n = count.min(cols - x);
        let row = self.grid_mut().row_mut(y);
        row.copy_within(x..cols - n, x + n);
        row[x..x + n].fill(blank);
        if row[cols - 1].width() == CellWidth::Wide {
            row[cols - 1] = blank;
        }
    }

    pub(crate) fn delete_chars(&mut self, count: usize) {
        self.pending_wrap = false;
        let (x, y, cols, blank) = (self.cursor_x, self.cursor_y, self.cols, Cell::blank(self.pen.bg));
        let n = count.min(cols - x);
        let row = self.grid_mut().row_mut(y);
        if row[x].width() == CellWidth::Tail && x > 0 {
            row[x - 1] = blank;
        }
        row.copy_within(x + n..cols, x);
        row[cols - n..].fill(blank);
        if row[x].width() == CellWidth::Tail {
            row[x] = blank;
        }
    }

    pub(crate) fn erase_chars(&mut self, count: usize) {
        self.pending_wrap = false;
        let (x, y, background) = (self.cursor_x, self.cursor_y, self.pen.bg);
        let end = self.cols.min(x + count);
        self.repair_wide_edges(y, x, end);
        self.grid_mut().clear(y, x, end, background);
    }

    pub(crate) fn erase_line(&mut self, mode: usize) {
        self.pending_wrap = false;
        let (x, y, cols, background) = (self.cursor_x, self.cursor_y, self.cols, self.pen.bg);
        match mode {
            0 => {
                self.repair_wide_edges(y, x, cols);
                self.grid_mut().clear(y, x, cols, background);
                self.grid_mut().set_wrapped(y, false);
            }
            1 => {
                self.repair_wide_edges(y, 0, x + 1);
                self.grid_mut().clear(y, 0, x + 1, background);
            }
            2 => self.grid_mut().clear_row(y, background),
            _ => {}
        }
    }

    pub(crate) fn erase_display(&mut self, mode: usize) {
        self.pending_wrap = false;
        let background = self.pen.bg;
        match mode {
            0 => {
                self.erase_line(0);
                for y in self.cursor_y + 1..self.rows {
                    self.grid_mut().clear_row(y, background);
                }
            }
            1 => {
                for y in 0..self.cursor_y {
                    self.grid_mut().clear_row(y, background);
                }
                self.erase_line(1);
            }
            2 => self.clear_screen(background),
            3 => self.scrollback.remove_all(),
            _ => {}
        }
    }

    pub(crate) fn clear_screen(&mut self, background: u32) {
        for y in 0..self.rows {
            self.grid_mut().clear_row(y, background);
        }
    }

    /// Clearing half of a wide character clears the other half too.
    fn repair_wide_edges(&mut self, y: usize, start: usize, end: usize) {
        let (cols, blank) = (self.cols, Cell::blank(self.pen.bg));
        let row = self.grid_mut().row_mut(y);
        if start > 0 && start < cols && row[start].width() == CellWidth::Tail {
            row[start - 1] = blank;
        }
        if end > 0 && end < cols && row[end - 1].width() == CellWidth::Wide {
            row[end] = blank;
        }
    }

    pub(crate) fn insert_lines(&mut self, count: usize) {
        if self.cursor_y < self.scroll_top || self.cursor_y > self.scroll_bottom {
            return;
        }
        let (y, bottom, background) = (self.cursor_y, self.scroll_bottom, self.pen.bg);
        self.grid_mut().scroll_down(y, bottom, count, background);
        self.cursor_x = 0;
        self.pending_wrap = false;
    }

    pub(crate) fn delete_lines(&mut self, count: usize) {
        if self.cursor_y < self.scroll_top || self.cursor_y > self.scroll_bottom {
            return;
        }
        let (y, bottom, background) = (self.cursor_y, self.scroll_bottom, self.pen.bg);
        self.grid_mut().scroll_up(y, bottom, count, background, None);
        self.cursor_x = 0;
        self.pending_wrap = false;
    }

    // Screens

    pub(crate) fn enter_alternate_screen(&mut self, clear: bool) {
        if !self.on_alternate {
            if !self.alternate.as_ref().is_some_and(|alternate| alternate.cols == self.cols && alternate.rows == self.rows) {
                self.alternate = Some(Grid::new(self.cols, self.rows));
            }
            self.on_alternate = true;
        }
        if clear {
            self.clear_screen(self.pen.bg);
        }
    }

    pub(crate) fn leave_alternate_screen(&mut self) {
        if !self.on_alternate {
            return;
        }
        self.on_alternate = false;
        // Programs repaint the alternate screen whenever they enter it; don't keep it around.
        self.alternate = None;
        self.saved_alternate = None;
    }

    pub fn resize(&mut self, new_cols: usize, new_rows: usize) {
        let (new_cols, new_rows) = (new_cols.max(2), new_rows.max(1));
        if new_cols == self.cols && new_rows == self.rows {
            return;
        }
        // Keep the main screen's cursor line visible: rows above it scroll into the history.
        let main_cursor = if self.on_alternate { self.saved_main.map_or(0, |saved| saved.y) } else { self.cursor_y };
        let shift = main_cursor.saturating_sub(new_rows - 1);
        // A cursor saved before the main screen shrank can be below it; Swift reads past the
        // grid there, this stops at its last row.
        for y in 0..shift.min(self.rows) {
            self.scrollback.push(self.main.row(y), self.main.is_wrapped(y));
        }
        self.main.resize(new_cols, new_rows, shift);
        if self.on_alternate {
            if let Some(saved) = &mut self.saved_main {
                saved.y -= shift;
            }
            let first_row = self.cursor_y.saturating_sub(new_rows - 1);
            if let Some(alternate) = &mut self.alternate {
                alternate.resize(new_cols, new_rows, first_row);
            }
        } else {
            self.cursor_y -= shift;
        }
        self.cols = new_cols;
        self.rows = new_rows;
        self.cursor_x = self.cursor_x.min(new_cols - 1);
        self.cursor_y = self.cursor_y.min(new_rows - 1);
        self.pending_wrap = false;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        let old_stops = std::mem::take(&mut self.tab_stops);
        self.tab_stops = (0..new_cols).map(|x| old_stops.get(x).copied().unwrap_or(x % 8 == 0 && x > 0)).collect();
    }

    pub(crate) fn full_reset(&mut self) {
        self.leave_alternate_screen();
        self.modes = TerminalModes::DEFAULTS;
        self.mouse_tracking = MouseTracking::None;
        self.mouse_encoding = MouseEncoding::X10;
        self.cursor_shape = CursorShape::Block;
        self.pen = Pen::default();
        self.charsets = [Charset::Ascii; 2];
        self.active_charset = 0;
        self.saved_main = None;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.tab_stops = Self::default_tab_stops(self.cols);
        self.title.clear();
        self.clear_screen(0);
        self.move_cursor(0, 0);
    }

    pub(crate) fn default_tab_stops(cols: usize) -> Vec<bool> {
        (0..cols).map(|x| x % 8 == 0 && x > 0).collect()
    }

    // Mode and event plumbing used by the control-sequence handlers

    pub(crate) fn set_mode(&mut self, mode: TerminalModes, on: bool) {
        if on {
            self.modes.insert(mode);
        } else {
            self.modes.remove(mode);
        }
    }

    pub(crate) fn set_title(&mut self, text: String) {
        self.title = text;
        self.events.title_changed = true;
    }

    pub(crate) fn bell(&mut self) {
        self.events.bells += 1;
    }

    pub(crate) fn notify(&mut self, text: String) {
        self.events.notifications.push(text);
    }
}

impl VtHandler for Terminal {
    fn print_ascii(&mut self, bytes: &[u8]) {
        if self.active_charset_is_special() || self.join_next || self.modes.contains(TerminalModes::INSERT) {
            for &byte in bytes {
                self.print(byte as u32);
            }
            return;
        }
        let (content_bits, fg, bg, cols) = (self.pen.content_bits, self.pen.fg, self.pen.bg, self.cols);
        let autowrap = self.modes.contains(TerminalModes::AUTOWRAP);
        let mut source = bytes;
        while !source.is_empty() {
            if self.pending_wrap {
                self.wrap();
            }
            let (x, y) = (self.cursor_x, self.cursor_y);
            let n = source.len().min(cols - x);
            let last = x + n - 1;
            let row = self.grid_mut().row_mut(y);
            if row[x].width() == CellWidth::Tail && x > 0 {
                row[x - 1] = Cell::blank(row[x - 1].bg);
            }
            if row[last].width() == CellWidth::Wide && last + 1 < cols {
                row[last + 1] = Cell::blank(row[last + 1].bg);
            }
            for (cell, &byte) in row[x..x + n].iter_mut().zip(source) {
                *cell = Cell::new(byte as u32 | content_bits, fg, bg);
            }
            source = &source[n..];
            if x + n >= cols {
                if !autowrap {
                    // Without autowrap the rest overwrites the last column; the final one stays.
                    if let Some(&byte) = source.last() {
                        row[cols - 1] = Cell::new(byte as u32 | content_bits, fg, bg);
                    }
                    source = &[];
                }
                self.cursor_x = cols - 1;
                self.pending_wrap = autowrap;
            } else {
                self.cursor_x += n;
            }
        }
        if let Some(&byte) = bytes.last() {
            self.last_printed = byte as u32;
        }
    }

    fn print(&mut self, scalar: u32) {
        let mut value = scalar;
        if value < 0x80 {
            if self.active_charset_is_special() && (0x5F..=0x7E).contains(&value) {
                value = DEC_SPECIAL_GRAPHICS[(value - 0x5F) as usize];
            }
        } else if value < 0xA0 {
            return; // C1 controls decoded from UTF-8 have no glyph
        }
        let mut width = if value < 0x7F { 1 } else { character_width::of(value) };
        if self.join_next {
            self.join_next = false;
            if width > 0 {
                self.combine(value);
                return;
            }
        }
        if width == 0 {
            self.combine(value);
            if value == 0x200D {
                self.join_next = true;
            }
            return;
        }
        if self.pending_wrap {
            self.wrap();
        }
        let (cols, pen) = (self.cols, self.pen);
        if width == 2 && cols < 2 {
            width = 1;
        }
        if width == 2 && self.cursor_x == cols - 1 {
            if !self.modes.contains(TerminalModes::AUTOWRAP) {
                return;
            }
            // A wide character never splits across lines: pad and wrap first.
            let (x, y) = (self.cursor_x, self.cursor_y);
            self.grid_mut().row_mut(y)[x] = Cell::blank(pen.bg);
            self.pending_wrap = true;
            self.wrap();
        }
        if self.modes.contains(TerminalModes::INSERT) {
            self.insert_blanks(width);
        }
        let (x, y) = (self.cursor_x, self.cursor_y);
        let row = self.grid_mut().row_mut(y);
        if row[x].width() == CellWidth::Tail && x > 0 {
            row[x - 1] = Cell::blank(row[x - 1].bg);
        }
        let last = x + width - 1;
        if row[last].width() == CellWidth::Wide && last + 1 < cols {
            row[last + 1] = Cell::blank(row[last + 1].bg);
        }
        if width == 1 {
            row[x] = Cell::new(value | pen.content_bits, pen.fg, pen.bg);
        } else {
            row[x] = Cell::new(value | (CellWidth::Wide as u32) << Cell::WIDTH_SHIFT | pen.content_bits, pen.fg, pen.bg);
            row[x + 1] = Cell::new((CellWidth::Tail as u32) << Cell::WIDTH_SHIFT | pen.content_bits, pen.fg, pen.bg);
        }
        self.last_printed = value;
        if x + width >= cols {
            self.cursor_x = cols - 1;
            if self.modes.contains(TerminalModes::AUTOWRAP) {
                self.pending_wrap = true;
            }
        } else {
            self.cursor_x += width;
        }
    }

    fn execute(&mut self, byte: u8) {
        self.execute_control(byte);
    }

    fn csi_dispatch(&mut self, params: crate::parser::CsiParams, collected: u32, final_byte: u8) {
        self.csi(params, collected, final_byte);
    }

    fn esc_dispatch(&mut self, collected: u32, final_byte: u8) {
        self.esc(collected, final_byte);
    }

    fn osc_dispatch(&mut self, data: &[u8], bell_terminated: bool) {
        self.osc(data, bell_terminated);
    }

    fn dcs_dispatch(&mut self, _params: crate::parser::CsiParams, collected: u32, final_byte: u8, _data: &[u8]) {
        self.dcs(collected, final_byte);
    }
}

/// DEC Special Graphics for 0x5F–0x7E (line drawing in `ESC ( 0`).
const DEC_SPECIAL_GRAPHICS: [u32; 32] = [
    0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
    0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
];

/// Interned grapheme clusters (base + combining marks, ZWJ emoji), shared by a terminal's
/// screens and scrollback. Ids are stable for the terminal's lifetime.
#[derive(Default)]
pub(crate) struct ClusterTable {
    entries: Vec<Vec<u32>>,
    ids: HashMap<Vec<u32>, u32>,
}

impl ClusterTable {
    pub fn intern(&mut self, scalars: Vec<u32>) -> Option<u32> {
        if let Some(&id) = self.ids.get(&scalars) {
            return Some(id);
        }
        if self.entries.len() >= Cell::SCALAR_MASK as usize {
            return None;
        }
        let id = self.entries.len() as u32;
        self.entries.push(scalars.clone());
        self.ids.insert(scalars, id);
        Some(id)
    }

    pub fn scalars(&self, id: u32) -> &[u32] {
        self.entries.get(id as usize).map_or(&[], Vec::as_slice)
    }

    pub fn string(&self, id: u32) -> String {
        self.scalars(id).iter().filter_map(|&value| char::from_u32(value)).collect()
    }

    /// Every cluster's scalars, by id.
    pub fn all_scalars(&self) -> &[Vec<u32>] {
        &self.entries
    }

    pub fn remove_all(&mut self) {
        self.entries.clear();
        self.ids.clear();
    }
}
