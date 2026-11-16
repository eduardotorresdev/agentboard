//! A terminal's whole state as bytes, so another process can pick up where this one is: the
//! screens, the scrollback, the cursor and pen, the modes, the cluster table, and the parser's
//! position inside a sequence (a snapshot taken between two halves of one finishes it right).
//! Restoring a snapshot into a terminal makes it render and answer exactly like the one it was
//! taken from.
//!
//! The bytes are the Swift `Terminal.snapshot()` format, version 2; each side restores the
//! other's.
//!
//! Not stored: the colors reported to programs (the owner sets those).

use crate::cell::{Cell, Pen};
use crate::grid::Grid;
use crate::parser::{Position, MAX_PARAMS, MAX_STRING};
use crate::terminal::{Charset, CursorShape, MouseEncoding, MouseTracking, SavedCursor, Terminal, TerminalModes};

const SNAPSHOT_MAGIC: u32 = 0x4142_5453; // "ABTS"
const SNAPSHOT_VERSION: i64 = 2;

impl Terminal {
    /// The terminal's state; `restore` reads it back.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut out = SnapshotWriter { bytes: Vec::new() };
        out.u32(SNAPSHOT_MAGIC);
        out.varint(SNAPSHOT_VERSION as u64);
        out.count(self.cols);
        out.count(self.rows);
        out.u32(self.modes.raw_value());
        out.byte(self.mouse_tracking as u8);
        out.byte(self.mouse_encoding as u8);
        out.byte(self.cursor_shape as u8);
        out.string(&self.title);
        out.bool(self.working_directory.is_some());
        if let Some(directory) = &self.working_directory {
            out.string(directory);
        }
        out.count(self.cursor_x);
        out.count(self.cursor_y);
        out.bool(self.pending_wrap);
        out.pen(self.pen);
        out.count(self.scroll_top);
        out.count(self.scroll_bottom);
        out.count(self.tab_stops.len());
        self.tab_stops.iter().for_each(|&stop| out.bool(stop));
        out.byte(self.charsets[0] as u8);
        out.byte(self.charsets[1] as u8);
        out.count(self.active_charset);
        out.saved_cursor(self.saved_main);
        out.saved_cursor(self.saved_alternate);
        out.u32(self.last_printed);
        out.bool(self.join_next);

        let clusters = self.clusters.all_scalars();
        out.count(clusters.len());
        for scalars in clusters {
            out.count(scalars.len());
            scalars.iter().for_each(|&scalar| out.varint(scalar as u64));
        }

        out.count(self.scrollback.count());
        self.scrollback.for_each_line(self.cols, |cells, wrapped| out.row(cells, wrapped));
        out.grid(&self.main);
        out.bool(self.alternate.is_some());
        if let Some(alternate) = &self.alternate {
            out.grid(alternate);
        }
        out.bool(self.on_alternate);
        out.parser(&self.parser.position());
        out.bytes
    }

    /// Replaces this terminal's state with `snapshot`'s, size included. Returns false, and
    /// changes nothing, when the bytes aren't a snapshot this version can read.
    pub fn restore(&mut self, snapshot: &[u8]) -> bool {
        let Some(state) = decode(snapshot) else { return false };
        self.cols = state.cols;
        self.rows = state.rows;
        self.modes = state.modes;
        self.mouse_tracking = state.mouse_tracking;
        self.mouse_encoding = state.mouse_encoding;
        self.cursor_shape = state.cursor_shape;
        self.title = state.title;
        self.working_directory = state.working_directory;
        self.cursor_x = state.cursor_x;
        self.cursor_y = state.cursor_y;
        self.pending_wrap = state.pending_wrap;
        self.pen = state.pen;
        self.scroll_top = state.scroll_top;
        self.scroll_bottom = state.scroll_bottom;
        self.tab_stops = state.tab_stops;
        self.charsets = state.charsets;
        self.active_charset = state.active_charset;
        self.saved_main = state.saved_main;
        self.saved_alternate = state.saved_alternate;
        self.last_printed = state.last_printed;
        self.join_next = state.join_next;

        self.clusters.remove_all();
        for scalars in state.clusters {
            self.clusters.intern(scalars);
        }

        self.scrollback.remove_all();
        for line in &state.scrollback {
            self.scrollback.push(&line.cells, line.wrapped);
        }
        self.main = filled(self.cols, self.rows, &state.main);
        self.alternate = state.alternate.as_deref().map(|rows| filled(self.cols, self.rows, rows));
        self.on_alternate = state.on_alternate;
        // A position the parser can't be at leaves it where it was, as in Swift.
        self.parser.move_to(state.parser);
        true
    }
}

fn filled(cols: usize, rows: usize, lines: &[SnapshotRow]) -> Grid {
    let mut grid = Grid::new(cols, rows);
    for (y, line) in lines.iter().enumerate() {
        grid.row_mut(y).copy_from_slice(&line.cells);
        grid.set_wrapped(y, line.wrapped);
    }
    grid
}

// Encoding

/// A row's cells and whether it soft-wraps into the next one.
struct SnapshotRow {
    cells: Vec<Cell>,
    wrapped: bool,
}

/// Little-endian fixed-width integers and LEB128 varints.
struct SnapshotWriter {
    bytes: Vec<u8>,
}

impl SnapshotWriter {
    fn byte(&mut self, value: u8) {
        self.bytes.push(value);
    }

    fn bool(&mut self, value: bool) {
        self.bytes.push(value as u8);
    }

    fn u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn varint(&mut self, mut value: u64) {
        while value >= 0x80 {
            self.bytes.push((value & 0x7F) as u8 | 0x80);
            value >>= 7;
        }
        self.bytes.push(value as u8);
    }

    fn count(&mut self, value: usize) {
        self.varint(value as u64);
    }

    fn string(&mut self, value: &str) {
        self.count(value.len());
        self.bytes.extend_from_slice(value.as_bytes());
    }

    fn pen(&mut self, pen: Pen) {
        self.u32(pen.content_bits);
        self.u32(pen.fg);
        self.u32(pen.bg);
    }

    fn saved_cursor(&mut self, saved: Option<SavedCursor>) {
        self.bool(saved.is_some());
        let Some(saved) = saved else { return };
        self.count(saved.x);
        self.count(saved.y);
        self.bool(saved.pending_wrap);
        self.pen(saved.pen);
        self.bool(saved.origin);
        self.byte(saved.charsets[0] as u8);
        self.byte(saved.charsets[1] as u8);
        self.count(saved.active_charset);
    }

    fn parser(&mut self, position: &Position) {
        self.byte(position.state);
        self.count(position.params.len());
        position.params.iter().for_each(|&param| self.varint(param as u64));
        self.varint(position.current_param as u64);
        self.bool(position.has_param);
        self.u32(position.colon_mask as u32);
        self.u32((position.colon_mask >> 32) as u32);
        self.u32(position.collected);
        self.count(position.string.len());
        self.bytes.extend_from_slice(&position.string);
        self.u32(position.utf8_scalar);
        self.varint(position.utf8_remaining as u64);
        self.u32(position.utf8_minimum);
    }

    fn grid(&mut self, grid: &Grid) {
        for y in 0..grid.rows {
            self.row(grid.row(y), grid.is_wrapped(y));
        }
    }

    /// Trailing default blanks trimmed, then runs of one style (the content's high bits, fg,
    /// bg) followed by one varint per cell for its scalar or cluster id.
    fn row(&mut self, cells: &[Cell], wrapped: bool) {
        let mut used = cells.len();
        while used > 0 && cells[used - 1].is_default_blank() {
            used -= 1;
        }
        self.bool(wrapped);
        self.count(used);
        let mut x = 0;
        while x < used {
            let (high, fg, bg) = (cells[x].content >> 21, cells[x].fg, cells[x].bg);
            let mut end = x + 1;
            while end < used && cells[end].content >> 21 == high && cells[end].fg == fg && cells[end].bg == bg {
                end += 1;
            }
            self.count(end - x);
            self.u32(high);
            self.u32(fg);
            self.u32(bg);
            for cell in &cells[x..end] {
                self.varint((cell.content & 0x1F_FFFF) as u64);
            }
            x = end;
        }
    }
}

/// Reads what `SnapshotWriter` wrote; every method is `None` past the end of the bytes.
struct SnapshotReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl SnapshotReader<'_> {
    fn byte(&mut self) -> Option<u8> {
        let value = *self.bytes.get(self.offset)?;
        self.offset += 1;
        Some(value)
    }

    fn bool(&mut self) -> Option<bool> {
        Some(self.byte()? != 0)
    }

    fn u32(&mut self) -> Option<u32> {
        let mut value = 0;
        for shift in [0, 8, 16, 24] {
            value |= (self.byte()? as u32) << shift;
        }
        Some(value)
    }

    /// Signed, as Swift reads it: ten bytes can spell a negative number.
    fn varint(&mut self) -> Option<i64> {
        let (mut value, mut shift) = (0u64, 0);
        loop {
            let next = self.byte()?;
            if shift >= 64 {
                return None;
            }
            value |= ((next & 0x7F) as u64) << shift;
            if next < 0x80 {
                return Some(value as i64);
            }
            shift += 7;
        }
    }

    /// A count that can't be larger than what is left to read, so a corrupt one fails fast.
    fn count(&mut self, limit: usize) -> Option<usize> {
        let value = usize::try_from(self.varint()?).ok()?;
        (value <= limit.min(self.bytes.len() - self.offset)).then_some(value)
    }

    fn string(&mut self) -> Option<String> {
        let length = self.count(usize::MAX)?;
        let text = String::from_utf8_lossy(&self.bytes[self.offset..self.offset + length]).into_owned();
        self.offset += length;
        Some(text)
    }

    fn pen(&mut self) -> Option<Pen> {
        Some(Pen { content_bits: self.u32()?, fg: self.u32()?, bg: self.u32()? })
    }

    fn charset(&mut self) -> Option<Charset> {
        match self.byte()? {
            0 => Some(Charset::Ascii),
            1 => Some(Charset::DecSpecialGraphics),
            _ => None,
        }
    }

    fn parser(&mut self) -> Option<Position> {
        let state = self.byte()?;
        let params = (0..self.count(MAX_PARAMS)?).map(|_| Some(self.varint()? as u16)).collect::<Option<_>>()?;
        let current_param = self.varint()?;
        let has_param = self.bool()?;
        let colon_mask = self.u32()? as u64 | (self.u32()? as u64) << 32;
        let collected = self.u32()?;
        let length = self.count(MAX_STRING)?;
        let string = self.bytes[self.offset..self.offset + length].to_vec();
        self.offset += length;
        Some(Position {
            state,
            params,
            current_param,
            has_param,
            colon_mask,
            collected,
            string,
            utf8_scalar: self.u32()?,
            utf8_remaining: self.varint()?,
            utf8_minimum: self.u32()?,
        })
    }

    fn saved_cursor(&mut self) -> Option<Option<SavedCursor>> {
        if !self.bool()? {
            return Some(None);
        }
        // Swift keeps whatever numbers it reads here and would index with them; a negative
        // position or a charset slot other than 0 or 1 can only come from corrupt bytes, and
        // is pulled into range instead.
        Some(Some(SavedCursor {
            x: self.varint()?.max(0) as usize,
            y: self.varint()?.max(0) as usize,
            pending_wrap: self.bool()?,
            pen: self.pen()?,
            origin: self.bool()?,
            charsets: [self.charset()?, self.charset()?],
            active_charset: self.varint()?.clamp(0, 1) as usize,
        }))
    }

    fn row(&mut self, cols: usize) -> Option<SnapshotRow> {
        let wrapped = self.bool()?;
        let used = self.count(cols)?;
        let mut cells = vec![Cell::default(); cols];
        let mut x = 0;
        while x < used {
            let length = self.count(used - x)?;
            if length == 0 {
                return None;
            }
            let (high, fg, bg) = (self.u32()?, self.u32()?, self.u32()?);
            for cell in &mut cells[x..x + length] {
                *cell = Cell::new(high << 21 | self.varint()? as u32 & 0x1F_FFFF, fg, bg);
            }
            x += length;
        }
        Some(SnapshotRow { cells, wrapped })
    }
}

struct DecodedSnapshot {
    cols: usize,
    rows: usize,
    modes: TerminalModes,
    mouse_tracking: MouseTracking,
    mouse_encoding: MouseEncoding,
    cursor_shape: CursorShape,
    title: String,
    working_directory: Option<String>,
    cursor_x: usize,
    cursor_y: usize,
    pending_wrap: bool,
    pen: Pen,
    scroll_top: usize,
    scroll_bottom: usize,
    tab_stops: Vec<bool>,
    charsets: [Charset; 2],
    active_charset: usize,
    saved_main: Option<SavedCursor>,
    saved_alternate: Option<SavedCursor>,
    last_printed: u32,
    join_next: bool,
    clusters: Vec<Vec<u32>>,
    scrollback: Vec<SnapshotRow>,
    main: Vec<SnapshotRow>,
    alternate: Option<Vec<SnapshotRow>>,
    on_alternate: bool,
    /// At rest for a version 1 snapshot, which didn't store it.
    parser: Position,
}

fn decode(bytes: &[u8]) -> Option<DecodedSnapshot> {
    let mut input = SnapshotReader { bytes, offset: 0 };
    if input.u32()? != SNAPSHOT_MAGIC {
        return None;
    }
    let version = input.varint()?;
    if version != 1 && version != 2 {
        return None;
    }
    let (cols, rows) = (input.varint()?, input.varint()?);
    if !(2..=4096).contains(&cols) || !(1..=4096).contains(&rows) {
        return None;
    }
    let (cols, rows) = (cols as usize, rows as usize);
    let modes = TerminalModes(input.u32()?);
    let mouse_tracking = MouseTracking::from_raw(input.byte()?)?;
    let mouse_encoding = MouseEncoding::from_raw(input.byte()?)?;
    let cursor_shape = CursorShape::from_raw(input.byte()?)?;
    let title = input.string()?;
    let working_directory = if input.bool()? { Some(input.string()?) } else { None };
    let cursor_x = input.varint()?.clamp(0, cols as i64 - 1) as usize;
    let cursor_y = input.varint()?.clamp(0, rows as i64 - 1) as usize;
    let pending_wrap = input.bool()?;
    let pen = input.pen()?;
    let (scroll_top, scroll_bottom) = (input.varint()?, input.varint()?);
    if !(0 <= scroll_top && scroll_top <= scroll_bottom && scroll_bottom < rows as i64) {
        return None;
    }
    let tab_stops = (0..input.count(usize::MAX)?).map(|_| input.bool()).collect::<Option<Vec<_>>>()?;
    if tab_stops.len() != cols {
        return None;
    }
    let charsets = [input.charset()?, input.charset()?];
    let active_charset = input.varint()?.clamp(0, 1) as usize;
    let saved_main = input.saved_cursor()?;
    let saved_alternate = input.saved_cursor()?;
    let last_printed = input.u32()?;
    let join_next = input.bool()?;
    let clusters = (0..input.count(usize::MAX)?)
        .map(|_| (0..input.count(usize::MAX)?).map(|_| Some(input.varint()? as u32)).collect())
        .collect::<Option<_>>()?;
    let scrollback = (0..input.count(usize::MAX)?).map(|_| input.row(cols)).collect::<Option<_>>()?;
    let main = (0..rows).map(|_| input.row(cols)).collect::<Option<_>>()?;
    let alternate: Option<Vec<SnapshotRow>> = if input.bool()? { Some((0..rows).map(|_| input.row(cols)).collect::<Option<_>>()?) } else { None };
    let on_alternate = input.bool()? && alternate.is_some();
    let parser = if version >= 2 { input.parser()? } else { Position::default() };
    Some(DecodedSnapshot {
        cols,
        rows,
        modes,
        mouse_tracking,
        mouse_encoding,
        cursor_shape,
        title,
        working_directory,
        cursor_x,
        cursor_y,
        pending_wrap,
        pen,
        scroll_top: scroll_top as usize,
        scroll_bottom: scroll_bottom as usize,
        tab_stops,
        charsets,
        active_charset,
        saved_main,
        saved_alternate,
        last_printed,
        join_next,
        clusters,
        scrollback,
        main,
        alternate,
        on_alternate,
        parser,
    })
}
