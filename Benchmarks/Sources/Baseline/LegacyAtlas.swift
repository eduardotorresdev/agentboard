import AppKit
import CoreText
import Metal

/// Rasterized text shared by every terminal on the board. Each entry is a run of text drawn
/// once with CoreText (which also handles font fallback) into an 8-bit coverage texture.
final class LegacyAtlas {
    enum Face: Hashable {
        case mono, monoBold, label, labelBold
    }

    struct Entry {
        /// Location in the atlas, in pixels.
        let uv: SIMD4<Float>
    }

    private struct Key: Hashable {
        let text: String
        let face: Face
        let width: Int
    }

    let texture: MTLTexture
    let size = 2048
    let scale: CGFloat
    /// Terminal cell size in device pixels.
    let cellWidth: Int
    let cellHeight: Int

    private let fonts: [Face: CTFont]
    private var entries: [Key: Entry] = [:]
    private var cursorX = 0, cursorY = 0, shelfHeight = 0
    /// Bumped when the atlas fills up and is cleared, so callers drop cached geometry.
    private(set) var generation = 0

    init?(device: MTLDevice, scale: CGFloat) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        self.scale = scale
        let pointSize: CGFloat = 12
        fonts = [
            .mono: NSFont.monospacedSystemFont(ofSize: pointSize * scale, weight: .regular),
            .monoBold: NSFont.monospacedSystemFont(ofSize: pointSize * scale, weight: .bold),
            .label: NSFont.systemFont(ofSize: 12 * scale, weight: .medium),
            .labelBold: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold),
        ]
        let mono = fonts[.mono]!
        var glyph = CTFontGetGlyphWithName(mono, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(mono, .horizontal, &glyph, &advance, 1)
        cellWidth = Int(advance.width.rounded())
        cellHeight = Int(((CTFontGetAscent(mono) + CTFontGetDescent(mono)) * 1.22).rounded(.up))
    }

    /// Size of a label in pixels.
    func measure(_ text: String, face: Face) -> CGSize {
        let line = makeLine(text, face: face)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGSize(width: ceil(width), height: CGFloat(labelHeight(face)))
    }

    /// Entry for a terminal cell (`cells` wide) or, with `cells == nil`, a label at its natural width.
    func entry(_ text: String, face: Face, cells: Int? = nil) -> Entry? {
        let width = cells.map { $0 * cellWidth } ?? Int(measure(text, face: face).width)
        let key = Key(text: text, face: face, width: width)
        if let entry = entries[key] { return entry }
        let height = cells == nil ? labelHeight(face) : cellHeight
        guard width > 0, let origin = allocate(width: width, height: height) else { return nil }
        rasterize(text, face: face, width: width, height: height, at: origin, isCell: cells != nil)
        let entry = Entry(uv: SIMD4(Float(origin.x), Float(origin.y), Float(width), Float(height)))
        entries[key] = entry
        return entry
    }

    private func labelHeight(_ face: Face) -> Int {
        let font = fonts[face]!
        return Int((CTFontGetAscent(font) + CTFontGetDescent(font)).rounded(.up)) + 2
    }

    private func makeLine(_ text: String, face: Face) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts[face]!, .foregroundColor: CGColor(gray: 1, alpha: 1)]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Shelf packing; clears everything when full, which is rare and cheap to rebuild.
    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width + 2 <= size else { return nil }
        if cursorX + width + 1 > size {
            cursorX = 0
            cursorY += shelfHeight + 1
            shelfHeight = 0
        }
        if cursorY + height > size {
            entries.removeAll()
            cursorX = 0; cursorY = 0; shelfHeight = 0
            generation += 1
        }
        defer {
            cursorX += width + 1
            shelfHeight = max(shelfHeight, height)
        }
        return (cursorX, cursorY)
    }

    private func rasterize(_ text: String, face: Face, width: Int, height: Int, at origin: (x: Int, y: Int), isCell: Bool) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setAllowsFontSmoothing(false)
            context.setShouldAntialias(true)
            let font = fonts[face]!
            let descent = CTFontGetDescent(font)
            let baseline = isCell
                ? ((CGFloat(cellHeight) - CTFontGetAscent(font) - descent) / 2 + descent).rounded()
                : descent.rounded(.up) + 1
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(makeLine(text, face: face), context)
        }
        // Bitmap memory is already top row first, matching the texture.
        texture.replace(region: MTLRegionMake2D(origin.x, origin.y, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width)
    }
}
