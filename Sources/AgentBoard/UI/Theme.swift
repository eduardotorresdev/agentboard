import AppKit
import SwiftUI

/// AgentBoard's visual identity. The app is light mode only.
/// Editorial and square: sky blue is the accent (actions, selection, focus); yellow/cream is the
/// secondary, for details and highlights, never behind long text. No greens or teals: the blue
/// stays at hue ~208°, never drifting toward cyan.
enum Theme {
    // MARK: Hex values (shared with BoardPalette and the contrast test)

    enum Hex {
        static let accent: UInt32 = 0x2272B8
        static let accentSoft: UInt32 = 0xDCEBF7
        static let secondary: UInt32 = 0xF5C443
        static let cream: UInt32 = 0xFBE7A1
        static let ink: UInt32 = 0x14233D
        static let inkMuted: UInt32 = 0x5A6478
        static let paper: UInt32 = 0xFBF8F1
        static let paperDeep: UInt32 = 0xF2EDE1
        static let danger: UInt32 = 0xC0322B
        static let white: UInt32 = 0xFFFFFF
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    // MARK: Colors

    /// Sky blue accent, #2272B8. White text on it passes AA.
    static let accent = color(Hex.accent)
    /// Pale sky wash for selected rows and quiet accent fills; ink text on it.
    static let accentSoft = color(Hex.accentSoft)
    /// Text and icons on an accent fill.
    static let onAccent = Color.white
    /// Yellow secondary, #F5C443: details, badges, highlights. Ink text on it.
    static let secondary = color(Hex.secondary)
    /// Cream highlight, the sky's clouds: marks and soft emphasis.
    static let cream = color(Hex.cream)
    /// Text and icons on a secondary or cream fill.
    static let onSecondary = color(Hex.ink)
    /// Primary text.
    static let ink = color(Hex.ink)
    /// Secondary text.
    static let inkMuted = color(Hex.inkMuted)
    /// Behind content that isn't the sky: the paper color.
    static let canvas = color(Hex.paper)
    /// UI surfaces (cards, sidebar, panels, dialogs): paper.
    static let surface = color(Hex.paper)
    /// A recessed paper fill: control backgrounds, accordion headers, wells.
    static let surfaceDeep = color(Hex.paperDeep)
    /// Hairlines, tinted by ink. Use with opacity, and only where a stroke is required.
    static let line = color(Hex.ink)
    /// Errors and destructive actions.
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

    // MARK: Type

    /// Editorial scale at normal desktop sizes: hierarchy from weight and spacing, not size.
    enum Font {
        static let headline = SwiftUI.Font.system(size: 21, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 13.5, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        /// Compact control labels: segments, chips, small buttons.
        static let label = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11)
        /// Small uppercase labels above a section.
        static let eyebrow = SwiftUI.Font.system(size: 10.5, weight: .bold)
        static let headlineTracking: CGFloat = -0.4
        static let titleTracking: CGFloat = -0.1
        static let eyebrowTracking: CGFloat = 0.8
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
            // Ink-colored speckle at very low alpha; premultiplied.
            let alpha = UInt8.random(in: 0 ... 14, using: &rng)
            data[i * 4] = UInt8(UInt32(0x14) * UInt32(alpha) / 255)
            data[i * 4 + 1] = UInt8(UInt32(0x23) * UInt32(alpha) / 255)
            data[i * 4 + 2] = UInt8(UInt32(0x3D) * UInt32(alpha) / 255)
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

/// A square, fill-delimited icon button for the window's top bar: neutral fill, ink icon.
struct TopBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(width: 30, height: 26)
            .background(Theme.surfaceDeep.opacity(configuration.isPressed ? 1 : 0.8),
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect(cornerRadius: Theme.Radius.control))
    }
}
