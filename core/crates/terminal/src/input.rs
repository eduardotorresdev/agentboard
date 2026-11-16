//! Encoding user input (keys, paste, focus, mouse) the way the running program asked for it.

use crate::cell::option_set;
use crate::swift_string::{removing_paste_end, replacing_line_breaks};
use crate::terminal::{MouseEncoding, MouseTracking, Terminal, TerminalModes};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TerminalKey {
    Enter,
    Tab,
    Backspace,
    Escape,
    Delete,
    Insert,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Function(u8),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct KeyModifiers(pub u8);
option_set!(KeyModifiers, u8);

impl KeyModifiers {
    pub const NONE: Self = Self(0);
    pub const SHIFT: Self = Self(1 << 0);
    pub const OPTION: Self = Self(1 << 1);
    pub const CONTROL: Self = Self(1 << 2);

    /// xterm's modifier parameter: 1 + shift + 2·alt + 4·control.
    fn xterm_parameter(self) -> u8 {
        1 + self.contains(Self::SHIFT) as u8 + 2 * self.contains(Self::OPTION) as u8 + 4 * self.contains(Self::CONTROL) as u8
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MouseEventKind {
    Press,
    Release,
    Drag,
    Motion,
    ScrollUp,
    ScrollDown,
    ScrollLeft,
    ScrollRight,
}

#[derive(Clone, Copy, Debug)]
pub struct MouseEvent {
    pub kind: MouseEventKind,
    /// 0 left, 1 middle, 2 right.
    pub button: u8,
    /// Zero-based cell coordinates.
    pub column: usize,
    pub row: usize,
    pub modifiers: KeyModifiers,
}

impl Terminal {
    pub fn encode(&self, key: TerminalKey, modifiers: KeyModifiers) -> Vec<u8> {
        use TerminalKey::*;
        let (shift, option, control) =
            (modifiers.contains(KeyModifiers::SHIFT), modifiers.contains(KeyModifiers::OPTION), modifiers.contains(KeyModifiers::CONTROL));
        let navigation = !matches!(key, Enter | Tab | Backspace | Escape);
        let modified = option || control || (shift && navigation);
        let parameter = modifiers.xterm_parameter();
        let tilde = |code: u8| if modified { format!("\x1b[{code};{parameter}~") } else { format!("\x1b[{code}~") };
        let text = match key {
            Enter => if shift || option { "\x1b\r" } else { "\r" }.to_string(),
            Tab => if shift { "\x1b[Z" } else { "\t" }.to_string(),
            Backspace => if option { "\x1b\x7f" } else if control { "\x08" } else { "\x7f" }.to_string(),
            Escape => "\x1b".to_string(),
            Delete => tilde(3),
            Insert => tilde(2),
            PageUp => tilde(5),
            PageDown => tilde(6),
            Up | Down | Left | Right | Home | End => {
                let final_byte = match key {
                    Up => 'A',
                    Down => 'B',
                    Right => 'C',
                    Left => 'D',
                    Home => 'H',
                    _ => 'F',
                };
                // Option+←/→ move by word, as in Terminal.app.
                if modifiers == KeyModifiers::OPTION && key == Left {
                    "\x1bb".to_string()
                } else if modifiers == KeyModifiers::OPTION && key == Right {
                    "\x1bf".to_string()
                } else if modified {
                    format!("\x1b[1;{parameter}{final_byte}")
                } else if self.modes.contains(TerminalModes::APPLICATION_CURSOR) {
                    format!("\x1bO{final_byte}")
                } else {
                    format!("\x1b[{final_byte}")
                }
            }
            Function(number @ 1..=4) => {
                let final_byte = ['P', 'Q', 'R', 'S'][number as usize - 1];
                if modified { format!("\x1b[1;{parameter}{final_byte}") } else { format!("\x1bO{final_byte}") }
            }
            Function(number @ 5..=12) => tilde([15, 17, 18, 19, 20, 21, 23, 24][number as usize - 5]),
            Function(_) => String::new(),
        };
        text.into_bytes()
    }

    /// Pasted text, bracketed when the program asked for it. Line breaks become CR, and an
    /// embedded end-of-paste marker is removed so pasted text can't escape the bracket.
    pub fn encode_paste(&self, text: &str) -> Vec<u8> {
        let body = replacing_line_breaks(text);
        if !self.modes.contains(TerminalModes::BRACKETED_PASTE) {
            return body.into_bytes();
        }
        format!("\x1b[200~{}\x1b[201~", removing_paste_end(&body)).into_bytes()
    }

    /// Focus in/out report, when the program enabled focus events.
    pub fn encode_focus(&self, focused: bool) -> Option<Vec<u8>> {
        self.modes.contains(TerminalModes::FOCUS_EVENTS).then(|| if focused { b"\x1b[I".to_vec() } else { b"\x1b[O".to_vec() })
    }

    /// True when the program wants mouse input instead of the host handling it.
    pub fn wants_mouse(&self) -> bool {
        self.mouse_tracking != MouseTracking::None
    }

    /// The report for `event`, or `None` when the current tracking mode doesn't include it.
    pub fn encode_mouse(&self, event: MouseEvent) -> Option<Vec<u8>> {
        use MouseEventKind::*;
        let sgr = matches!(self.mouse_encoding, MouseEncoding::Sgr | MouseEncoding::SgrPixels);
        let button = event.button as usize;
        let mut code = match (event.kind, self.mouse_tracking) {
            (_, MouseTracking::None) => return None,
            (Press, _) => button,
            (Release, MouseTracking::X10) => return None,
            (Release, _) => if sgr { button } else { 3 },
            (Drag, MouseTracking::ButtonEvent | MouseTracking::AnyEvent) => button + 32,
            (Motion, MouseTracking::AnyEvent) => 3 + 32,
            (ScrollUp, _) => 64,
            (ScrollDown, _) => 65,
            (ScrollLeft, _) => 66,
            (ScrollRight, _) => 67,
            _ => return None,
        };
        if self.mouse_tracking == MouseTracking::X10 && event.kind != Press {
            return None;
        }
        code += 4 * event.modifiers.contains(KeyModifiers::SHIFT) as usize
            + 8 * event.modifiers.contains(KeyModifiers::OPTION) as usize
            + 16 * event.modifiers.contains(KeyModifiers::CONTROL) as usize;
        let (x, y) = (event.column + 1, event.row + 1);
        match self.mouse_encoding {
            MouseEncoding::Sgr | MouseEncoding::SgrPixels => {
                Some(format!("\x1b[<{code};{x};{y}{}", if event.kind == Release { 'm' } else { 'M' }).into_bytes())
            }
            MouseEncoding::Urxvt => Some(format!("\x1b[{};{x};{y}M", code + 32).into_bytes()),
            MouseEncoding::Utf8 => {
                let mut text = String::from("\x1b[M");
                for value in [code + 32, x + 32, y + 32] {
                    text.push(char::from_u32(value.min(2047) as u32).unwrap_or(' '));
                }
                Some(text.into_bytes())
            }
            MouseEncoding::X10 => {
                if x + 32 >= 256 || y + 32 >= 256 {
                    return None;
                }
                Some(vec![0x1B, 0x5B, 0x4D, u8::try_from(code + 32).ok()?, (x + 32) as u8, (y + 32) as u8])
            }
        }
    }
}
