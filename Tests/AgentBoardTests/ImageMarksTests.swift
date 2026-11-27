@testable import AgentBoard
import AppKit
import Testing

@MainActor
struct ImageMarksTests {
    /// A click on Mark reaches the button at any zoom, instead of falling through to the card's move and resize.
    @Test func theMarkButtonTakesClicksAtAnyZoom() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AgentStore(database: folder.appendingPathComponent("cards.sqlite"), connect: { .failure(.noCore) })
        let board = BoardView(store: store, browsers: BrowserStore(database: nil), simulators: SimulatorStore(database: nil),
                              fileTrees: FileTreeStore(database: nil))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = board
        board.worktree = "/w"
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 900, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        _ = try await store.addImage(.data(picture.representation(using: .png, properties: [:])!), named: "p", to: "/w", at: CGPoint(x: 200, y: 100))
        window.orderFrontRegardless()
        board.syncLayers()
        let host = try #require(board.subviews.compactMap { $0 as? ImageMarksHost }.first)

        // A command-scroll zooms the board; 0 leaves it at 1.
        for wheel: Int32 in [0, -40, 60] {
            if wheel != 0 {
                let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0))
                scroll.flags = .maskCommand
                // Zoom around the picture, not wherever the real pointer is, or it can zoom the Mark button out of the window.
                let center = window.convertPoint(toScreen: host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil))
                scroll.location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.height ?? 0) - center.y)
                board.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
            }
            // The zoom springs: wait until it has settled, not a fixed time, so a loaded machine doesn't click mid-animation.
            var last = CGFloat.nan
            for _ in 0..<100 {
                board.syncLayers()
                try await Task.sleep(for: .milliseconds(100))
                if host.zoom == last { break }
                last = host.zoom
            }
            host.state.marking = false
            // The Mark button leads the footer.
            let footer = host.layout.footer(open: false)
            let point = host.convert(CGPoint(x: (footer.minX + 40) * host.zoom, y: footer.midY * host.zoom), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                try await Task.sleep(for: .milliseconds(150))
            }
            #expect(host.state.marking, "zoom \(host.zoom)")
        }
    }

    /// Connected beats last sent to beats first on the board; among several connected, the last sent to.
    @Test func recommendsAnAgent() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(ImageMarks.recommended(connected: [b, c], last: c, all: [a, b, c]) == c)
        #expect(ImageMarks.recommended(connected: [b, c], last: a, all: [a, b, c]) == b)
        #expect(ImageMarks.recommended(connected: [], last: c, all: [a, b, c]) == c)
        #expect(ImageMarks.recommended(connected: [], last: UUID(), all: [a, b]) == a)
        #expect(ImageMarks.recommended(connected: [], last: nil, all: []) == nil)
    }

    @Test func writesTheMessage() {
        let id = UUID(uuidString: "8F2C41D0-0000-4000-8000-000000000000")!
        var first = ImageMark(area: CGRect(x: 48.4, y: 486, width: 408, height: 132))
        first.text = "The button should say “Pay”.\nNot “Submit”."
        var second = ImageMark(area: CGRect(x: 0, y: 0, width: 10, height: 20))
        second.text = "Too small."
        let text = ImageMarks.message(for: [first, second], on: BoardMention(name: "checkout.png", type: "image", id: id),
                                      pixelSize: CGSize(width: 1440, height: 900), marked: "A7.png")
        #expect(text == """
        Annotations from the user on the image @[checkout.png](image:\(id.uuidString)): 2 marks on a 1440×900 pixel picture.
        Each area is x, y, width, height in the picture's pixels, from the top left corner.

        1. Area 48, 486, 409, 132
           The button should say “Pay”.
           Not “Submit”.

        2. Area 0, 0, 10, 20
           Too small.

        See the picture with the numbered marks drawn on it: image_read with image "\(id.uuidString)" and marks "A7.png".
        See it without marks: image_read with image "\(id.uuidString)".
        """)
    }

    /// Areas go to picture pixels and back whatever the card's size; clicks outside the chrome pass through.
    @Test func laysOutAndCatchesClicks() {
        let layout = ImageMarksLayout(card: CGSize(width: 720, height: 450 + 32), pixelSize: CGSize(width: 1440, height: 900))
        let mark = ImageMark(area: layout.area(of: CGRect(x: 100, y: 50, width: 200, height: 80)))
        #expect(mark.area == CGRect(x: 200, y: 100, width: 400, height: 160))
        #expect(layout.rect(of: mark) == CGRect(x: 100, y: 50, width: 200, height: 80))
        #expect(layout.area(of: CGRect(x: 700, y: 440, width: 100, height: 100)) == CGRect(x: 1400, y: 880, width: 40, height: 20))

        let state = ImageMarks(file: "a.png")
        #expect(layout.catches(CGPoint(x: 20, y: 460), state))  // the Mark button, in the footer
        #expect(!layout.catches(CGPoint(x: 20, y: 430), state))  // the picture
        #expect(!layout.catches(CGPoint(x: 300, y: 500), state))  // the footer is short until there is something to send
        state.marks = [mark]
        state.select(mark.id)
        #expect(layout.catches(CGPoint(x: 150, y: 60), state) && layout.catches(CGPoint(x: 320, y: 60), state))  // the mark, its balloon
        state.select(nil)
        #expect(state.marks.isEmpty)  // left without a remark
        state.marks = [mark]
        state.marks[0].text = "kept"
        state.select(nil)
        #expect(state.footerOpen && layout.catches(CGPoint(x: 300, y: 500), state) && !layout.catches(CGPoint(x: 320, y: 60), state))
        state.marking = true
        #expect(layout.catches(CGPoint(x: 600, y: 300), state))
        #expect(state.escape() && !state.marking && !state.escape())
    }

    /// The pen's path covers a box (with its nib) that is the area the agent gets; marks from before the pen go back and forth inside theirs.
    @Test func turnsTheMarkerPathIntoAnArea() throws {
        let layout = ImageMarksLayout(card: CGSize(width: 720, height: 450 + 32), pixelSize: CGSize(width: 1440, height: 900))
        #expect(layout.nib == 18)
        #expect(layout.area(ofStroke: [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 60), CGPoint(x: 200, y: 40)]) == CGRect(x: 182, y: 62, width: 436, height: 76))
        #expect(layout.area(ofStroke: [CGPoint(x: 2, y: 2), CGPoint(x: 50, y: 2)]).origin == .zero)  // kept inside the picture

        let old = ImageMark(area: CGRect(x: 0, y: 0, width: 200, height: 100))
        let path = old.path(nib: 20)
        #expect(path.count > 4 && path.allSatisfy { CGRect(x: 10, y: 10, width: 180, height: 80).insetBy(dx: -0.01, dy: -0.01).contains($0) })
        let saved = try JSONDecoder().decode(ImageMark.self, from: Data(#"{"id":"\#(old.id)","area":[[0,0],[200,100]],"text":"x"}"#.utf8))
        #expect(saved.stroke == nil && saved.text == "x")
    }

    @Test func drawsTheMarksOnThePicture() throws {
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        // Decoded at half the picture's size: the area lands at half its place.
        let blank = try #require(context.makeImage())
        let data = try #require(ImageMarks.render(blank, marks: [ImageMark(area: CGRect(x: 0, y: 0, width: 200, height: 100))],
                                                  pixelSize: CGSize(width: 400, height: 200)))
        let drawn = try #require(NSBitmapImageRep(data: data))
        #expect(drawn.pixelsWide == 200 && drawn.pixelsHigh == 100)
        let inside = try #require(drawn.colorAt(x: 50, y: 25)), outside = try #require(drawn.colorAt(x: 150, y: 75))
        #expect(inside.blueComponent > inside.redComponent + 0.1)
        #expect(outside.redComponent > 0.99 && outside.blueComponent > 0.99)
    }

    /// Unsent annotations outlive the app; sending them, replacing the picture or removing the image drops them.
    @Test func keepsUnsentAnnotations() throws {
        let suite = "ImageMarksTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = UUID()
        let state = ImageMarks(file: "a.png", image: image, defaults: defaults)
        state.marks = [ImageMark(area: CGRect(x: 1, y: 2, width: 30, height: 40), text: "kept"), ImageMark(area: CGRect(x: 5, y: 5, width: 9, height: 9))]

        let reopened = ImageMarks(file: "a.png", image: image, defaults: defaults)
        #expect(reopened.marks.map(\.area) == [CGRect(x: 1, y: 2, width: 30, height: 40)] && reopened.marks.first?.text == "kept")
        #expect(ImageMarks(file: "b.png", image: image, defaults: defaults).marks.isEmpty)  // the picture was replaced

        reopened.marks = []  // sent
        #expect(ImageMarks(file: "a.png", image: image, defaults: defaults).marks.isEmpty)

        state.marks = [ImageMark(area: .zero, text: "again")]
        ImageMarks.forget(image, in: defaults)
        #expect(ImageMarks(file: "a.png", image: image, defaults: defaults).marks.isEmpty)
    }

    /// The balloon goes to the mark's left when the window ends first; a click finds the mark on top.
    @Test func flipsTheBalloonAndFindsTheMark() {
        let layout = ImageMarksLayout(card: CGSize(width: 720, height: 450 + 32), pixelSize: CGSize(width: 720, height: 450))
        let mark = ImageMark(area: CGRect(x: 400, y: 50, width: 200, height: 80))
        #expect(layout.balloon(of: mark).minX == 610)
        #expect(layout.balloon(of: mark, room: 800).maxX == 390)
        #expect(layout.balloon(of: ImageMark(area: CGRect(x: 100, y: 50, width: 200, height: 80)), room: 400).minX == 0)

        let over = ImageMark(area: CGRect(x: 450, y: 60, width: 50, height: 50))
        #expect(layout.mark(at: CGPoint(x: 460, y: 70), in: [mark, over])?.id == over.id)
        #expect(layout.mark(at: CGPoint(x: 410, y: 70), in: [mark, over])?.id == mark.id)
        #expect(layout.mark(at: CGPoint(x: 10, y: 10), in: [mark, over]) == nil)
    }
}
