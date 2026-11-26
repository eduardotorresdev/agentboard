@testable import AgentBoard
import XCTest

final class ThemeContrastTests: XCTestCase {
    typealias H = Theme.Hex

    func testKeyPairsPassWCAGAA() {
        let pairs: [(String, UInt32, UInt32)] = [
            ("white on accent", H.white, H.accent),
            ("window on deep", H.window, H.deep),
            ("deep on accentTint", H.deep, H.accentTint),
            ("ink on accentSoft", H.ink, H.accentSoft),
            ("onYou on you", H.onYou, H.you),
            ("window on danger", H.window, H.danger),
            ("onCaffeinate on caffeinate", H.onCaffeinate, H.caffeinate),
        ]
        for (name, fg, bg) in pairs {
            XCTAssertGreaterThanOrEqual(Theme.contrast(fg, bg), 4.5, name)
        }
        // Every text tone on every plane it sits on.
        for plane in [H.window, H.plane, H.canvas, H.paper, H.paperDeep] {
            for (name, fg) in [("ink", H.ink), ("inkMuted", H.inkMuted), ("accentText", H.accentText), ("deep", H.deep),
                               ("you", H.you), ("danger", H.danger)] as [(String, UInt32)] {
                XCTAssertGreaterThanOrEqual(Theme.contrast(fg, plane), 4.5, "\(name) on \(String(plane, radix: 16))")
            }
            // Status dots and the running accent are graphics: 3:1. On controls the dots use accentText.
            if plane != H.paperDeep { XCTAssertGreaterThanOrEqual(Theme.contrast(H.accent, plane), 3, "accent mark on \(String(plane, radix: 16))") }
            XCTAssertGreaterThanOrEqual(Theme.contrast(H.faint, plane), 3, "faint mark on \(String(plane, radix: 16))")
        }
    }

    /// Sidebar rows on its solid plane, on a hovered or dragged row (a surface) and on the
    /// selected row (accentSoft): text passes AA, the status dots 3:1.
    func testSidebarRowsOnItsPlane() {
        for (name, fill) in [("plane", H.plane), ("surface", H.paper), ("selected", H.accentSoft)] as [(String, UInt32)] {
            XCTAssertGreaterThanOrEqual(Theme.contrast(H.ink, fill), 4.5, "ink on \(name)")
            XCTAssertGreaterThanOrEqual(Theme.contrast(H.inkMuted, fill), 4.5, "inkMuted on \(name)")
            for (dot, color) in [("running", H.accentText), ("waiting", H.you), ("crashed", H.danger), ("idle", H.faint)] as [(String, UInt32)] {
                XCTAssertGreaterThanOrEqual(Theme.contrast(color, fill), 3, "\(dot) dot on \(name)")
            }
        }
        // The footer's toggles: their fill is their state.
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.ink, H.paperDeep), 4.5, "toggle off")
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.white, H.accent), 4.5, "zen on")
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.onCaffeinate, H.caffeinate), 4.5, "caffeinate on")
        // The computers' count on its dark badge.
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.accentText, H.window), 4.5, "compute count")
    }

    func testContrastMatchesWCAGReference() {
        XCTAssertEqual(Theme.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    /// The accent must read as blue, not drift toward teal.
    func testAccentHueStaysBlue() {
        let c = NSColor(srgbRed: CGFloat(H.accent >> 16 & 0xFF) / 255, green: CGFloat(H.accent >> 8 & 0xFF) / 255,
                        blue: CGFloat(H.accent & 0xFF) / 255, alpha: 1)
        XCTAssert((218.0 ... 232.0).contains(c.hueComponent * 360))
    }

    /// Card headers are a solid step above the card body: their text passes AA, their icons
    /// 3:1, and each status pill's words pass AA on its own fill.
    func testCardHeaderPairsPassAA() throws {
        let header = CardFrame.header
        for (name, fg) in [("title ink", H.ink), ("detail inkMuted", H.inkMuted)] {
            XCTAssertGreaterThanOrEqual(Theme.contrast(fg, header), 4.5, name)
        }
        // Brand marks (Claude's orange) keep their color: logos are exempt from WCAG 1.4.11.
        XCTAssertGreaterThanOrEqual(Theme.contrast(H.inkMuted, header), 3, "icon inkMuted")
        for status in [CardStatus.running, .waiting, .crashed] {
            let pill = try XCTUnwrap(CardFrame.pill(status))
            XCTAssertGreaterThanOrEqual(Theme.contrast(pill.ink, pill.fill), 4.5, status.label)
            // The pill itself stands out from the header it sits on.
            XCTAssertNotEqual(pill.fill, header, status.label)
        }
        XCTAssertNil(CardFrame.pill(.stopped))
    }

    @MainActor
    func testCardStyleRingsOnlyHighlightedCardsAndCastsNoShadow() {
        let card = CALayer()
        CardFrame.style(card, focused: true)
        XCTAssertEqual(card.borderWidth, 2)
        XCTAssertEqual(card.shadowOpacity, 0)
        XCTAssertGreaterThan(card.borderColor?.alpha ?? 0, 0)
        CardFrame.style(card, focused: false)
        // The ring stays, clear, so highlighting only fades its color in.
        XCTAssertEqual(card.borderWidth, 2)
        XCTAssertEqual(card.borderColor?.alpha, 0)
    }

    func testControlTargetsKeepTheirScreenSizeWhenZoomedOut() {
        let close = CGRect(x: 100, y: 10, width: 20, height: 20)
        XCTAssertEqual(close.target(zoom: 1), close)
        let far = close.target(zoom: 0.25)
        XCTAssertEqual(far.width, 80)
        XCTAssertEqual(far.midX, close.midX)
        XCTAssertEqual(far.midY, close.midY)
    }
}
