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
            // The state dots, at full color all the way through running's breath.
            for (name, fg) in [("running accent", H.accent), ("waiting deep", H.deep), ("crashed danger", H.danger),
                               ("icon inkMuted", H.inkMuted)] as [(String, UInt32)] {
                XCTAssertGreaterThanOrEqual(Theme.contrast(fg, header), 3, "\(name) over \(String(sky, radix: 16))")
            }
        }
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

    @MainActor
    func testHeaderBackdropCropsTheSkyLayerNotTheWindow() throws {
        // A window taller than the sky (a top bar above it): the crop is relative to the sky.
        let window = CALayer()
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 852)
        let sky = CALayer()
        sky.frame = CGRect(x: 0, y: 52, width: 1000, height: 800)
        sky.isGeometryFlipped = true
        window.addSublayer(sky)
        let header = CardTitleBar()
        sky.addSublayer(header)
        SkyBlur.shared.sky = sky
        let surface = try XCTUnwrap(IOSurface(properties: [.width: 4, .height: 4, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]))
        SkyBlur.shared.setCurrentForTesting(surface)
        header.update(size: CGSize(width: 200, height: 100), icon: .claude, status: nil, title: "A", detail: nil,
                      focused: false, reserve: 0, scale: 1)
        header.position = CGPoint(x: 100 + 100, y: 0 + CardMetrics.titleHeight / 2)
        header.refreshBackdrop()
        let crop = try XCTUnwrap(header.sublayers?.compactMap { $0.contents == nil ? nil : $0.contentsRect }.first)
        XCTAssertEqual(crop.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(crop.minY, 0, accuracy: 0.001)
        XCTAssertEqual(crop.width, 0.2, accuracy: 0.001)
        XCTAssertEqual(crop.height, CardMetrics.titleHeight / 800, accuracy: 0.001)
        XCTAssertTrue(SkyBlur.shared.isNeeded)
        header.removeFromSuperlayer()
        XCTAssertFalse(SkyBlur.shared.isNeeded)
    }
}
