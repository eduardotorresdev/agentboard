import AppKit
import SwiftUI

/// AgentBoard's visual identity: Grafite. The app is dark mode only.
/// Near-black planes stacked by lightness (window < plane < canvas < surface < chip), light ink,
/// one strong blue for action and running, and amber only for "waiting for you". Red is
/// reserved for errors. No green or teal; the blue stays at hue ~220–228°.
enum Theme {
    // MARK: Hex values (shared with BoardPalette and the contrast test)

    enum Hex {
        /// The solid accent: fills with white text, running dots, selection rings.
        static let accent: UInt32 = 0x1F5BFF
        /// The accent as text or a small mark on the dark planes (the solid one is too dark there).
        static let accentText: UInt32 = 0x6B97FF
        /// Selected rows, quiet accent fills; ink text on it.
        static let accentSoft: UInt32 = 0x102A6B
        /// A stronger blue wash for selected thumbs; deep text on it.
        static let accentTint: UInt32 = 0x163A94
        /// The canvas behind the cards (the old sky's role).
        static let sky: UInt32 = 0x0F1013
        /// Decorative blue (blob details, chart lines).
        static let blueLight: UInt32 = 0x3B6FFF
        /// Pale blue for strong emphasis on dark: questions, decision headings. `onDeep` text on it.
        static let deep: UInt32 = 0xB5CCFF
        /// Primary text.
        static let ink: UInt32 = 0xF1F2F4
        /// Secondary text.
        static let inkMuted: UInt32 = 0xA3A6AE
        /// Tertiary marks: counts, hints, placeholders (large or non-text only).
        static let faint: UInt32 = 0x757880
        /// Cards, panels, dialogs, popovers.
        static let paper: UInt32 = 0x1B1C21
        /// Controls, card headers, wells: one step lighter than a surface.
        static let paperDeep: UInt32 = 0x25272D
        /// The window itself and the top bar.
        static let window: UInt32 = 0x0A0B0D
        /// The sidebar's plane, between the window and the canvas.
        static let plane: UInt32 = 0x131418
        /// Behind content that isn't a card.
        static let canvas: UInt32 = 0x0F1013
        /// The canvas's faint dot grid.
        static let dot: UInt32 = 0x24262C
        /// "Waiting for you": the queue, a card that needs an answer.
        static let you: UInt32 = 0xFFB86B
        static let onYou: UInt32 = 0x1A0F02
        static let danger: UInt32 = 0xFF6369
        static let white: UInt32 = 0xFFFFFF
        /// Caffeinate's on state, the coffee pack's maroon, with its cream text.
        static let caffeinate: UInt32 = 0x4E0C10
        static let onCaffeinate: UInt32 = 0xFFF4E0
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    // MARK: Colors

    /// Solid blue accent: primary actions, focus, selection, running. White text on it.
    static let accent = color(Hex.accent)
    /// The accent for text and small marks on dark planes.
    static let accentText = color(Hex.accentText)
    /// Dark blue wash for selected rows and quiet accent fills; ink text on it.
    static let accentSoft = color(Hex.accentSoft)
    /// A stronger blue wash for selected thumbs and chips; `deep` text on it.
    static let accentTint = color(Hex.accentTint)
    /// The canvas behind the cards.
    static let sky = color(Hex.sky)
    /// Pale blue: strong emphasis. As a fill, `onDeep` text on it.
    static let deep = color(Hex.deep)
    static let onDeep = color(Hex.window)
    /// Text and icons on an accent fill.
    static let onAccent = Color.white
    /// Primary text.
    static let ink = color(Hex.ink)
    /// Secondary text.
    static let inkMuted = color(Hex.inkMuted)
    /// Tertiary marks: counts, hints, placeholders.
    static let faint = color(Hex.faint)
    /// Behind content that isn't a card.
    static let canvas = color(Hex.canvas)
    /// The window and its top bar.
    static let window = color(Hex.window)
    /// The sidebar's plane.
    static let plane = color(Hex.plane)
    /// UI surfaces: cards, panels, dialogs, popovers.
    static let surface = color(Hex.paper)
    /// One step lighter: control backgrounds, card headers, accordion headers, wells.
    static let surfaceDeep = color(Hex.paperDeep)
    /// Hairlines, tinted by ink. Use with opacity, and only where a stroke is required.
    static let line = color(Hex.ink)
    /// "Waiting for you", with its text color.
    static let you = color(Hex.you)
    static let onYou = color(Hex.onYou)
    /// Errors and destructive actions. As a fill, `onDanger` text on it.
    static let danger = color(Hex.danger)
    static let onDanger = color(Hex.window)
    /// Caffeinate's on state.
    static let caffeinate = color(Hex.caffeinate)
    static let onCaffeinate = color(Hex.onCaffeinate)

    // MARK: Shape

    /// Soft continuous (squircle) corners: always `style: .continuous`, never pills.
    enum Radius {
        /// A selection thumb inside a segmented track (the track adds 2).
        static let thumb: CGFloat = 8
        /// Buttons, fields, chips, rows.
        static let control: CGFloat = 10
        /// Cards, panels, popovers.
        static let card: CGFloat = 14
        /// Dialogs and sheets.
        static let dialog: CGFloat = 18
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

