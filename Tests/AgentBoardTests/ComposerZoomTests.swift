@testable import AgentBoard
import AgentRuntime
import AppKit
@testable import Orchestration
import Testing

/// The composer on a board, zoomed with the board like the rest of its card.
@MainActor
struct ComposerZoomTests {
    /// A board in a window with one agent card, and its composer once SwiftUI has made it.
    @MainActor struct Rig {
        let store: AgentStore
        let board: BoardView
        let window: NSWindow
        let record: AgentRecord
        let field: ComposerTextView
        /// The composer's own view on the board, placed in board points from the card's world rect.
        let container: NSView
        let folder: URL

        init(held: Int? = nil) async throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A core that never answers: the board stays connecting, and what it sends waits in its link.
            let store = AgentStore(database: folder.appendingPathComponent("cards.sqlite"),
                                   connect: { Thread.sleep(forTimeInterval: 120); return .failure(.noCore) })
            let board = BoardView(store: store, browsers: BrowserStore(database: nil), simulators: SimulatorStore(database: nil),
                                  fileTrees: FileTreeStore(database: nil))
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = board
            board.worktree = "/w"
            record = store.add(try #require(AgentCatalog.all.first), to: "/w", at: CGPoint(x: 200, y: 100))
            if let held { store.heldMessages[record.id] = held }
            window.orderFrontRegardless()
            board.syncLayers()
            func textView(in view: NSView) -> ComposerTextView? {
                view as? ComposerTextView ?? view.subviews.lazy.compactMap(textView).first
            }
            // SwiftUI makes the field on its first layout.
            var found: ComposerTextView?
            for _ in 0..<50 where found == nil {
                board.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                found = textView(in: board)
            }
            field = try #require(found)
            var container: NSView = field
            while let parent = container.superview, parent !== board { container = parent }
            (self.store, self.board, self.container) = (store, board, container)
        }

        func close() {
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }

        var zoom: CGFloat { container.frame.width / CardMetrics.composer(of: record).width }

        /// Zooms the board by a command-scroll around the composer, and waits for the spring to settle.
        func scroll(_ wheel: Int32) async throws {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0))
            event.flags = .maskCommand
            let center = window.convertPoint(toScreen: board.convert(CGPoint(x: container.frame.midX, y: container.frame.midY), to: nil))
            event.location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.height ?? 0) - center.y)
            board.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
            var last = CGRect.null
            for _ in 0..<100 {
                board.syncLayers()
                try await Task.sleep(for: .milliseconds(100))
                if container.frame == last { break }
                last = container.frame
            }
        }

        /// Where `world` (points in the composer at zoom 1) is on screen now, in window points.
        func onScreen(_ world: CGPoint) -> CGPoint {
            board.convert(CGPoint(x: container.frame.minX + world.x * zoom, y: container.frame.minY + world.y * zoom), to: nil)
        }

        func click(_ point: CGPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// A click on the composer's field is routed to it at any zoom, and the field is drawn at the
    /// board's zoom, as the rest of the composer: its text keeps the same width against the status
    /// line beside it (the field was once scaled twice, 0.36× at 0.6 and 2.3× at 1.5).
    @Test func theFieldTakesClicksAndIsDrawnAtAnyZoom() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.store.composerNotices[rig.record.id] = "A status line beside the field"
        var ratios: [CGFloat: CGFloat] = [:]
        for wheel: Int32 in [0, -51, 92] {
            if wheel != 0 { try await rig.scroll(wheel) }
            let zoom = rig.zoom
            #expect(wheel == 0 || abs(zoom - 1) > 0.3, "the board didn't zoom")
            // 40 world points into the field, halfway down. The window's own routing, as a click
            // takes it: the field is AppKit, and a test window never becomes key.
            let point = rig.onScreen(CGPoint(x: 40, y: CardMetrics.composer(of: rig.record).height / 2))
            let hit = rig.window.contentView?.superview?.hitTest(point)
            #expect(hit.map { $0 === rig.field || $0.isDescendant(of: rig.field) } == true, "zoom \(zoom): \(String(describing: hit))")
            let area = rig.container.frame.insetBy(dx: -24, dy: -24)
            let image = try #require(rig.board.bitmapImageRepForCachingDisplay(in: area))
            rig.board.cacheDisplay(in: area, to: image)
            // `COMPOSER_SHOTS=<folder>`: the composer as the board draws it at this zoom, for looking at.
            if let folder = ProcessInfo.processInfo.environment["COMPOSER_SHOTS"] {
                try? image.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "composer-%.2f.png", zoom)))
            }
            let runs = Self.inkRuns(image)
            #expect(runs.count >= 2, "zoom \(zoom): the field's text and the status apart, got \(runs)")
            if runs.count >= 2 { ratios[zoom] = CGFloat(runs[0]) / CGFloat(runs[1]) }
        }
        let base = try #require(ratios[1] ?? ratios.values.first)
        for (zoom, ratio) in ratios { #expect(abs(ratio / base - 1) < 0.08, "zoom \(zoom): field/status \(ratio), \(base) at zoom 1") }
    }

    /// Widths of the light (ink) stretches left to right, split where a gap is wider than 2% of the
    /// image: the field's text, then the status line (word gaps are narrower).
    static func inkRuns(_ image: NSBitmapImageRep) -> [Int] {
        let width = image.pixelsWide, height = image.pixelsHigh
        var runs: [Int] = [], start: Int?, last = 0
        for x in 0..<width {
            let ink = (0..<height).contains { y in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return false }
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3 > 0.55
            }
            if ink {
                if start == nil { start = x }
                last = x
            } else if let first = start, x - last > width / 50 {
                runs.append(last - first)
                start = nil
            }
        }
        if let first = start { runs.append(last - first) }
        return runs
    }

    /// The composer's SwiftUI buttons take a click where the user sees them at any zoom, never
    /// where they would sit at zoom 1, and the click doesn't fall through to the card. "Deliver
    /// now" stands for them: the points that send it at zoom 1 are clicked again, scaled, at
    /// about 0.6 and 1.5.
    @Test func theButtonsTakeClicksWhereTheyAreDrawnAtAnyZoom() async throws {
        let rig = try await Rig(held: 1)
        defer { rig.close() }
        let size = CardMetrics.composer(of: rig.record).size
        func delivered(at world: CGPoint) async throws -> Bool {
            let before = rig.store.link.pending.count
            try await rig.click(rig.onScreen(world))
            return rig.store.link.pending.dropFirst(before).contains { if case .deliverHeld(rig.record.id) = $0 { true } else { false } }
        }
        // The button's area at zoom 1, on a grid of world points; its inside, away from the edges.
        var area: [CGPoint] = []
        for y in stride(from: 2.0, to: size.height, by: 4) {
            for x in stride(from: 2.0, to: size.width, by: 8) where try await delivered(at: CGPoint(x: x, y: y)) {
                area.append(CGPoint(x: x, y: y))
            }
        }
        let inside = area.filter { point in [(-8.0, 0.0), (8, 0), (0, -4), (0, 4)].allSatisfy { dx, dy in area.contains(CGPoint(x: point.x + dx, y: point.y + dy)) } }
        try #require(!inside.isEmpty, "Deliver now took no click at zoom 1: \(area)")

        for wheel: Int32 in [-51, 92] {
            try await rig.scroll(wheel)
            let zoom = rig.zoom
            #expect(abs(zoom - (wheel < 0 ? 0.6 : 1.5)) < 0.06, "zoom \(zoom)")
            var missed: [CGPoint] = []
            for point in inside where try await !delivered(at: point) { missed.append(point) }
            #expect(missed.isEmpty, "zoom \(zoom): \(missed.count) of \(inside.count) clicks on Deliver now missed: \(missed)")
        }
    }
}
