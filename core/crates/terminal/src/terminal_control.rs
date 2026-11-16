//! Control functions: C0 controls, ESC, CSI, OSC and DCS sequences.

use crate::cell::{Cell, CellAttributes, Pen, TerminalColor};
use crate::parser::{CsiParams, VtHandler};
use crate::swift_string::{has_prefix, split_semicolons};
use crate::terminal::{Charset, CursorShape, MouseEncoding, MouseTracking, Terminal, TerminalModes};

/// Private markers and intermediates as the parser collects them.
const fn marker(text: &[u8]) -> u32 {
    let (mut value, mut index) = (0, 0);
    while index < text.len() {
        value = value << 8 | text[index] as u32;
        index += 1;
    }
    value
}

const QUESTION: u32 = marker(b"?");
const GREATER: u32 = marker(b">");
const SPACE: u32 = marker(b" ");
const BANG: u32 = marker(b"!");
const DOLLAR: u32 = marker(b"$");
const QUESTION_DOLLAR: u32 = marker(b"?$");
const PLUS: u32 = marker(b"+");
const HASH: u32 = marker(b"#");
const OPEN: u32 = marker(b"(");
const CLOSE: u32 = marker(b")");

impl Terminal {
    pub(crate) fn execute_control(&mut self, byte: u8) {
        match byte {
            0x07 => self.bell(),
            0x08 => {
                // xterm: backspace from the wrap-pending position stays on the last column.
                if self.pending_wrap {
                    self.pending_wrap = false;
                } else if self.cursor_x > 0 {
                    self.cursor_x -= 1;
                }
            }
            0x09 => self.tab_forward(1),
            0x0A..=0x0C => {
                self.index();
                if self.modes.contains(TerminalModes::LINEFEED_NEWLINE) {
                    self.cursor_x = 0;
                }
            }
            0x0D => {
                self.cursor_x = 0;
                self.pending_wrap = false;
            }
            0x0E => self.active_charset = 1,
            0x0F => self.active_charset = 0,
            _ => {}
        }
    }

    fn tab_forward(&mut self, count: usize) {
        self.pending_wrap = false;
        for _ in 0..count {
            let mut x = self.cursor_x + 1;
            while x < self.cols - 1 && !self.tab_stops[x] {
                x += 1;
            }
            self.cursor_x = x.min(self.cols - 1);
        }
    }

    fn tab_backward(&mut self, count: usize) {
        self.pending_wrap = false;
        for _ in 0..count {
            let mut x = self.cursor_x.saturating_sub(1);
            while x > 0 && !self.tab_stops[x] {
                x -= 1;
            }
            self.cursor_x = x;
        }
    }

    // ESC

    pub(crate) fn esc(&mut self, collected: u32, final_byte: u8) {
        match collected {
            0 => match final_byte {
                b'7' => self.save_cursor(),
                b'8' => self.restore_cursor(),
                b'D' => self.index(),
                b'E' => {
                    self.index();
                    self.cursor_x = 0;
                }
                b'H' => self.tab_stops[self.cursor_x] = true,
                b'M' => self.reverse_index(),
                b'c' => self.full_reset(),
                b'=' => self.set_mode(TerminalModes::APPLICATION_KEYPAD, true),
                b'>' => self.set_mode(TerminalModes::APPLICATION_KEYPAD, false),
                b'Z' => self.respond("\x1b[?62;22c"),
                _ => {}
            },
            OPEN | CLOSE => {
                let charset = if final_byte == b'0' { Charset::DecSpecialGraphics } else { Charset::Ascii };
                self.charsets[if collected == OPEN { 0 } else { 1 }] = charset;
            }
            HASH if final_byte == b'8' => {
                // DECALN: fill the screen with E (alignment test).
                for y in 0..self.rows {
                    self.grid_mut().row_mut(y).fill(Cell::new(0x45, 0, 0));
                }
            }
            _ => {}
        }
    }

    // CSI

    pub(crate) fn csi(&mut self, p: CsiParams, collected: u32, final_byte: u8) {
        match collected {
            0 => self.standard_csi(p, final_byte),
            QUESTION => self.private_csi(p, final_byte),
            GREATER => {
                if final_byte == b'c' {
                    self.respond("\x1b[>1;10;0c"); // DA2
                }
                // XTVERSION (q), modifyOtherKeys (m) and kitty keyboard (u) are not supported.
            }
            SPACE if final_byte == b'q' => {
                self.cursor_shape = match p.get(0) {
                    3 | 4 => CursorShape::Underline,
                    5 | 6 => CursorShape::Bar,
                    _ => CursorShape::Block,
                }
            }
            BANG if final_byte == b'p' => self.soft_reset(),
            DOLLAR if final_byte == b'p' => self.respond(&format!("\x1b[{};{}$y", p.get(0), self.ansi_mode_state(p.get(0)))),
            QUESTION_DOLLAR if final_byte == b'p' => self.respond(&format!("\x1b[?{};{}$y", p.get(0), self.dec_mode_state(p.get(0)))),
            _ => {}
        }
    }

    fn standard_csi(&mut self, p: CsiParams, final_byte: u8) {
        let n = p.value(0, 1);
        match final_byte {
            b'@' => self.insert_blanks(n),
            b'A' => self.cursor_up(n),
            b'B' | b'e' => self.cursor_down(n),
            b'C' | b'a' => {
                self.pending_wrap = false;
                self.cursor_x = (self.cols - 1).min(self.cursor_x + n);
            }
            b'D' => {
                self.pending_wrap = false;
                self.cursor_x = self.cursor_x.saturating_sub(n);
            }
            b'E' => {
                self.cursor_down(n);
                self.cursor_x = 0;
            }
            b'F' => {
                self.cursor_up(n);
                self.cursor_x = 0;
            }
            b'G' | b'`' => {
                self.pending_wrap = false;
                self.cursor_x = (n - 1).min(self.cols - 1);
            }
            b'H' | b'f' => self.move_cursor(p.value(1, 1) - 1, p.value(0, 1) - 1),
            b'I' => self.tab_forward(n),
            b'J' => self.erase_display(p.get(0)),
            b'K' => self.erase_line(p.get(0)),
            b'L' => self.insert_lines(n),
            b'M' => self.delete_lines(n),
            b'P' => self.delete_chars(n),
            b'S' => self.scroll_up(n),
            b'T' if p.count() <= 1 => self.scroll_down(n),
            b'X' => self.erase_chars(n),
            b'Z' => self.tab_backward(n),
            b'b' => {
                if self.last_printed != 0 {
                    for _ in 0..n.min(65535) {
                        let scalar = self.last_printed;
                        self.print(scalar);
                    }
                }
            }
            b'c' => {
                if p.get(0) == 0 {
                    self.respond("\x1b[?62;22c"); // DA1: VT220 with ANSI color
                }
            }
            b'd' => self.move_cursor(self.cursor_x, p.value(0, 1) - 1),
            b'g' => {
                if p.get(0) == 0 {
                    self.tab_stops[self.cursor_x] = false;
                } else if p.get(0) == 3 {
                    self.tab_stops = vec![false; self.cols];
                }
            }
            b'h' | b'l' => {
                for index in 0..p.count() {
                    match p.get(index) {
                        4 => self.set_mode(TerminalModes::INSERT, final_byte == b'h'),
                        20 => self.set_mode(TerminalModes::LINEFEED_NEWLINE, final_byte == b'h'),
                        _ => {}
                    }
                }
            }
            b'm' => self.select_graphic_rendition(p),
            b'n' => {
                if p.get(0) == 5 {
                    self.respond("\x1b[0n");
                }
                if p.get(0) == 6 {
                    self.respond(&format!("\x1b[{};{}R", self.reported_row() + 1, self.cursor_x + 1));
                }
            }
            b'r' => {
                let (top, bottom) = (p.value(0, 1) - 1, p.value(1, self.rows) - 1);
                if top < bottom && bottom < self.rows {
                    self.scroll_top = top;
                    self.scroll_bottom = bottom;
                    self.move_cursor(0, 0);
                }
            }
            b's' => self.save_cursor(),
            b'u' => self.restore_cursor(),
            b't' => {
                if p.get(0) == 18 {
                    self.respond(&format!("\x1b[8;{};{}t", self.rows, self.cols));
                }
            }
            _ => {}
        }
    }

    fn private_csi(&mut self, p: CsiParams, final_byte: u8) {
        match final_byte {
            b'h' | b'l' => {
                for index in 0..p.count() {
                    self.set_private_mode(p.get(index), final_byte == b'h');
                }
            }
            b'J' => self.erase_display(p.get(0)),
            b'K' => self.erase_line(p.get(0)),
            b'n' => {
                if p.get(0) == 6 {
                    self.respond(&format!("\x1b[?{};{}R", self.reported_row() + 1, self.cursor_x + 1));
                }
            }
            // ?u (kitty keyboard query) gets no answer: the program falls back to legacy keys.
            _ => {}
        }
    }

    /// Cursor row as programs see it: relative to the scroll region in origin mode.
    ///
    /// Signed, as in Swift: the cursor can sit above the region when origin mode is on.
    fn reported_row(&self) -> isize {
        let top = if self.modes.contains(TerminalModes::ORIGIN) { self.scroll_top } else { 0 };
        self.cursor_y as isize - top as isize
    }

    fn set_private_mode(&mut self, mode: usize, on: bool) {
        let tracking = |tracking| if on { tracking } else { MouseTracking::None };
        let encoding = |encoding| if on { encoding } else { MouseEncoding::X10 };
        match mode {
            1 => self.set_mode(TerminalModes::APPLICATION_CURSOR, on),
            5 => self.set_mode(TerminalModes::REVERSE_VIDEO, on),
            6 => {
                self.set_mode(TerminalModes::ORIGIN, on);
                self.move_cursor(0, 0);
            }
            7 => self.set_mode(TerminalModes::AUTOWRAP, on),
            9 => self.mouse_tracking = tracking(MouseTracking::X10),
            12 => self.set_mode(TerminalModes::CURSOR_BLINK, on),
            25 => self.set_mode(TerminalModes::CURSOR_VISIBLE, on),
            47 => {
                if on {
                    self.enter_alternate_screen(false);
                } else {
                    self.leave_alternate_screen();
                }
            }
            66 => self.set_mode(TerminalModes::APPLICATION_KEYPAD, on),
            1000 => self.mouse_tracking = tracking(MouseTracking::Normal),
            1002 => self.mouse_tracking = tracking(MouseTracking::ButtonEvent),
            1003 => self.mouse_tracking = tracking(MouseTracking::AnyEvent),
            1004 => self.set_mode(TerminalModes::FOCUS_EVENTS, on),
            1005 => self.mouse_encoding = encoding(MouseEncoding::Utf8),
            1006 => self.mouse_encoding = encoding(MouseEncoding::Sgr),
            1007 => self.set_mode(TerminalModes::ALTERNATE_SCROLL, on),
            1015 => self.mouse_encoding = encoding(MouseEncoding::Urxvt),
            1016 => self.mouse_encoding = encoding(MouseEncoding::SgrPixels),
            1047 => {
                if on {
                    self.enter_alternate_screen(false);
                } else {
                    if self.on_alternate {
                        self.clear_screen(self.pen.bg);
                    }
                    self.leave_alternate_screen();
                }
            }
            1048 => {
                if on {
                    self.save_cursor();
                } else {
                    self.restore_cursor();
                }
            }
            1049 => {
                if on {
                    self.save_cursor();
                    self.enter_alternate_screen(true);
                } else {
                    self.leave_alternate_screen();
                    self.restore_cursor();
                }
            }
            2004 => self.set_mode(TerminalModes::BRACKETED_PASTE, on),
            2026 => self.set_mode(TerminalModes::SYNCHRONIZED_OUTPUT, on),
            _ => {}
        }
    }

    /// DECRQM answer: 1 set, 2 reset, 0 not recognized.
    fn dec_mode_state(&self, mode: usize) -> u8 {
        let state = |set: bool| if set { 1 } else { 2 };
        let flag = match mode {
            1 => TerminalModes::APPLICATION_CURSOR,
            5 => TerminalModes::REVERSE_VIDEO,
            6 => TerminalModes::ORIGIN,
            7 => TerminalModes::AUTOWRAP,
            12 => TerminalModes::CURSOR_BLINK,
            25 => TerminalModes::CURSOR_VISIBLE,
            66 => TerminalModes::APPLICATION_KEYPAD,
            1004 => TerminalModes::FOCUS_EVENTS,
            1007 => TerminalModes::ALTERNATE_SCROLL,
            2004 => TerminalModes::BRACKETED_PASTE,
            2026 => TerminalModes::SYNCHRONIZED_OUTPUT,
            47 | 1047 | 1049 => return state(self.on_alternate),
            1000 => return state(self.mouse_tracking == MouseTracking::Normal),
            1002 => return state(self.mouse_tracking == MouseTracking::ButtonEvent),
            1003 => return state(self.mouse_tracking == MouseTracking::AnyEvent),
            1006 => return state(self.mouse_encoding == MouseEncoding::Sgr),
            _ => return 0,
        };
        state(self.modes.contains(flag))
    }

    fn ansi_mode_state(&self, mode: usize) -> u8 {
        let state = |flag| if self.modes.contains(flag) { 1 } else { 2 };
        match mode {
            4 => state(TerminalModes::INSERT),
            20 => state(TerminalModes::LINEFEED_NEWLINE),
            _ => 0,
        }
    }

    fn soft_reset(&mut self) {
        for mode in [TerminalModes::INSERT, TerminalModes::ORIGIN, TerminalModes::APPLICATION_CURSOR, TerminalModes::APPLICATION_KEYPAD] {
            self.modes.remove(mode);
        }
        self.modes.insert(TerminalModes::DEFAULTS);
        self.pen = Pen::default();
        self.charsets = [Charset::Ascii; 2];
        self.active_charset = 0;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.saved_main = None;
        self.saved_alternate = None;
        self.pending_wrap = false;
    }

    // SGR

    fn select_graphic_rendition(&mut self, p: CsiParams) {
        let (mut attributes, mut fg, mut bg) = (self.pen.attributes(), self.pen.foreground(), self.pen.background());
        if p.count() == 0 {
            self.pen = Pen::default();
            return;
        }
        let mut index = 0;
        while index < p.count() {
            let value = p.get(index);
            match value {
                0 => {
                    attributes = CellAttributes::EMPTY;
                    fg = TerminalColor::DEFAULT;
                    bg = TerminalColor::DEFAULT;
                }
                1 => attributes.insert(CellAttributes::BOLD),
                2 => attributes.insert(CellAttributes::DIM),
                3 => attributes.insert(CellAttributes::ITALIC),
                4 => {
                    attributes.remove(CellAttributes::UNDERLINES);
                    if p.is_subparameter(index + 1) {
                        match p.get(index + 1) {
                            0 => {}
                            2 => attributes.insert(CellAttributes::DOUBLE_UNDERLINE),
                            3 => attributes.insert(CellAttributes::CURLY_UNDERLINE),
                            _ => attributes.insert(CellAttributes::UNDERLINE),
                        }
                    } else {
                        attributes.insert(CellAttributes::UNDERLINE);
                    }
                }
                5 | 6 => attributes.insert(CellAttributes::BLINK),
                7 => attributes.insert(CellAttributes::INVERSE),
                8 => attributes.insert(CellAttributes::INVISIBLE),
                9 => attributes.insert(CellAttributes::STRIKETHROUGH),
                21 => {
                    attributes.remove(CellAttributes::UNDERLINES);
                    attributes.insert(CellAttributes::DOUBLE_UNDERLINE);
                }
                22 => attributes.remove(CellAttributes::BOLD.union(CellAttributes::DIM)),
                23 => attributes.remove(CellAttributes::ITALIC),
                24 => attributes.remove(CellAttributes::UNDERLINES),
                25 => attributes.remove(CellAttributes::BLINK),
                27 => attributes.remove(CellAttributes::INVERSE),
                28 => attributes.remove(CellAttributes::INVISIBLE),
                29 => attributes.remove(CellAttributes::STRIKETHROUGH),
                30..=37 => fg = TerminalColor::palette((value - 30) as u8),
                38 => {
                    let (color, consumed) = extended_color(p, index);
                    fg = color.unwrap_or(fg);
                    index += consumed;
                }
                39 => fg = TerminalColor::DEFAULT,
                40..=47 => bg = TerminalColor::palette((value - 40) as u8),
                48 => {
                    let (color, consumed) = extended_color(p, index);
                    bg = color.unwrap_or(bg);
                    index += consumed;
                }
                49 => bg = TerminalColor::DEFAULT,
                53 => attributes.insert(CellAttributes::OVERLINE),
                55 => attributes.remove(CellAttributes::OVERLINE),
                58 => index += extended_color(p, index).1, // underline color: parsed, not drawn
                90..=97 => fg = TerminalColor::palette((value - 90 + 8) as u8),
                100..=107 => bg = TerminalColor::palette((value - 100 + 8) as u8),
                _ => {}
            }
            index += 1;
            while index < p.count() && p.is_subparameter(index) {
                index += 1;
            }
        }
        self.pen = Pen::default();
        self.pen.set_foreground(fg);
        self.pen.set_background(bg);
        self.pen.set_attributes(attributes);
    }

    // OSC and DCS

    pub(crate) fn osc(&mut self, data: &[u8], bell_terminated: bool) {
        let separator = data.iter().position(|&byte| byte == b';').unwrap_or(data.len());
        // Swift's `Int(String)`: an optional sign and decimal digits, nothing else.
        let Some(command) = std::str::from_utf8(&data[..separator]).ok().and_then(|text| text.parse::<i64>().ok()) else { return };
        let text = String::from_utf8_lossy(data.get(separator + 1..).unwrap_or_default());
        let terminator = if bell_terminated { "\x07" } else { "\x1b\\" };
        match command {
            0 | 2 => self.set_title(text.into_owned()),
            7 => self.working_directory = Some(text.into_owned()),
            9 => {
                // iTerm2 notifications; "9;4;…" is ConEmu's progress report, not a message.
                if !has_prefix(&text, "4;") {
                    self.notify(text.into_owned());
                }
            }
            10..=12 => {
                if !has_prefix(&text, "?") {
                    return;
                }
                let color = if command == 11 { self.reported_background } else { self.reported_foreground };
                let channel = |shift: u32| format!("{0:02x}{0:02x}", (color >> shift) & 0xFF);
                self.respond(&format!("\x1b]{command};rgb:{}/{}/{}{terminator}", channel(16), channel(8), channel(0)));
            }
            777 => {
                let parts = split_semicolons(&text, 2);
                if parts[0] == "notify" {
                    self.notify(parts[1..].join(": "));
                }
            }
            // 8 (hyperlinks), 52 (clipboard), 133 (shell marks) and the rest are ignored.
            _ => {}
        }
    }

    pub(crate) fn dcs(&mut self, collected: u32, final_byte: u8) {
        // Answer "unsupported" to status and capability requests so programs don't wait.
        if collected == DOLLAR && final_byte == b'q' {
            self.respond("\x1bP0$r\x1b\\");
        }
        if collected == PLUS && final_byte == b'q' {
            self.respond("\x1bP0+r\x1b\\");
        }
    }
}

/// `38;5;n`, `38;2;r;g;b` and their colon forms (`38:5:n`, `38:2:[space]:r:g:b`). Returns
/// how many semicolon-separated parameters it used; colon sub-parameters are skipped by
/// the caller.
fn extended_color(p: CsiParams, index: usize) -> (Option<TerminalColor>, usize) {
    let byte = |i: usize| p.get(i).min(255) as u8;
    if p.is_subparameter(index + 1) {
        let mut subcount = 0;
        while p.is_subparameter(index + 1 + subcount) && index + 1 + subcount < p.count() {
            subcount += 1;
        }
        return match (p.get(index + 1), subcount) {
            (5, 2..) => (Some(TerminalColor::palette(byte(index + 2))), 0),
            (2, 5..) => (Some(TerminalColor::rgb(byte(index + 3), byte(index + 4), byte(index + 5))), 0),
            (2, 4) => (Some(TerminalColor::rgb(byte(index + 2), byte(index + 3), byte(index + 4))), 0),
            _ => (None, 0),
        };
    }
    match p.get(index + 1) {
        5 if index + 2 < p.count() => (Some(TerminalColor::palette(byte(index + 2))), 2),
        2 if index + 4 < p.count() => (Some(TerminalColor::rgb(byte(index + 2), byte(index + 3), byte(index + 4))), 4),
        _ => (None, (p.count() - index - 1).min(1)),
    }
}
