/// The set operations Swift's `OptionSet` gives a flags type.
macro_rules! option_set {
    ($name:ident, $raw:ty) => {
        impl $name {
            pub const fn raw_value(self) -> $raw {
                self.0
            }
            pub const fn contains(self, other: Self) -> bool {
                self.0 & other.0 == other.0
            }
            pub const fn union(self, other: Self) -> Self {
                Self(self.0 | other.0)
            }
            pub const fn subtracting(self, other: Self) -> Self {
                Self(self.0 & !other.0)
            }
            pub const fn is_empty(self) -> bool {
                self.0 == 0
            }
            pub fn insert(&mut self, other: Self) {
                self.0 |= other.0;
            }
            pub fn remove(&mut self, other: Self) {
                self.0 &= !other.0;
            }
        }
    };
}
pub(crate) use option_set;

/// A terminal color as the program asked for it: the default, a palette index, or 24-bit RGB.
/// Resolving it to an actual color is the renderer's job (it owns the theme).
///
/// Bits 0–23: palette index or 0xRRGGBB. Bits 24–25: 0 default, 1 palette, 2 RGB.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct TerminalColor(u32);

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum ColorKind {
    Default,
    Palette(u8),
    Rgb(u8, u8, u8),
}

impl TerminalColor {
    pub(crate) const MASK: u32 = 0x03FF_FFFF;
    pub const DEFAULT: TerminalColor = TerminalColor(0);

    pub const fn from_raw(raw_value: u32) -> Self {
        Self(raw_value & Self::MASK)
    }
    pub const fn palette(index: u8) -> Self {
        Self(1 << 24 | index as u32)
    }
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self(2 << 24 | (r as u32) << 16 | (g as u32) << 8 | b as u32)
    }
    pub const fn raw_value(self) -> u32 {
        self.0
    }
    pub fn kind(self) -> ColorKind {
        match self.0 >> 24 {
            1 => ColorKind::Palette(self.0 as u8),
            2 => ColorKind::Rgb((self.0 >> 16) as u8, (self.0 >> 8) as u8, self.0 as u8),
            _ => ColorKind::Default,
        }
    }
    pub const fn is_default(self) -> bool {
        self.0 == 0
    }
}

/// SGR attributes of a cell.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct CellAttributes(pub u16);
option_set!(CellAttributes, u16);

impl CellAttributes {
    pub const EMPTY: Self = Self(0);
    pub const BOLD: Self = Self(1 << 0);
    pub const DIM: Self = Self(1 << 1);
    pub const ITALIC: Self = Self(1 << 2);
    pub const UNDERLINE: Self = Self(1 << 3);
    pub const BLINK: Self = Self(1 << 4);
    pub const INVERSE: Self = Self(1 << 5);
    pub const INVISIBLE: Self = Self(1 << 6);
    pub const STRIKETHROUGH: Self = Self(1 << 7);
    pub const DOUBLE_UNDERLINE: Self = Self(1 << 8);
    pub const CURLY_UNDERLINE: Self = Self(1 << 9);
    pub const OVERLINE: Self = Self(1 << 10);
    /// Any underline style.
    pub const UNDERLINES: Self = Self(1 << 3 | 1 << 8 | 1 << 9);
}

/// How a cell takes part in a character's columns.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CellWidth {
    /// One column (or an empty cell).
    Narrow = 0,
    /// Left half of a two-column character; the glyph is anchored here.
    Wide = 1,
    /// Right half of a two-column character; carries no content of its own.
    Tail = 2,
}

/// One screen cell, packed into 12 bytes. Colors are stored as requested (not resolved), so
/// a theme change never has to touch the grid.
///
/// - `content`: bits 0–20 scalar or cluster id, bit 21 cluster flag, bits 22–23 width,
///   bits 24–31 the low eight attributes.
/// - `fg`: bits 0–25 color, bits 26–28 the remaining attributes.
/// - `bg`: bits 0–25 color.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Cell {
    pub content: u32,
    pub fg: u32,
    pub bg: u32,
}

impl Cell {
    pub(crate) const SCALAR_MASK: u32 = 0x1F_FFFF;
    pub(crate) const CLUSTER_FLAG: u32 = 1 << 21;
    pub(crate) const WIDTH_SHIFT: u32 = 22;
    pub(crate) const WIDTH_MASK: u32 = 3 << 22;

    pub const fn new(content: u32, fg: u32, bg: u32) -> Self {
        Self { content, fg, bg }
    }

    /// An erased cell: no content, default foreground, the given background (xterm's BCE).
    pub const fn blank(background: u32) -> Self {
        Self { content: 0, fg: 0, bg: background & TerminalColor::MASK }
    }

    /// The Unicode scalar, or 0 for an empty cell. For clusters, the cluster id (see `is_cluster`).
    pub const fn scalar(self) -> u32 {
        self.content & Self::SCALAR_MASK
    }
    /// True when `scalar` is an id in the terminal's cluster table (combining marks, ZWJ emoji).
    pub const fn is_cluster(self) -> bool {
        self.content & Self::CLUSTER_FLAG != 0
    }
    pub const fn is_empty(self) -> bool {
        self.content & (Self::SCALAR_MASK | Self::CLUSTER_FLAG) == 0
    }
    pub const fn width(self) -> CellWidth {
        match (self.content & Self::WIDTH_MASK) >> Self::WIDTH_SHIFT {
            1 => CellWidth::Wide,
            2 => CellWidth::Tail,
            _ => CellWidth::Narrow,
        }
    }
    pub const fn attributes(self) -> CellAttributes {
        CellAttributes((self.content >> 24) as u16 | ((self.fg >> 26 & 0x7) as u16) << 8)
    }
    pub const fn foreground(self) -> TerminalColor {
        TerminalColor::from_raw(self.fg)
    }
    pub const fn background(self) -> TerminalColor {
        TerminalColor::from_raw(self.bg)
    }
    /// All bits zero: a default blank, which rows trim from their end when packed.
    pub(crate) const fn is_default_blank(self) -> bool {
        self.content | self.fg | self.bg == 0
    }
}

/// The current SGR state, pre-packed so writing a cell is three stores.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub(crate) struct Pen {
    /// Attribute bits already shifted into `Cell::content` position.
    pub content_bits: u32,
    pub fg: u32,
    pub bg: u32,
}

impl Pen {
    pub fn attributes(self) -> CellAttributes {
        CellAttributes((self.content_bits >> 24) as u16 | ((self.fg >> 26 & 0x7) as u16) << 8)
    }
    pub fn set_attributes(&mut self, value: CellAttributes) {
        self.content_bits = ((value.0 & 0xFF) as u32) << 24;
        self.fg = self.fg & TerminalColor::MASK | ((value.0 >> 8 & 0x7) as u32) << 26;
    }
    pub fn foreground(self) -> TerminalColor {
        TerminalColor::from_raw(self.fg)
    }
    pub fn set_foreground(&mut self, value: TerminalColor) {
        self.fg = self.fg & !TerminalColor::MASK | value.raw_value();
    }
    pub fn background(self) -> TerminalColor {
        TerminalColor::from_raw(self.bg)
    }
    pub fn set_background(&mut self, value: TerminalColor) {
        self.bg = value.raw_value();
    }
}
