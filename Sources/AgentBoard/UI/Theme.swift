import AppKit
import SwiftUI

/// AgentBoard's visual identity. The app is light mode only.
/// White, light grays, baby blue, a stronger blue and near-black, from Radix Colors (Slate and
/// Blue, light scales, radix-ui.com/colors), whose steps are contrast-tested. Red is reserved for
/// errors. No yellow, green or teal; the blue stays at hue ~205–210°.
enum Theme {
    // MARK: Hex values (shared with BoardPalette and the contrast test)

    enum Hex {
        /// Blue 11: the solid accent. White text on it passes AA.
        static let accent: UInt32 = 0x0D74CE
        /// Blue 3: selected rows, quiet accent fills.
        static let accentSoft: UInt32 = 0xE6F4FE
        /// Blue 2: near-white baby blue, the sky's tone.
        static let sky: UInt32 = 0xF4FAFF
        /// Blue 5: a light blue tint for selected thumbs; deep text on it.
        static let accentTint: UInt32 = 0xC2E5FF
        /// Blue 6: decorative light blue (the blob's little clouds).
        static let blueLight: UInt32 = 0xACD8FC
        /// Blue 12: deep blue for strong emphasis, "waiting for you", the mascot.
        static let deep: UInt32 = 0x113264
        /// Slate 12.
        static let ink: UInt32 = 0x1C2024
        /// Slate 11.
        static let inkMuted: UInt32 = 0x60646C
        static let paper: UInt32 = 0xFFFFFF
        /// Slate 3: control fills, wells.
        static let paperDeep: UInt32 = 0xF0F0F3
        /// Slate 2: behind content that isn't the sky.
        static let canvas: UInt32 = 0xF9F9FB
        static let danger: UInt32 = 0xC0322B
        static let white: UInt32 = 0xFFFFFF
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    // MARK: Colors

    /// Solid blue accent: primary actions, focus, selection, running. White text on it.
    static let accent = color(Hex.accent)
    /// Baby-blue wash for selected rows and quiet accent fills; ink text on it.
    static let accentSoft = color(Hex.accentSoft)
    /// Light blue tint (Blue 5) for selected thumbs and chips; `deep` text on it.
    static let accentTint = color(Hex.accentTint)
    /// Near-white baby blue.
    static let sky = color(Hex.sky)
    /// Deep blue: strong emphasis and "waiting for you".
    static let deep = color(Hex.deep)
    /// Text and icons on an accent or deep fill.
    static let onAccent = Color.white
    /// Primary text.
    static let ink = color(Hex.ink)
    /// Secondary text.
    static let inkMuted = color(Hex.inkMuted)
    /// Behind content that isn't the sky.
    static let canvas = color(Hex.canvas)
    /// UI surfaces (cards, panels, dialogs, top bar): white.
    static let surface = color(Hex.paper)
    /// A light gray fill: control backgrounds, accordion headers, wells.
    static let surfaceDeep = color(Hex.paperDeep)
    /// Hairlines, tinted by ink. Use with opacity, and only where a stroke is required.
    static let line = color(Hex.ink)
    /// Errors and destructive actions: the one off-palette tone.
    static let danger = color(Hex.danger)

    // MARK: Shape

    /// Moderate, firm corners: structured, never pills.
    enum Radius {
        /// A selection thumb inside a segmented track (the track adds 2).
        static let thumb: CGFloat = 5
        /// Buttons, fields, chips, rows.
        static let control: CGFloat = 6
        /// Cards, panels, popovers.
        static let card: CGFloat = 8
        /// Dialogs and sheets.
        static let dialog: CGFloat = 10
    }

    /// Board elements separate from the sky by fill and contrast, not shadow. Where an element
    /// truly needs separation, at most this one short, discreet shadow.
    enum Shadow {
        static let opacity: Float = 0.12
        static let radius: CGFloat = 2
        static let y: CGFloat = 1
    }

    // MARK: Type

    /// Editorial scale at normal desktop sizes: hierarchy from weight and spacing, not size.
    enum Font {
        /// Bold 22pt counts as WCAG large text, so white headlines pass AA (3:1) on the sky.
        static let headline = SwiftUI.Font.system(size: 22, weight: .bold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 13.5, weight: .semibold)
        static let bodySize: CGFloat = 13
        static let body = SwiftUI.Font.system(size: bodySize)
        /// Compact control labels: segments, chips, small buttons.
        static let labelSize: CGFloat = 12
        static let label = SwiftUI.Font.system(size: labelSize, weight: .semibold)
        static let captionSize: CGFloat = 11
        static let caption = SwiftUI.Font.system(size: captionSize)
        /// Small uppercase labels above a section.
        static let eyebrow = SwiftUI.Font.system(size: 10.5, weight: .bold)
        static let headlineTracking: CGFloat = -0.4
        static let titleTracking: CGFloat = -0.1
        static let eyebrowTracking: CGFloat = 0.8

        /// The app's own handwriting faces, registered on first use (see scripts/board-hand.py).
        private static let handFaces: Void = {
            for face in ["BoardHand-Regular", "BoardHand-Bold"] {
                if let url = Bundle.module.url(forResource: face, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            }
        }()

        /// Handwriting leaning to the right, only for what is written on a post-it.
        static func hand(size: CGFloat, bold: Bool = false) -> NSFont {
            _ = handFaces
            return NSFont(name: bold ? "BoardHand-Bold" : "BoardHand-Regular", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
    }

    // MARK: Paper texture

    /// A tile of faint paper grain, generated once. Static: a surface material, not an ambient effect.
    static let paperGrain: NSImage = {
        let side = 128
        var rng = SystemRandomNumberGenerator()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        let data = rep.bitmapData!
        for i in 0 ..< side * side {
            // Neutral ink speckle at very low alpha; premultiplied.
            let alpha = UInt8.random(in: 0 ... 8, using: &rng)
            data[i * 4] = UInt8(UInt32(0x1C) * UInt32(alpha) / 255)
            data[i * 4 + 1] = UInt8(UInt32(0x20) * UInt32(alpha) / 255)
            data[i * 4 + 2] = UInt8(UInt32(0x24) * UInt32(alpha) / 255)
            data[i * 4 + 3] = alpha
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()

    /// Paper fill with grain: use as a surface's background.
    static var paper: some View {
        ZStack {
            surface
            Image(nsImage: paperGrain).resizable(resizingMode: .tile)
        }
    }

    /// WCAG relative-luminance contrast ratio between two sRGB hex colors.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [hex >> 16 & 0xFF, hex >> 8 & 0xFF, hex & 0xFF].map { value -> Double in
                let c = Double(value) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

extension View {
    /// Fills behind the view with grained paper, clipped to a square-cornered shape.
    func paperSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        background(Theme.paper.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
}

