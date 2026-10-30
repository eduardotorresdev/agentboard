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
struct CanvasGrid: View, Animatable {
    var strength: Double

    static let spacing: CGFloat = 24
    private var spacing: CGFloat { Self.spacing }
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

/// Energy pulses running along the canvas grid's lines: every seven seconds one rises from the
/// bottom and drifts slowly up, a soft violet band fading out on both of its edges.
struct GridPulses: View {
    /// A new pulse starts this often, after the last one has crossed in `duration`.
    private static let period: Double = 7
    private static let duration: Double = 6
    /// How wide the lit band is.
    private static let band: CGFloat = 320
    private static let peak: Double = 0.8

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let spacing = CanvasGrid.spacing
                var lines = Path()
                for i in 0...Int(size.width / spacing) {
                    let x = CGFloat(i) * spacing + 0.5
                    lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                for i in 0...Int(size.height / spacing) {
                    let y = CGFloat(i) * spacing + 0.5
                    lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                let latest = Int(time / Self.period)
                for cycle in stride(from: latest, to: latest - Int(ceil(Self.duration / Self.period)), by: -1) {
                    let t = (time - Double(cycle) * Self.period) / Self.duration
                    guard t >= 0, t < 1 else { continue }
                    // Eases in and out, like a slow, critically damped spring.
                    let travel = CGFloat(t * t * (3 - 2 * t))
                    let horizontal = false
                    let length = horizontal ? size.width : size.height
                    let center = -Self.band / 2 + travel * (length + Self.band)
                    let middle = length - center
                    let lead = middle - Self.band / 2, trail = middle + Self.band / 2
                    let start = horizontal ? CGPoint(x: lead, y: 0) : CGPoint(x: 0, y: lead)
                    let end = horizontal ? CGPoint(x: trail, y: 0) : CGPoint(x: 0, y: trail)
                    // Fades in as it leaves the edge and out before it reaches the other.
                    let strength = Self.peak * sin(.pi * t)
                    // Clear at both ends: past them the gradient repeats its last color.
                    let gradient = Gradient(stops: [
                        .init(color: Theme.accent.opacity(0), location: 0),
                        .init(color: Theme.accent.opacity(strength * 0.5), location: 0.3),
                        .init(color: Theme.accent.opacity(strength), location: 0.5),
                        .init(color: Theme.accent.opacity(strength * 0.5), location: 0.7),
                        .init(color: Theme.accent.opacity(0), location: 1),
                    ])
                    context.stroke(lines, with: .linearGradient(gradient, startPoint: start, endPoint: end), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
