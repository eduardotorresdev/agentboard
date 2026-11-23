@testable import AgentBoard
import AgentRuntime
import AppKit
import Testing

@MainActor
struct ComposerZoomTests {
    /// A click on the composer's field is routed to it at any zoom, and the field is drawn at the
    /// board's zoom: a click where the user sees it lands in it.
    @Test func theComposerTakesClicksAtAnyZoom() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
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
        let record = store.add(try #require(AgentCatalog.all.first), to: "/w", at: CGPoint(x: 200, y: 100))
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
        let field = try #require(found)
        // The composer's own view on the board, placed in board points from the card's world rect.
        var container: NSView = field
        while let parent = container.superview, parent !== board { container = parent }

        var width: CGFloat = 0
        // A command-scroll zooms the board; 0 leaves it at 1.
        for wheel: Int32 in [0, -40, 60] {
            if wheel != 0 {
                let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0))
                scroll.flags = .maskCommand
                let center = window.convertPoint(toScreen: board.convert(CGPoint(x: container.frame.midX, y: container.frame.midY), to: nil))
                scroll.location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.height ?? 0) - center.y)
                board.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
            }
            // The zoom springs: wait until the composer has settled.
            var last = CGRect.null
            for _ in 0..<100 {
                board.syncLayers()
                try await Task.sleep(for: .milliseconds(100))
                if container.frame == last { break }
                last = container.frame
            }
            let zoom = container.frame.width / CardMetrics.composer(of: record).width
            // 40 world points into the field, halfway down: where the user sees it, whatever the zoom.
            let point = board.convert(CGPoint(x: container.frame.minX + 40 * zoom, y: container.frame.midY), to: nil)
            // The window's own routing, as a click takes it (a test window never becomes key, so a
            // sent click would only reach views that take the first mouse).
            let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
            #expect(hit.map { $0 === field || $0.isDescendant(of: field) } == true, "zoom \(zoom): \(String(describing: hit))")
            #expect(wheel == 0 || abs(zoom - 1) > 0.05, "the board didn't zoom")
            // Drawn at the zoom: as wide on screen as at zoom 1, times the zoom.
            let drawn = field.convert(field.bounds, to: nil)
            if wheel == 0 { width = drawn.width }
            #expect(abs(drawn.width - width * zoom) < 2, "zoom \(zoom): drawn \(drawn.width), \(width) at zoom 1")
        }
    }
}
