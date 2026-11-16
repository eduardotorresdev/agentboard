import SwiftUI

/// What a worktree's canvas holds, per kind, each at the most pressing status of its cards; nil
/// when the canvas has none of that kind.
struct WorktreeContents: Equatable {
    var agents: CardStatus?
    var runners: CardStatus?
}

/// The worktree's branch, small and quiet in the canvas's top-leading corner: the one place it shows.
struct BranchBadge: View {
    let branch: String?

    var body: some View {
        Label(branch ?? L("Detached HEAD"), systemImage: "arrow.triangle.branch")
            .font(Theme.Font.caption.monospaced())
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .paperSurface(radius: Theme.Radius.control)
            .fixedSize()
    }
}
