import SwiftUI

/// The Mac board's tokens (Sources/AgentBoard/UI/Theme.swift), without its AppKit parts.
/// Light mode only. Keep the hex values in step with the Mac's.
enum Theme {
    enum Hex {
        static let accent: UInt32 = 0x0D74CE
        static let accentSoft: UInt32 = 0xE6F4FE
        static let sky: UInt32 = 0xF4FAFF
        static let accentTint: UInt32 = 0xC2E5FF
        static let deep: UInt32 = 0x113264
        static let ink: UInt32 = 0x1C2024
        static let inkMuted: UInt32 = 0x60646C
        static let paper: UInt32 = 0xFFFFFF
        static let paperDeep: UInt32 = 0xF0F0F3
        static let canvas: UInt32 = 0xF9F9FB
        static let danger: UInt32 = 0xC0322B
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let accent = color(Hex.accent)
    static let accentSoft = color(Hex.accentSoft)
    static let accentTint = color(Hex.accentTint)
    static let sky = color(Hex.sky)
    static let deep = color(Hex.deep)
    static let onAccent = Color.white
    static let ink = color(Hex.ink)
    static let inkMuted = color(Hex.inkMuted)
    static let canvas = color(Hex.canvas)
    static let surface = color(Hex.paper)
    static let surfaceDeep = color(Hex.paperDeep)
    static let line = color(Hex.ink)
    static let danger = color(Hex.danger)

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let dialog: CGFloat = 10
    }

    /// The Mac's scale, a step up for a phone held at reading distance.
    enum Font {
        static let headline = SwiftUI.Font.system(size: 26, weight: .bold)
        static let title = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15)
        static let label = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 12)
        static let eyebrow = SwiftUI.Font.system(size: 11, weight: .bold)
        static let mono = SwiftUI.Font.system(size: 15, weight: .medium, design: .monospaced)
        static let headlineTracking: CGFloat = -0.4
    }
}

/// A solid, firmly rounded button: the house control.
struct SolidButton: ButtonStyle {
    var fill: Color = Theme.accent
    var text: Color = Theme.onAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.label)
            .foregroundStyle(text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(fill.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .animation(.snappy, value: configuration.isPressed)
    }
}
