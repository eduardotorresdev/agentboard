import SwiftUI

enum CanvasMode: String, CaseIterable, Identifiable {
    case canvas
    case offCanvas

    var id: Self { self }

    var title: String {
        switch self {
        case .canvas: "Canvas"
        case .offCanvas: "Off Canvas"
        }
    }

    /// How visible the grid is: canvas mode draws strong lines, off canvas keeps them faint.
    var gridStrength: Double {
        switch self {
        case .canvas: 1
        case .offCanvas: 0.3
        }
    }
}

/// The main content area. It is always a canvas; the mode only changes how loud the grid is.
struct CanvasView<Content: View>: View {
    let mode: CanvasMode
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Theme.canvas
            CanvasGrid(strength: mode.gridStrength)
            content
        }
        .clipped()
    }
}

/// Minor lines every `spacing` points, with a heavier major line every `majorEvery` cells.
/// Animatable so mode changes fade the grid instead of snapping it.
private struct CanvasGrid: View, Animatable {
    var strength: Double

    private let spacing: CGFloat = 24
    private let majorEvery = 5

    var animatableData: Double {
        get { strength }
        set { strength = newValue }
    }

    var body: some View {
        Canvas { context, size in
            var minor = Path()
            var major = Path()
            let columns = Int(size.width / spacing)
            let rows = Int(size.height / spacing)
            for i in 0...columns {
                let x = CGFloat(i) * spacing + 0.5
                let line = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }
                if i % majorEvery == 0 { major.addPath(line) } else { minor.addPath(line) }
            }
            for i in 0...rows {
                let y = CGFloat(i) * spacing + 0.5
                let line = Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }
                if i % majorEvery == 0 { major.addPath(line) } else { minor.addPath(line) }
            }
            context.stroke(minor, with: .color(.primary.opacity(0.07 * strength)), lineWidth: 1)
            context.stroke(major, with: .color(.primary.opacity(0.14 * strength)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

