import AgentRuntime
import SwiftUI

extension EnvironmentValues {
    /// The board's zoom around views it scales (see `Zoomed`); 1 elsewhere.
    @Entry var boardZoom: CGFloat = 1
}

/// A decision's diagram, drawn from its vector for the pixels it covers at the board's zoom, so
/// it stays sharp however far the board is zoomed in (a stretched bitmap would blur).
struct DiagramView: View {
    let svg: String
    @Environment(\.boardZoom) private var zoom
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            // Steps of a quarter, so a pinch redraws a handful of times, not every frame.
            let scale = max(1, (max(zoom, 1) * displayScale * 4).rounded(.up) / 4)
            if let diagram = try? SVGDiagram(svg), let image = diagram.image(size: proxy.size, scale: scale) {
                Image(decorative: image, scale: scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                Text(L("This diagram can't be drawn."))
                    .font(Theme.Font.label.weight(.regular))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
