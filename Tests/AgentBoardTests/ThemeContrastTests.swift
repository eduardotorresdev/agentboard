@testable import AgentBoard
import XCTest

final class ThemeContrastTests: XCTestCase {
    typealias H = Theme.Hex

    func testKeyPairsPassWCAGAA() {
        let pairs: [(String, UInt32, UInt32)] = [
            ("white on accent", H.white, H.accent),
            ("white on deep", H.white, H.deep),
            ("deep on accentTint", H.deep, H.accentTint),
            ("ink on accentSoft", H.ink, H.accentSoft),
            ("ink on sky", H.ink, H.sky),
            ("ink on surface", H.ink, H.paper),
            ("inkMuted on surface", H.inkMuted, H.paper),
            ("inkMuted on surfaceDeep", H.inkMuted, H.paperDeep),
            ("inkMuted on sky", H.inkMuted, H.sky),
            ("accent on surface", H.accent, H.paper),
            ("white on danger", H.white, H.danger),
            ("inkMuted on surfaceDeep (organization menu row hover)", H.inkMuted, H.paperDeep),
            ("white on deep (project tile)", H.white, H.deep),
            ("white on ink (project tile)", H.white, H.ink),
            ("white on inkMuted (project tile)", H.white, H.inkMuted),
        ]
        for (name, fg, bg) in pairs {
            XCTAssertGreaterThanOrEqual(Theme.contrast(fg, bg), 4.5, name)
        }
    }

    /// Sidebar text over its translucent backdrop, with the darkest sky behind it: the darkest
    /// pixel of the frosted sky over a sweep of its frames (the greener blue pooled along the bottom).
    func testSidebarTextOverTheBlurredSky() {
        let darkestSky: UInt32 = 0x94C4D7
        func over(_ top: UInt32, _ bottom: UInt32, _ alpha: Double) -> UInt32 {
            [16, 8, 0].reduce(0) { hex, shift in
                let a = Double(top >> UInt32(shift) & 0xFF), b = Double(bottom >> UInt32(shift) & 0xFF)
                return hex | UInt32((a * alpha + b * (1 - alpha)).rounded()) << UInt32(shift)
            }
        }
        for sky in [darkestSky, H.sky] {
            let sidebar = over(H.ink, over(H.paper, sky, SidebarBackdrop.tint), SidebarBackdrop.shade)
            // A dragged item and its placeholder: the same backdrop, more shaded, over the sidebar.
            let lifted = over(H.paper, sidebar, SidebarBackdrop.liftedTint)
            for backdrop in [sidebar, lifted] {
                XCTAssertGreaterThanOrEqual(Theme.contrast(H.inkMuted, backdrop), 4.5, "inkMuted on sidebar")
                XCTAssertGreaterThanOrEqual(Theme.contrast(H.ink, backdrop), 4.5, "ink on sidebar")
                // Status dots are graphics: 3:1.
                XCTAssertGreaterThanOrEqual(Theme.contrast(H.accent, backdrop), 3, "running dot")
                XCTAssertGreaterThanOrEqual(Theme.contrast(H.deep, backdrop), 3, "waiting dot")
                XCTAssertGreaterThanOrEqual(Theme.contrast(H.danger, backdrop), 3, "crashed dot")
            }
        }
    }

    func testContrastMatchesWCAGReference() {
        XCTAssertEqual(Theme.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    /// The mascot (a graphic) needs 3:1 against the lightest and the bluest sky tones.
    func testDeepBlueStandsOutOnTheSky() {
        for sky in [H.sky, H.accentSoft, H.white] {
            XCTAssertGreaterThanOrEqual(Theme.contrast(H.deep, sky), 3)
        }
    }

    /// The accent must read as blue, not drift toward teal.
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
