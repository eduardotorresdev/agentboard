use std::collections::VecDeque;

use crate::cell::Cell;

/// Lines that scrolled off the top of the main screen.
///
/// Lines are packed as they arrive: trailing blanks trimmed, styles run-length encoded
/// (10 bytes per run) and characters as varints (one byte for ASCII). Packed lines are
/// appended to 16 KB pages; the oldest page is freed once all its lines have expired. Typical
/// output costs a little over one byte per character instead of 12 bytes per cell.
pub struct Scrollback {
    limit: usize,
    count: usize,
    pages: VecDeque<Page>,
    /// Lines of the first page that already expired, and the byte offset of the first live one.
    head_expired: usize,
    head_offset: usize,
    /// Reused packing buffers for one line's style runs and characters.
    run_scratch: Vec<u8>,
    scalar_scratch: Vec<u8>,
}

struct Page {
    data: Vec<u8>,
    capacity: usize,
    lines: usize,
}

const PAGE_SIZE: usize = 16 * 1024;

impl Scrollback {
    pub fn new(limit: usize) -> Self {
        Self { limit, count: 0, pages: VecDeque::new(), head_expired: 0, head_offset: 0, run_scratch: Vec::new(), scalar_scratch: Vec::new() }
    }

    pub fn limit(&self) -> usize {
        self.limit
    }

    pub fn count(&self) -> usize {
        self.count
    }

    pub fn remove_all(&mut self) {
        self.pages.clear();
        self.head_expired = 0;
        self.head_offset = 0;
        self.count = 0;
    }

    pub(crate) fn push(&mut self, row: &[Cell], wrapped: bool) {
        if self.limit == 0 {
            return;
        }
        let (header, run_count) = self.encode(row, wrapped);
        let body = varint_size(header) + varint_size(run_count) + self.run_scratch.len() + self.scalar_scratch.len();
        let total = varint_size(body) + body;
        if self.pages.back().is_none_or(|page| page.capacity - page.data.len() < total) {
            let capacity = PAGE_SIZE.max(total);
            self.pages.push_back(Page { data: Vec::with_capacity(capacity), capacity, lines: 0 });
        }
        if let Some(page) = self.pages.back_mut() {
            write_varint(body, &mut page.data);
            write_varint(header, &mut page.data);
            write_varint(run_count, &mut page.data);
            page.data.extend_from_slice(&self.run_scratch);
            page.data.extend_from_slice(&self.scalar_scratch);
            page.lines += 1;
        }
        self.count += 1;
        if self.count > self.limit {
            self.drop_oldest();
        }
    }

    /// The line `index` lines after the oldest one, unpacked to `cols` cells, and whether it
    /// soft-wraps into the next line.
    pub fn line(&self, index: usize, cols: usize) -> Option<(Vec<Cell>, bool)> {
        if index >= self.count {
            return None;
        }
        let mut remaining = index;
        for (page_index, page) in self.pages.iter().enumerate() {
            let live = if page_index == 0 { page.lines - self.head_expired } else { page.lines };
            if remaining >= live {
                remaining -= live;
                continue;
            }
            let mut cursor = if page_index == 0 { self.head_offset } else { 0 };
            for _ in 0..remaining {
                let length = read_varint(&page.data, &mut cursor);
                cursor += length;
            }
            let length = read_varint(&page.data, &mut cursor);
            return Some(decode(&page.data[cursor..cursor + length], cols));
        }
        None
    }

    /// Every line from the oldest, unpacked to `cols` cells, in one pass over the pages.
    pub(crate) fn for_each_line(&self, cols: usize, mut body: impl FnMut(&[Cell], bool)) {
        for (page_index, page) in self.pages.iter().enumerate() {
            let mut cursor = if page_index == 0 { self.head_offset } else { 0 };
            let live = if page_index == 0 { page.lines - self.head_expired } else { page.lines };
            for _ in 0..live {
                let length = read_varint(&page.data, &mut cursor);
                let (cells, wrapped) = decode(&page.data[cursor..cursor + length], cols);
                body(&cells, wrapped);
                cursor += length;
            }
        }
    }

    fn drop_oldest(&mut self) {
        let Some(page) = self.pages.front() else { return };
        let mut cursor = self.head_offset;
        let length = read_varint(&page.data, &mut cursor);
        self.head_offset = cursor + length;
        self.head_expired += 1;
        self.count -= 1;
        if self.head_expired == page.lines {
            self.pages.pop_front();
            self.head_expired = 0;
            self.head_offset = 0;
        }
    }

    // Packing

    /// Layout: varint (cells << 1 | wrapped), varint runs, runs of (varint length, u16 content
    /// high bits, u32 fg, u32 bg), then one varint per cell for its scalar.
    ///
    /// One pass over the row writes runs and characters into the scratch buffers; returns the
    /// header and the run count.
    fn encode(&mut self, row: &[Cell], wrapped: bool) -> (usize, usize) {
        self.run_scratch.clear();
        self.scalar_scratch.clear();
        // Trim trailing blanks; a default blank cell is all zero bits.
        let mut used = row.len();
        while used > 0 && row[used - 1].is_default_blank() {
            used -= 1;
        }
        let header = used << 1 | wrapped as usize;
        if used == 0 {
            return (header, 0);
        }
        let mut run_count = 0;
        let (mut high, mut fg, mut bg, mut length) = (row[0].content >> 21, row[0].fg, row[0].bg, 0);
        let mut close_run = |runs: &mut Vec<u8>, length: usize, high: u32, fg: u32, bg: u32| {
            write_varint(length, runs);
            runs.extend_from_slice(&(high as u16).to_le_bytes());
            runs.extend_from_slice(&fg.to_le_bytes());
            runs.extend_from_slice(&bg.to_le_bytes());
            run_count += 1;
        };
        for cell in &row[..used] {
            let cell_high = cell.content >> 21;
            if cell_high != high || cell.fg != fg || cell.bg != bg {
                close_run(&mut self.run_scratch, length, high, fg, bg);
                (high, fg, bg, length) = (cell_high, cell.fg, cell.bg, 0);
            }
            length += 1;
            write_varint((cell.content & 0x1F_FFFF) as usize, &mut self.scalar_scratch);
        }
        close_run(&mut self.run_scratch, length, high, fg, bg);
        (header, run_count)
    }
}

fn decode(data: &[u8], cols: usize) -> (Vec<Cell>, bool) {
    let mut cursor = 0;
    let header = read_varint(data, &mut cursor);
    let used = header >> 1;
    let mut cells = vec![Cell::default(); cols.max(used)];
    let run_count = read_varint(data, &mut cursor);
    let mut scalars = cursor;
    for _ in 0..run_count {
        read_varint(data, &mut scalars);
        scalars += 10;
    }
    let mut x = 0;
    for _ in 0..run_count {
        let length = read_varint(data, &mut cursor);
        let high = u16::from_le_bytes([data[cursor], data[cursor + 1]]) as u32;
        let fg = u32::from_le_bytes([data[cursor + 2], data[cursor + 3], data[cursor + 4], data[cursor + 5]]);
        let bg = u32::from_le_bytes([data[cursor + 6], data[cursor + 7], data[cursor + 8], data[cursor + 9]]);
        cursor += 10;
        for _ in 0..length {
            cells[x] = Cell::new(high << 21 | read_varint(data, &mut scalars) as u32, fg, bg);
            x += 1;
        }
    }
    cells.truncate(cols);
    (cells, header & 1 == 1)
}

fn varint_size(mut value: usize) -> usize {
    let mut size = 1;
    while value >= 0x80 {
        value >>= 7;
        size += 1;
    }
    size
}

fn write_varint(mut value: usize, to: &mut Vec<u8>) {
    while value >= 0x80 {
        to.push((value & 0x7F) as u8 | 0x80);
        value >>= 7;
    }
    to.push(value as u8);
}

fn read_varint(data: &[u8], cursor: &mut usize) -> usize {
    let (mut value, mut shift) = (0, 0);
    loop {
        let byte = data[*cursor];
        *cursor += 1;
        value |= ((byte & 0x7F) as usize) << shift;
        if byte < 0x80 {
            return value;
        }
        shift += 7;
    }
}
