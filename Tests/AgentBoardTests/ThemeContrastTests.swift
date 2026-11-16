@testable import AgentBoard
import XCTest

final class ThemeContrastTests: XCTestCase {
    typealias H = Theme.Hex

    func testKeyPairsPassWCAGAA() {
        let pairs: [(String, UInt32, UInt32)] = [
            ("white on accent", H.white, H.accent),
            ("ink on accentSoft", H.ink, H.accentSoft),
            ("ink on secondary", H.ink, H.secondary),
            ("ink on cream", H.ink, H.cream),
            ("ink on paper", H.ink, H.paper),
            ("inkMuted on paper", H.inkMuted, H.paper),
            ("inkMuted on paperDeep", H.inkMuted, H.paperDeep),
            ("accent on paper", H.accent, H.paper),
            ("white on danger", H.white, H.danger),
            // The organization switcher in the white top bar: ink-tinted fills over white.
            ("inkMuted on switcher rail", H.inkMuted, 0xF6F6F7),
            ("ink on switcher thumb", H.ink, 0xDFE1E5),
        ]
        for (name, fg, bg) in pairs {
            XCTAssertGreaterThanOrEqual(Theme.contrast(fg, bg), 4.5, name)
        }
    }

    /// Sidebar text over its translucent backdrop, with the darkest sky behind it: the sky
    /// shader's deepest blue after its pale wash (#D3E0F0), taken a step darker for the grid.
    func testSidebarTextOverTheBlurredSky() {
        let darkestSky: UInt32 = 0xC8D6E8
        func over(_ top: UInt32, _ bottom: UInt32, _ alpha: Double) -> UInt32 {
            [16, 8, 0].reduce(0) { hex, shift in
                let a = Double(top >> UInt32(shift) & 0xFF), b = Double(bottom >> UInt32(shift) & 0xFF)
                return hex | UInt32((a * alpha + b * (1 - alpha)).rounded()) << UInt32(shift)
            }
        }
        let backdrop = over(H.paper, darkestSky, SidebarBackdrop.tint)
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.inkMuted, backdrop), 4.5, "inkMuted on sidebar")
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.ink, backdrop), 4.5, "ink on sidebar")
    }

    func testContrastMatchesWCAGReference() {
        XCTAssertEqual(Theme.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    /// The accent must read as sky blue, not drift toward teal.
    func testAccentHueStaysBlue() {
        let c = NSColor(srgbRed: CGFloat(H.accent >> 16 & 0xFF) / 255, green: CGFloat(H.accent >> 8 & 0xFF) / 255,
                        blue: CGFloat(H.accent & 0xFF) / 255, alpha: 1)
        XCTAssert((200.0 ... 220.0).contains(c.hueComponent * 360))
    }

    /// Card headers are translucent over the sky: their text passes AA, their icons 3:1, over
    /// the darkest sky blue and the lightest cloud.
    func testCardHeaderPairsPassAA() {
        // The sky's deepest blue (its base color) and a white cloud.
        for sky: UInt32 in [0x458CD1, 0xFFFFFF] {
            let header = CardFrame.header(over: sky)
            for (name, fg) in [("title ink", H.ink), ("detail inkMuted", H.inkMuted)] {
                XCTAssertGreaterThanOrEqual(Theme.contrast(fg, header), 4.5, "\(name) over \(String(sky, radix: 16))")
            }
            // Brand marks (Claude's orange) keep their color: logos are exempt from WCAG 1.4.11.
            for (name, fg) in [("running accent", H.accent), ("icon inkMuted", H.inkMuted)] as [(String, UInt32)] {
                XCTAssertGreaterThanOrEqual(Theme.contrast(fg, header), 3, "\(name) over \(String(sky, radix: 16))")
            }
        }
    }
}
