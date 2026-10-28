import CoreGraphics
import CoreText
import Foundation
import Metal
import TerminalCore

/// Rasterized terminal glyphs, one cell-sized slot each (two for wide characters), in an
/// 8-bit coverage texture shared by every terminal drawn with the same font and scale.
///
/// Because every slot is exactly one cell, the cell shader finds a glyph from its slot index
/// alone, and box-drawing and block characters are drawn procedurally to the cell's edges so
/// borders and pixel art tile without gaps.
public final class GlyphCache {
    public enum Style: Int, CaseIterable {
        case regular, bold, italic, boldItalic

        init(_ attributes: CellAttributes) {
            switch (attributes.contains(.bold), attributes.contains(.italic)) {
            case (true, true): self = .boldItalic
            case (true, false): self = .bold
            case (false, true): self = .italic
            case (false, false): self = .regular
            }
        }
    }

    /// Cell size in pixels.
    public let cellWidth: Int
    public let cellHeight: Int
    @exclusivity(unchecked) public private(set) var texture: MTLTexture
    public let slotsPerRow: Int
    /// Bumped when the atlas is cleared; drawn cells referring to old slots must be rebuilt.
    @exclusivity(unchecked) public private(set) var generation = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fonts: [CTFont]
    private let fontSize: CGFloat
    @exclusivity(unchecked) private var nextSlot = 0
    /// Glyph indices (slot + 1) for printable ASCII by style, the hot path; 0 = not yet drawn.
    @exclusivity(unchecked) private var ascii = [UInt32](repeating: 0, count: 4 * 128)
    @exclusivity(unchecked) private var scalars: [UInt64: UInt32] = [:]
    @exclusivity(unchecked) private var clusters: [String: UInt32] = [:]
    private static let maxHeight = 8192
    /// coverage^0.85: light text on a light card reads too thin with linear coverage.
    private static let coverageCurve: [UInt8] = (0..<256).map { UInt8((pow(Double($0) / 255, 0.85) * 255).rounded()) }

    /// `font` is the regular face at its pixel size (point size × backing scale).
    public init?(device: MTLDevice, font: CTFont, lineHeight: CGFloat = 1.22) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        fontSize = CTFontGetSize(font)
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
        }
        fonts = [font, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]
        (cellWidth, cellHeight) = Self.cellSize(of: font, lineHeight: lineHeight)
        slotsPerRow = max(2, 2048 / cellWidth)
        guard let texture = Self.makeTexture(device: device, width: slotsPerRow * cellWidth, height: cellHeight * 8) else { return nil }
        self.texture = texture
    }

    /// Cell size in pixels a cache built with `font` would have, without building one.
    public static func cellSize(of font: CTFont, lineHeight: CGFloat = 1.22) -> (width: Int, height: Int) {
        var glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return (max(1, Int(advance.width.rounded())),
                max(1, Int(((CTFontGetAscent(font) + CTFontGetDescent(font)) * lineHeight).rounded(.up))))
    }

    /// Bytes of GPU memory held by the atlas.
    public var memoryUsage: Int { texture.width * texture.height }

    /// Glyph index (slot + 1) for a cell, or 0 when it draws nothing.
    @inline(__always)
    public func glyph(for cell: Cell, in terminal: Terminal) -> UInt32 {
        let style = Style(cell.attributes)
        let scalar = cell.scalar
        if !cell.isCluster {
            if scalar < 128 {
                if scalar <= 0x20 || scalar == 0x7F { return 0 }
                let index = style.rawValue * 128 + Int(scalar)
                if ascii[index] != 0 { return ascii[index] }
                let glyph = rasterize(String(UnicodeScalar(UInt8(scalar))), scalar: scalar, style: style, wide: false)
                ascii[index] = glyph
                return glyph
            }
            if scalar == 0xA0 { return 0 }
            let wide = cell.width == .wide
            let key = UInt64(scalar) | UInt64(style.rawValue) << 32 | (wide ? 1 << 40 : 0)
            if let glyph = scalars[key] { return glyph }
            let glyph = rasterize(Unicode.Scalar(scalar).map { String(Character($0)) } ?? "\u{FFFD}", scalar: scalar, style: style, wide: wide)
            scalars[key] = glyph
            return glyph
        }
        let text = terminal.clusterString(scalar)
        let key = "\(style.rawValue)\(cell.width == .wide ? "w" : "n")\(text)"
        if let glyph = clusters[key] { return glyph }
        let glyph = rasterize(text, scalar: nil, style: style, wide: cell.width == .wide)
        clusters[key] = glyph
        return glyph
    }

    // MARK: Slots

    private func allocate(wide: Bool) -> Int? {
        if wide, nextSlot % slotsPerRow == slotsPerRow - 1 { nextSlot += 1 }
        let needed = nextSlot + (wide ? 2 : 1)
        let rowsNeeded = (needed + slotsPerRow - 1) / slotsPerRow
        if rowsNeeded * cellHeight > texture.height, !grow(toRows: rowsNeeded) {
            clear()
            return allocate(wide: wide)
        }
        defer { nextSlot = needed }
        return nextSlot
    }

    /// Doubles the atlas height, copying what is already drawn.
    private func grow(toRows rows: Int) -> Bool {
        var height = texture.height
        while height < rows * cellHeight { height *= 2 }
        guard height <= Self.maxHeight, let larger = Self.makeTexture(device: device, width: texture.width, height: height),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return false }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: larger, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        texture = larger
        return true
    }

    /// Forgets every glyph; callers notice through `generation` and redraw.
    private func clear() {
        nextSlot = 0
        ascii = [UInt32](repeating: 0, count: ascii.count)
        scalars.removeAll()
        clusters.removeAll()
        generation += 1
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: Drawing

    private func rasterize(_ text: String, scalar: UInt32?, style: Style, wide: Bool) -> UInt32 {
        guard let slot = allocate(wide: wide) else { return 0 }
        let width = cellWidth * (wide ? 2 : 1), height = cellHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            if let scalar, drawProcedural(scalar, in: context, width: width, height: height) { return }
            context.setAllowsFontSmoothing(false)
            context.setShouldAntialias(true)
            let font = fonts[style.rawValue]
            let descent = CTFontGetDescent(font)
            let baseline = ((CGFloat(height) - CTFontGetAscent(font) - descent) / 2 + descent).rounded()
            context.textPosition = CGPoint(x: 0, y: baseline)
            let attributed = NSAttributedStringShim.make(text, font: font)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        // Thicken antialiased edges once here instead of in every fragment.
        for index in pixels.indices { pixels[index] = Self.coverageCurve[Int(pixels[index])] }
        let x = (slot % slotsPerRow) * cellWidth, y = (slot / slotsPerRow) * cellHeight
        // Bitmap memory is top row first, like the texture.
        texture.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width)
        return UInt32(slot + 1)
    }

    /// Box drawing (U+2500–257F) and block elements (U+2580–259F) drawn to the cell edges.
    private func drawProcedural(_ scalar: UInt32, in context: CGContext, width: Int, height: Int) -> Bool {
        let w = CGFloat(width), h = CGFloat(height)
        // Rects are given top-down (terminal convention) and flipped into Core Graphics space.
        func fill(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, alpha: CGFloat = 1) {
            context.setFillColor(gray: 1, alpha: alpha)
            context.fill(CGRect(x: x0, y: h - y1, width: x1 - x0, height: y1 - y0))
        }
        switch scalar {
        case 0x2580...0x259F:
            let e = 1.0 / 8
            switch scalar {
            case 0x2580: fill(0, 0, w, (h / 2).rounded())
            case 0x2581...0x2588: fill(0, (h * (1 - CGFloat(scalar - 0x2580) * e)).rounded(), w, h)
            case 0x2589...0x258F: fill(0, 0, (w * CGFloat(0x2590 - scalar) * e).rounded(), h)
            case 0x2590: fill((w / 2).rounded(), 0, w, h)
            case 0x2591...0x2593: fill(0, 0, w, h, alpha: CGFloat(scalar - 0x2590) * 0.25)
            case 0x2594: fill(0, 0, w, (h * e).rounded())
            case 0x2595: fill((w * (1 - e)).rounded(), 0, w, h)
            default:
                // Quadrants: 1 upper left, 2 upper right, 4 lower left, 8 lower right.
                let masks: [UInt32: Int] = [0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 13, 0x259A: 9,
                                            0x259B: 7, 0x259C: 11, 0x259D: 2, 0x259E: 6, 0x259F: 14]
                let mask = masks[scalar] ?? 0, mx = (w / 2).rounded(), my = (h / 2).rounded()
                if mask & 1 != 0 { fill(0, 0, mx, my) }
                if mask & 2 != 0 { fill(mx, 0, w, my) }
                if mask & 4 != 0 { fill(0, my, mx, h) }
                if mask & 8 != 0 { fill(mx, my, w, h) }
            }
            return true
        case 0x2500...0x257F:
            let light = max(1, (fontSize / 12).rounded()), heavy = light * 2
            let cx = (w / 2).rounded(.down), cy = (h / 2).rounded(.down)
            if (0x256D...0x2570).contains(scalar) {
                // Rounded corners: an arc joining the two arms, stroked like a light line.
                let r = min(cx, cy), y = h - cy
                let (start, end): (CGPoint, CGPoint) = switch scalar {
                case 0x256D: (CGPoint(x: w, y: y), CGPoint(x: cx, y: 0))
                case 0x256E: (CGPoint(x: 0, y: y), CGPoint(x: cx, y: 0))
                case 0x256F: (CGPoint(x: 0, y: y), CGPoint(x: cx, y: h))
                default: (CGPoint(x: w, y: y), CGPoint(x: cx, y: h))
                }
                context.setLineWidth(light)
                context.move(to: start)
                context.addArc(tangent1End: CGPoint(x: cx, y: y), tangent2End: end, radius: r)
                context.addLine(to: end)
                context.strokePath()
                return true
            }
            if scalar == 0x2550 || scalar == 0x2551 {
                let gap = light * 1.5
                if scalar == 0x2550 {
                    fill(0, cy - gap - light / 2, w, cy - gap + light / 2)
                    fill(0, cy + gap - light / 2, w, cy + gap + light / 2)
                } else {
                    fill(cx - gap - light / 2, 0, cx - gap + light / 2, h)
                    fill(cx + gap - light / 2, 0, cx + gap + light / 2, h)
                }
                return true
            }
            guard let arms = Self.boxArms[scalar] else { return false }
            func thickness(_ weight: UInt8) -> CGFloat { weight == 2 ? heavy : weight == 1 ? light : 0 }
            let up = thickness(arms.0), right = thickness(arms.1), down = thickness(arms.2), left = thickness(arms.3)
            let vertical = max(up, down), horizontal = max(left, right)
            if left > 0 { fill(0, cy - left / 2, cx + max(vertical, left) / 2, cy + left / 2) }
            if right > 0 { fill(cx - max(vertical, right) / 2, cy - right / 2, w, cy + right / 2) }
            if up > 0 { fill(cx - up / 2, 0, cx + up / 2, cy + max(horizontal, up) / 2) }
            if down > 0 { fill(cx - down / 2, cy - max(horizontal, down) / 2, cx + down / 2, h) }
            return true
        default:
            return false
        }
    }

    /// Arms (up, right, down, left) of the line-drawing characters: 0 none, 1 light, 2 heavy.
    /// Dashed and double-line joins are left to the font.
    private static let boxArms: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = {
        let codes = """
        0101 0202 1010 2020 ---- ---- ---- ---- ---- ---- ---- ---- 0110 0210 0120 0220 0011 0012 0021 0022 \
        1100 1200 2100 2200 1001 1002 2001 2002 1110 1210 2110 1120 2120 2210 1220 2220 1011 1012 2011 1021 \
        2021 2012 1022 2022 0111 0112 0211 0212 0121 0122 0221 0222 1101 1102 1201 1202 2101 2102 2201 2202 \
        1111 1112 1211 1212 2111 1121 2121 2112 2211 1122 1221 2212 1222 2122 2221 2222
        """.split(separator: " ")
        var table: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = [:]
        func add(_ scalar: UInt32, _ code: Substring) {
            let digits = code.compactMap { $0.wholeNumberValue }.map(UInt8.init)
            if digits.count == 4 { table[scalar] = (digits[0], digits[1], digits[2], digits[3]) }
        }
        for (offset, code) in codes.enumerated() { add(0x2500 + UInt32(offset), code) }
        for (offset, code) in "0001 1000 0100 0010 0002 2000 0200 0020 0201 1020 0102 2010".split(separator: " ").enumerated() {
            add(0x2574 + UInt32(offset), code)
        }
        return table
    }()
}

/// CoreText wants an attributed string; keep the Foundation dependency in one place.
private enum NSAttributedStringShim {
    static func make(_ text: String, font: CTFont) -> CFAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }
}
