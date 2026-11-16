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
}

/// The main content area when no board is open: the sky behind the content.
struct CanvasView<Content: View>: View {
    let mode: CanvasMode
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            SkyCanvas()
            content
        }
        .clipped()
    }
}
