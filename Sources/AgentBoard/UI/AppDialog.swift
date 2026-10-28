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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            content

            HStack(spacing: 8) {
                footer
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 24)
        }
        .padding(24)
        .frame(width: 560)
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
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 24)
                    .padding(.bottom, 14)
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 4)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                field
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : .secondary)
                }
            }
        }
    }
}
