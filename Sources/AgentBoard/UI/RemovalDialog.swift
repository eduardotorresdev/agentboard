import SwiftUI

/// What an agent asked to remove from the board, waiting for the user's answer.
struct RemovalRequest: Identifiable {
    let id = UUID()
    /// The asking agent's card name.
    let asker: String
    /// Each thing that would go: its type (`ElementKind.rawValue`, or `connection`) and name.
    let items: [(kind: String, name: String)]
    let answer: (Bool) -> Void
}

/// Asks before an agent removes several things, or anything it didn't put on the board.
struct RemovalDialog: View {
    let request: RemovalRequest
    let answer: (Bool) -> Void

    var body: some View {
        AppDialog(title: L("Remove from the board?"),
                  subtitle: request.asker.isEmpty ? L("An agent asks to remove:") : L("“\(request.asker)” asks to remove:")) {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(request.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: DialogLayout.gap) {
                                Text(item.kind == "connection" ? L("Connection") : BoardMention(name: "", type: item.kind, id: request.id).typeLabel)
                                    .foregroundStyle(Theme.inkMuted)
                                    .frame(width: DialogLayout.labelWidth, alignment: .leading)
                                Text(item.name).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.surfaceDeep))
                Text(L("Remove takes them off the board for good. Keep changes nothing and tells the agent no."))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button(L("Keep"), role: .cancel) { answer(false) }
                .keyboardShortcut(.cancelAction)
            Button(L("Remove")) { answer(true) }
                // No Return shortcut: the dialog opens on its own, maybe while the user types.
                .buttonStyle(DialogButtonStyle(prominent: true))
        }
    }
}
