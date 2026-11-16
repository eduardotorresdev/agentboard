import SwiftUI

/// Standard dialog chrome for the app: title, optional subtitle, content, and a trailing footer.
/// Presented as a sheet attached to the main window.
struct AppDialog<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.Font.title)
                    .tracking(Theme.Font.titleTracking)
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.bottom, 24)

            content

            HStack(spacing: 8) {
                footer
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 28)
            .buttonStyle(DialogButtonStyle())
        }
        .font(Theme.Font.body)
        .padding(28)
        .frame(width: 580)
        .paperSurface(radius: Theme.Radius.dialog)
    }
}

/// A large selectable option: icon, name, and one line of explanation.
struct ChoiceTile: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.accent)
                    .frame(height: 24)
                    .padding(.bottom, 14)
                Text(title)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 4)
                Text(detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(isHovered ? Theme.accentSoft : Theme.surfaceDeep)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) { isHovered = hovering }
        }
    }
}

/// A labeled form row: fixed-width label on the left, field on the right, optional message below.
struct FormRow<Field: View>: View {
    let label: String
    var message: String?
    var isError = false
    @ViewBuilder let field: Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DialogLayout.gap) {
            Text(label)
                .foregroundStyle(Theme.inkMuted)
                .frame(width: DialogLayout.labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                field
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                if let message {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(isError ? Theme.danger : Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum DialogLayout {
    /// Width of a FormRow's label column.
    static let labelWidth: CGFloat = 84
    /// Space between the label column and the field.
    static let gap: CGFloat = 12
}

/// Square, solidly filled dialog buttons. `prominent` is the one action the dialog is for.
struct DialogButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.heading)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(prominent ? Theme.accent : Theme.surfaceDeep)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
