import AppKit
import SwiftUI

/// The board's backdrop: the flat graphite canvas with a faint dot grid. It stays fixed while
/// the board pans and zooms, like a sheet of dotted paper behind the cards.
struct SkyCanvas: View {
    var body: some View {
        Theme.canvas
            .overlay(Image(nsImage: Self.dots).resizable(resizingMode: .tile))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// One cell of the grid: a single dot, drawn at whatever resolution the screen asks for.
    static let spacing: CGFloat = 22
    static let dots = NSImage(size: NSSize(width: spacing, height: spacing), flipped: false) { _ in
        NSColor(cgColor: BoardPalette.rgb(Theme.Hex.dot))?.setFill()
        NSBezierPath(ovalIn: NSRect(x: spacing / 2 - 1, y: spacing / 2 - 1, width: 2, height: 2)).fill()
        return true
    }
}
