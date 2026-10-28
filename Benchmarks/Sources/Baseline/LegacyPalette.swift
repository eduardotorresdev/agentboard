import SwiftTerm

/// Terminal colors tuned for a white card on the light board.
public enum LegacyPalette {
    typealias RGBA = SIMD4<Float>

    static let foreground = rgb(0x26, 0x21, 0x3A)
    static let background = rgb(0xFF, 0xFF, 0xFF)

    private static let ansi16: [RGBA] = [
        rgb(0x26, 0x21, 0x3A), rgb(0xCE, 0x2C, 0x31), rgb(0x2F, 0x7D, 0x45), rgb(0xA3, 0x5F, 0x00),
        rgb(0x34, 0x63, 0xC9), rgb(0x8E, 0x4E, 0xC6), rgb(0x10, 0x7D, 0x98), rgb(0x8B, 0x87, 0x99),
        rgb(0x6F, 0x6A, 0x80), rgb(0xE5, 0x48, 0x4D), rgb(0x3E, 0x9B, 0x58), rgb(0xC2, 0x7C, 0x0E),
        rgb(0x5B, 0x8D, 0xEF), rgb(0xA6, 0x6B, 0xD9), rgb(0x2A, 0x9D, 0xB8), rgb(0xC7, 0xC3, 0xD1),
    ]

    private static let table: [RGBA] = {
        var colors = ansi16
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { colors.append(rgb(r, g, b)) } } }
        for i in 0..<24 {
            let level = UInt8(8 + i * 10)
            colors.append(rgb(level, level, level))
        }
        return colors
    }()

    static func color(_ color: Attribute.Color, isForeground: Bool) -> RGBA {
        switch color {
        case .ansi256(let code): table[Int(code)]
        case .trueColor(let r, let g, let b): rgb(r, g, b)
        case .defaultColor: isForeground ? foreground : background
        case .defaultInvertedColor: isForeground ? background : foreground
        }
    }

    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: Float = 1) -> RGBA {
        RGBA(Float(r) / 255, Float(g) / 255, Float(b) / 255, a)
    }
}
