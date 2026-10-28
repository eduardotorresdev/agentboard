import SwiftUI

/// AgentBoard's visual identity. The app is light mode only.
/// Violet is the accent (actions, selection, focus); warm orange is the secondary, a
/// complementary partner reserved for supporting highlights. No greens or teals.
enum Theme {
    /// Violet accent, #6E56CF.
    static let accent = Color(red: 0x6E / 255, green: 0x56 / 255, blue: 0xCF / 255)
    /// Orange secondary, #F76B15.
    static let secondary = Color(red: 0xF7 / 255, green: 0x6B / 255, blue: 0x15 / 255)
    /// Canvas paper: white with a faint violet cast.
    static let canvas = Color(red: 0xFB / 255, green: 0xFA / 255, blue: 0xFF / 255)
    /// Card surface on the canvas.
    static let surface = Color.white
    /// Hairlines and card borders, violet-tinted instead of neutral gray.
    static let line = Color(red: 0x2E / 255, green: 0x1F / 255, blue: 0x6B / 255)
}
