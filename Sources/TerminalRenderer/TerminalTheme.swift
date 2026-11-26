import TerminalCore

/// Resolves the colors a program asked for into the colors drawn. Colors are packed RGBA8
/// (red in the low byte), the layout the cell shader unpacks.
public struct TerminalTheme: Equatable, Sendable {
    public var foreground: UInt32
    /// The default background. Drawn transparent so the surface under the terminal shows.
    public var background: UInt32
    /// The 16 ANSI colors; the 256-color cube and grays are derived.
    public var ansi: [UInt32]
    /// Opacity of dim (SGR 2) text.
    public var dimAlpha: Float = 0.55

    private var table: [UInt32]

    public init(foreground: UInt32, background: UInt32, ansi: [UInt32]) {
        self.foreground = foreground
        self.background = background
        self.ansi = ansi
        var table = ansi
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { table.append(Self.rgb(r, g, b)) } } }
        for i in 0..<24 {
            let level = UInt32(8 + i * 10)
            table.append(Self.rgb(level, level, level))
        }
        self.table = table
    }

    /// Light theme for white cards: deep navy ink, ANSI colors tuned for contrast on white.
    public static let light = TerminalTheme(
        foreground: rgb(0x14, 0x23, 0x3D),
        background: rgb(0xFF, 0xFF, 0xFF),
        ansi: [
            rgb(0x14, 0x23, 0x3D), rgb(0xCE, 0x2C, 0x31), rgb(0x2F, 0x7D, 0x45), rgb(0xA3, 0x5F, 0x00),
            rgb(0x34, 0x63, 0xC9), rgb(0x8E, 0x4E, 0xC6), rgb(0x10, 0x7D, 0x98), rgb(0x8B, 0x87, 0x99),
            rgb(0x6F, 0x6A, 0x80), rgb(0xE5, 0x48, 0x4D), rgb(0x3E, 0x9B, 0x58), rgb(0xC2, 0x7C, 0x0E),
            rgb(0x5B, 0x8D, 0xEF), rgb(0xA6, 0x6B, 0xD9), rgb(0x2A, 0x9D, 0xB8), rgb(0xC7, 0xC3, 0xD1),
        ])

    /// Dark theme for the graphite cards: light ink on the card's surface (`Theme.Hex.paper`),
    /// ANSI colors lifted for contrast on dark.
    public static let dark = TerminalTheme(
        foreground: rgb(0xE3, 0xE5, 0xE9),
        background: rgb(0x1B, 0x1C, 0x21),
        ansi: [
            rgb(0x5C, 0x5F, 0x68), rgb(0xFF, 0x63, 0x69), rgb(0x4C, 0xC3, 0x8A), rgb(0xF5, 0xC4, 0x51),
            rgb(0x6B, 0x97, 0xFF), rgb(0xC5, 0x8A, 0xF9), rgb(0x4C, 0xC9, 0xDB), rgb(0xC9, 0xCC, 0xD3),
            rgb(0x75, 0x78, 0x80), rgb(0xFF, 0x8A, 0x8F), rgb(0x7E, 0xE0, 0xA6), rgb(0xFF, 0xD9, 0x78),
            rgb(0x9B, 0xB8, 0xFF), rgb(0xD9, 0xAD, 0xFF), rgb(0x7F, 0xDD, 0xEA), rgb(0xF1, 0xF2, 0xF4),
        ])

    /// Perceived brightness, 0...255 (Rec. 709 weights), of a packed color.
    @inline(__always)
    static func luminance(_ color: UInt32) -> UInt32 {
        ((color & 0xFF) * 54 + (color >> 8 & 0xFF) * 183 + (color >> 16 & 0xFF) * 19) >> 8
    }

    public static func rgb(_ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: UInt32 = 255) -> UInt32 {
        r | g << 8 | b << 16 | a << 24
    }

    /// 0xRRGGBB, the form terminals report to programs.
    public static func hex(_ color: UInt32) -> UInt32 {
        (color & 0xFF) << 16 | (color >> 8 & 0xFF) << 8 | (color >> 16 & 0xFF)
    }

    @inline(__always)
    private func resolve(_ color: TerminalColor, isForeground: Bool) -> UInt32 {
        let raw = color.rawValue
        switch raw >> 24 {
        case 1: return table[Int(raw & 0xFF)]
        case 2: return (raw >> 16 & 0xFF) | (raw & 0xFF00) | (raw & 0xFF) << 16 | 0xFF00_0000
        default: return isForeground ? foreground : background & 0x00FF_FFFF  // transparent default background
        }
    }

    /// Foreground and background as drawn, applying inverse, dim and invisible.
    @inline(__always)
    public func colors(of cell: Cell) -> (fg: UInt32, bg: UInt32) {
        let attributes = cell.attributes
        var fg = resolve(cell.foreground, isForeground: true)
        var bg = resolve(cell.background, isForeground: false)
        if attributes.contains(.inverse) {
            let opaqueBackground = bg >> 24 == 0 ? background | 0xFF00_0000 : bg
            bg = fg | 0xFF00_0000
            fg = opaqueBackground
        }
        // Text a program colored for the other kind of terminal (near white on a white default
        // background, near black on a dark one) would vanish: it takes the theme's ink instead,
        // like a terminal's minimum contrast.
        if bg >> 24 == 0 {
            let (text, ground) = (Self.luminance(fg), Self.luminance(background))
            if (text > 200 && ground > 200) || (text < 40 && ground < 40) { fg = foreground | fg & 0xFF00_0000 }
        }
        if attributes.contains(.dim) { fg = fg & 0x00FF_FFFF | UInt32(Float(fg >> 24) * dimAlpha) << 24 }
        if attributes.contains(.invisible) { fg &= 0x00FF_FFFF }
        return (fg, bg)
    }
}
