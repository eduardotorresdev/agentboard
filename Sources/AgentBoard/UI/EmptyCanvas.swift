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
                .foregroundStyle(Theme.inkMuted)
                .padding(.bottom, 16)
            Text(title)
                .font(Theme.Font.title)
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 6)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            actions
                .padding(.top, 20)
        }
        .padding(32)
        .background(Theme.paper.clipShape(.rect(cornerRadius: Theme.Radius.dialog))
            .shadow(color: Theme.ink.opacity(0.14), radius: 16, y: 4))
    }
}
