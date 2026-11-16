/// Receives what the parser recognizes. Implemented by `Terminal`.
pub(crate) trait VtHandler {
    /// A run of printable ASCII (0x20–0x7E), the overwhelmingly common case.
    fn print_ascii(&mut self, bytes: &[u8]);
    fn print(&mut self, scalar: u32);
    fn execute(&mut self, byte: u8);
    fn csi_dispatch(&mut self, params: CsiParams, collected: u32, final_byte: u8);
    fn esc_dispatch(&mut self, collected: u32, final_byte: u8);
    fn osc_dispatch(&mut self, data: &[u8], bell_terminated: bool);
    fn dcs_dispatch(&mut self, params: CsiParams, collected: u32, final_byte: u8, data: &[u8]);
}

/// Numeric parameters of a CSI or DCS sequence. Missing parameters read as 0.
#[derive(Clone, Copy)]
pub(crate) struct CsiParams<'a> {
    pub values: &'a [u16],
    /// Bit `i` set: parameter `i` followed a ':' (a sub-parameter of the one before).
    pub colon_mask: u64,
}

impl CsiParams<'_> {
    pub fn count(&self) -> usize {
        self.values.len()
    }

    pub fn get(&self, index: usize) -> usize {
        self.values.get(index).map_or(0, |&value| value as usize)
    }

    /// The parameter, or `fallback` when it is missing or zero (cursor movement semantics).
    pub fn value(&self, index: usize, fallback: usize) -> usize {
        match self.get(index) {
            0 => fallback,
            value => value,
        }
    }

    pub fn is_subparameter(&self, index: usize) -> bool {
        index < 64 && self.colon_mask & (1 << index) != 0
    }
}

// Raw values are part of the snapshot format.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
enum State {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    CsiIgnore,
    OscString,
    DcsEntry,
    DcsParam,
    DcsIntermediate,
    DcsPassthrough,
    DcsIgnore,
    /// SOS, PM, APC
    IgnoreString,
}

impl State {
    const ALL: [State; 14] = [
        State::Ground,
        State::Escape,
        State::EscapeIntermediate,
        State::CsiEntry,
        State::CsiParam,
        State::CsiIntermediate,
        State::CsiIgnore,
        State::OscString,
        State::DcsEntry,
        State::DcsParam,
        State::DcsIntermediate,
        State::DcsPassthrough,
        State::DcsIgnore,
        State::IgnoreString,
    ];
}

pub(crate) const MAX_PARAMS: usize = 32;
pub(crate) const MAX_STRING: usize = 64 * 1024;

/// Where the parser is inside a sequence, so a terminal snapshot taken mid-sequence picks
/// it up where it was.
#[derive(Clone, PartialEq, Eq, Default)]
pub(crate) struct Position {
    pub state: u8,
    pub params: Vec<u16>,
    pub current_param: i64,
    pub has_param: bool,
    pub colon_mask: u64,
    pub collected: u32,
    pub string: Vec<u8>,
    pub utf8_scalar: u32,
    pub utf8_remaining: i64,
    pub utf8_minimum: u32,
}

/// A DEC/ANSI escape sequence parser (Paul Williams' VT500 state machine) with UTF-8 decoding
/// in the ground state. Bytes may arrive split anywhere; all state carries across calls.
#[derive(Default)]
pub(crate) struct VtParser {
    state: State,
    params: [u16; MAX_PARAMS],
    param_count: usize,
    current_param: usize,
    has_param: bool,
    colon_mask: u64,
    /// Private markers and intermediates, one byte each, oldest in the high bits.
    collected: u32,
    string_buffer: Vec<u8>,
    utf8_scalar: u32,
    utf8_remaining: usize,
    utf8_minimum: u32,
}

impl VtParser {
    pub fn position(&self) -> Position {
        Position {
            state: self.state as u8,
            params: self.params[..self.param_count].to_vec(),
            current_param: self.current_param as i64,
            has_param: self.has_param,
            colon_mask: self.colon_mask,
            collected: self.collected,
            string: self.string_buffer.clone(),
            utf8_scalar: self.utf8_scalar,
            utf8_remaining: self.utf8_remaining as i64,
            utf8_minimum: self.utf8_minimum,
        }
    }

    /// Puts the parser at `position`; false (and nothing changed) when it isn't one it could be at.
    pub fn move_to(&mut self, position: Position) -> bool {
        let Some(&state) = State::ALL.get(position.state as usize) else { return false };
        if position.params.len() > MAX_PARAMS || position.string.len() > MAX_STRING || !(0..=3).contains(&position.utf8_remaining) {
            return false;
        }
        self.state = state;
        self.params[..position.params.len()].copy_from_slice(&position.params);
        self.param_count = position.params.len();
        self.current_param = position.current_param.clamp(0, 0xFFFF) as usize;
        self.has_param = position.has_param;
        self.colon_mask = position.colon_mask;
        self.collected = position.collected;
        self.string_buffer = position.string;
        self.utf8_scalar = position.utf8_scalar;
        self.utf8_remaining = position.utf8_remaining as usize;
        self.utf8_minimum = position.utf8_minimum;
        true
    }

    pub fn advance<H: VtHandler>(&mut self, input: &[u8], handler: &mut H) {
        let mut p = 0;
        while p < input.len() {
            let byte = input[p];
            if self.state == State::Ground {
                if self.utf8_remaining > 0 {
                    if byte & 0xC0 == 0x80 {
                        self.utf8_scalar = self.utf8_scalar << 6 | (byte & 0x3F) as u32;
                        self.utf8_remaining -= 1;
                        if self.utf8_remaining == 0 {
                            let scalar = self.utf8_scalar;
                            let valid = scalar >= self.utf8_minimum && scalar <= 0x10FFFF && !(0xD800..=0xDFFF).contains(&scalar);
                            handler.print(if valid { scalar } else { 0xFFFD });
                        }
                        p += 1;
                        continue;
                    }
                    self.utf8_remaining = 0;
                    handler.print(0xFFFD); // truncated sequence; reprocess this byte
                }
                if (0x20..0x7F).contains(&byte) {
                    let mut q = p + 1;
                    while q < input.len() && (0x20..0x7F).contains(&input[q]) {
                        q += 1;
                    }
                    handler.print_ascii(&input[p..q]);
                    p = q;
                    continue;
                }
                if byte < 0x20 {
                    if byte == 0x1B {
                        self.enter_escape();
                    } else {
                        handler.execute(byte);
                    }
                } else if byte >= 0x80 {
                    match byte {
                        0xC2..=0xDF => (self.utf8_scalar, self.utf8_remaining, self.utf8_minimum) = ((byte & 0x1F) as u32, 1, 0x80),
                        0xE0..=0xEF => (self.utf8_scalar, self.utf8_remaining, self.utf8_minimum) = ((byte & 0x0F) as u32, 2, 0x800),
                        0xF0..=0xF4 => (self.utf8_scalar, self.utf8_remaining, self.utf8_minimum) = ((byte & 0x07) as u32, 3, 0x10000),
                        _ => handler.print(0xFFFD),
                    }
                }
                p += 1;
                continue;
            }
            self.step(byte, handler);
            p += 1;
        }
    }

    /// Everything outside the ground state's fast paths.
    fn step<H: VtHandler>(&mut self, byte: u8, handler: &mut H) {
        // Transitions from anywhere.
        match byte {
            0x18 | 0x1A => {
                self.finish_string(handler, false);
                self.state = State::Ground;
                return;
            }
            0x1B => {
                self.finish_string(handler, false);
                self.enter_escape();
                return;
            }
            _ => {}
        }

        match self.state {
            State::Ground => {}

            State::Escape => match byte {
                0x00..=0x1F => handler.execute(byte),
                0x20..=0x2F => {
                    self.collect(byte);
                    self.state = State::EscapeIntermediate;
                }
                0x5B => {
                    self.enter_params();
                    self.state = State::CsiEntry;
                }
                0x5D => {
                    self.string_buffer.clear();
                    self.state = State::OscString;
                }
                0x50 => {
                    self.enter_params();
                    self.state = State::DcsEntry;
                }
                0x58 | 0x5E | 0x5F => self.state = State::IgnoreString,
                0x7F => {}
                _ => {
                    self.state = State::Ground;
                    handler.esc_dispatch(self.collected, byte);
                }
            },

            State::EscapeIntermediate => match byte {
                0x00..=0x1F => handler.execute(byte),
                0x20..=0x2F => self.collect(byte),
                0x7F => {}
                _ => {
                    self.state = State::Ground;
                    handler.esc_dispatch(self.collected, byte);
                }
            },

            State::CsiEntry | State::CsiParam => match byte {
                0x00..=0x1F => handler.execute(byte),
                0x30..=0x39 => {
                    self.digit(byte);
                    self.state = State::CsiParam;
                }
                0x3A | 0x3B => {
                    self.separator(byte);
                    self.state = State::CsiParam;
                }
                0x3C..=0x3F => {
                    if self.state == State::CsiEntry {
                        self.collect(byte);
                        self.state = State::CsiParam;
                    } else {
                        self.state = State::CsiIgnore;
                    }
                }
                0x20..=0x2F => {
                    self.collect(byte);
                    self.state = State::CsiIntermediate;
                }
                0x40..=0x7E => {
                    self.state = State::Ground;
                    self.dispatch_csi(byte, handler);
                }
                _ => {}
            },

            State::CsiIntermediate => match byte {
                0x00..=0x1F => handler.execute(byte),
                0x20..=0x2F => self.collect(byte),
                0x30..=0x3F => self.state = State::CsiIgnore,
                0x40..=0x7E => {
                    self.state = State::Ground;
                    self.dispatch_csi(byte, handler);
                }
                _ => {}
            },

            State::CsiIgnore => match byte {
                0x00..=0x1F => handler.execute(byte),
                0x40..=0x7E => self.state = State::Ground,
                _ => {}
            },

            State::OscString => {
                if byte == 0x07 {
                    self.finish_string(handler, true);
                    self.state = State::Ground;
                } else if byte >= 0x20 && self.string_buffer.len() < MAX_STRING {
                    self.string_buffer.push(byte);
                }
            }

            State::DcsEntry | State::DcsParam => match byte {
                0x30..=0x39 => {
                    self.digit(byte);
                    self.state = State::DcsParam;
                }
                0x3A | 0x3B => {
                    self.separator(byte);
                    self.state = State::DcsParam;
                }
                0x3C..=0x3F => {
                    if self.state == State::DcsEntry {
                        self.collect(byte);
                        self.state = State::DcsParam;
                    } else {
                        self.state = State::DcsIgnore;
                    }
                }
                0x20..=0x2F => {
                    self.collect(byte);
                    self.state = State::DcsIntermediate;
                }
                0x40..=0x7E => self.enter_passthrough(byte),
                _ => {}
            },

            State::DcsIntermediate => match byte {
                0x20..=0x2F => self.collect(byte),
                0x30..=0x3F => self.state = State::DcsIgnore,
                0x40..=0x7E => self.enter_passthrough(byte),
                _ => {}
            },

            State::DcsPassthrough => {
                if byte != 0x7F && self.string_buffer.len() < MAX_STRING {
                    self.string_buffer.push(byte);
                }
            }

            State::DcsIgnore | State::IgnoreString => {}
        }
    }

    fn enter_escape(&mut self) {
        self.state = State::Escape;
        self.collected = 0;
        self.utf8_remaining = 0;
    }

    fn enter_params(&mut self) {
        self.param_count = 0;
        self.current_param = 0;
        self.has_param = false;
        self.colon_mask = 0;
        self.collected = 0;
    }

    fn enter_passthrough(&mut self, final_byte: u8) {
        self.string_buffer.clear();
        self.collect(final_byte);
        self.state = State::DcsPassthrough;
    }

    fn collect(&mut self, byte: u8) {
        self.collected = self.collected << 8 | byte as u32;
    }

    fn digit(&mut self, byte: u8) {
        self.current_param = (self.current_param * 10 + (byte - 0x30) as usize).min(0xFFFF);
        self.has_param = true;
    }

    fn separator(&mut self, byte: u8) {
        self.push_param();
        if byte == 0x3A && self.param_count < 64 {
            self.colon_mask |= 1 << self.param_count;
        }
        self.has_param = true; // "CSI ;5H" has an empty first parameter
    }

    fn push_param(&mut self) {
        if self.param_count < MAX_PARAMS {
            self.params[self.param_count] = self.current_param as u16;
            self.param_count += 1;
        }
        self.current_param = 0;
    }

    fn dispatch_csi<H: VtHandler>(&mut self, final_byte: u8, handler: &mut H) {
        if self.has_param {
            self.push_param();
        }
        handler.csi_dispatch(CsiParams { values: &self.params[..self.param_count], colon_mask: self.colon_mask }, self.collected, final_byte);
    }

    /// Ends an OSC or DCS string when its terminator (BEL, ST, CAN, SUB) arrives.
    fn finish_string<H: VtHandler>(&mut self, handler: &mut H, bell: bool) {
        match self.state {
            State::OscString => handler.osc_dispatch(&self.string_buffer, bell),
            State::DcsPassthrough => {
                if self.has_param {
                    self.push_param();
                }
                let params = CsiParams { values: &self.params[..self.param_count], colon_mask: self.colon_mask };
                handler.dcs_dispatch(params, self.collected >> 8, self.collected as u8, &self.string_buffer);
            }
            _ => {}
        }
    }
}
