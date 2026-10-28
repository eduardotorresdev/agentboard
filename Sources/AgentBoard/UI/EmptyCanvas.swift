import SwiftUI

/// Centered message for a canvas with nothing on it yet.
struct EmptyCanvas<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.bottom, 6)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            actions
                .padding(.top, 20)
        }
        .padding(32)
        // A feathered backing fades the grid out around the text instead of cutting a hard box.
        .background {
            Ellipse()
                .fill(Theme.canvas)
                .padding(-24)
                .blur(radius: 28)
        }
    }
}
