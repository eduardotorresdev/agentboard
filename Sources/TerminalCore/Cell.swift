/// A terminal color as the program asked for it: the default, a palette index, or 24-bit RGB.
/// Resolving it to an actual color is the renderer's job (it owns the theme).
public struct TerminalColor: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case `default`
        case palette(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    /// Bits 0–23: palette index or 0xRRGGBB. Bits 24–25: 0 default, 1 palette, 2 RGB.
    public let rawValue: UInt32

    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue & Self.mask }

    public static let `default` = TerminalColor(rawValue: 0)
    @inlinable public static func palette(_ index: UInt8) -> TerminalColor { TerminalColor(rawValue: 1 << 24 | UInt32(index)) }
    @inlinable public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> TerminalColor {
        TerminalColor(rawValue: 2 << 24 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    public var kind: Kind {
        switch rawValue >> 24 {
        case 1: .palette(UInt8(rawValue & 0xFF))
        case 2: .rgb(UInt8(rawValue >> 16 & 0xFF), UInt8(rawValue >> 8 & 0xFF), UInt8(rawValue & 0xFF))
        default: .default
        }
    }

    public var isDefault: Bool { rawValue == 0 }

    @usableFromInline static let mask: UInt32 = 0x03FF_FFFF
}

/// SGR attributes of a cell.
public struct CellAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    @inlinable public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = CellAttributes(rawValue: 1 << 0)
    public static let dim = CellAttributes(rawValue: 1 << 1)
    public static let italic = CellAttributes(rawValue: 1 << 2)
    public static let underline = CellAttributes(rawValue: 1 << 3)
    public static let blink = CellAttributes(rawValue: 1 << 4)
    public static let inverse = CellAttributes(rawValue: 1 << 5)
    public static let invisible = CellAttributes(rawValue: 1 << 6)
    public static let strikethrough = CellAttributes(rawValue: 1 << 7)
    public static let doubleUnderline = CellAttributes(rawValue: 1 << 8)
    public static let curlyUnderline = CellAttributes(rawValue: 1 << 9)
    public static let overline = CellAttributes(rawValue: 1 << 10)

    /// Any underline style.
    public static let underlines: CellAttributes = [.underline, .doubleUnderline, .curlyUnderline]
}

/// How a cell takes part in a character's columns.
public enum CellWidth: UInt8, Sendable {
    /// One column (or an empty cell).
    case narrow = 0
    /// Left half of a two-column character; the glyph is anchored here.
    case wide = 1
    /// Right half of a two-column character; carries no content of its own.
    case tail = 2
}

/// One screen cell, packed into 12 bytes. Colors are stored as requested (not resolved), so
/// a theme change never has to touch the grid.
///
/// - `content`: bits 0–20 scalar or cluster id, bit 21 cluster flag, bits 22–23 width,
///   bits 24–31 the low eight attributes.
/// - `fg`: bits 0–25 color, bits 26–28 the remaining attributes.
/// - `bg`: bits 0–25 color.
public struct Cell: Hashable, Sendable {
    public var content: UInt32
    public var fg: UInt32
    public var bg: UInt32

    @inlinable public init(content: UInt32, fg: UInt32, bg: UInt32) {
        self.content = content
        self.fg = fg
        self.bg = bg
    }

    /// An erased cell: no content, default foreground, the given background (xterm's BCE).
    @inlinable public static func blank(background: UInt32 = 0) -> Cell {
        Cell(content: 0, fg: 0, bg: background & TerminalColor.mask)
    }

    @usableFromInline static let scalarMask: UInt32 = 0x1F_FFFF
    @usableFromInline static let clusterFlag: UInt32 = 1 << 21
    @usableFromInline static let widthShift: UInt32 = 22
    @usableFromInline static let widthMask: UInt32 = 3 << 22

    /// The Unicode scalar, or 0 for an empty cell. For clusters, the cluster id (see `isCluster`).
    @inlinable public var scalar: UInt32 { content & Self.scalarMask }
    /// True when `scalar` is an id in the terminal's cluster table (combining marks, ZWJ emoji).
    @inlinable public var isCluster: Bool { content & Self.clusterFlag != 0 }
    @inlinable public var isEmpty: Bool { content & (Self.scalarMask | Self.clusterFlag) == 0 }

    @inlinable public var width: CellWidth { CellWidth(rawValue: UInt8((content & Self.widthMask) >> Self.widthShift)) ?? .narrow }

    @inlinable public var attributes: CellAttributes {
        CellAttributes(rawValue: UInt16(content >> 24) | UInt16(fg >> 26 & 0x7) << 8)
    }

    @inlinable public var foreground: TerminalColor { TerminalColor(rawValue: fg) }
    @inlinable public var background: TerminalColor { TerminalColor(rawValue: bg) }
}

/// The current SGR state, pre-packed so writing a cell is three stores.
@usableFromInline
struct Pen: Equatable {
    /// Attribute bits already shifted into `Cell.content` position.
    var contentBits: UInt32 = 0
    var fg: UInt32 = 0
    var bg: UInt32 = 0

    var attributes: CellAttributes {
        get { CellAttributes(rawValue: UInt16(contentBits >> 24) | UInt16(fg >> 26 & 0x7) << 8) }
        set {
            contentBits = UInt32(newValue.rawValue & 0xFF) << 24
            fg = fg & TerminalColor.mask | UInt32(newValue.rawValue >> 8 & 0x7) << 26
        }
    }

    var foreground: TerminalColor {
        get { TerminalColor(rawValue: fg) }
        set { fg = fg & ~TerminalColor.mask | newValue.rawValue }
    }

    var background: TerminalColor {
        get { TerminalColor(rawValue: bg) }
        set { bg = newValue.rawValue }
    }
}
