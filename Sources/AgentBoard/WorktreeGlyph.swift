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
    /// The user's own board has no branch: its title shows instead.
    var title: String?

    var body: some View {
        Label(title ?? branch ?? L("Detached HEAD"), systemImage: title == nil ? "arrow.triangle.branch" : MyBoard.symbol)
            .font(title == nil ? Theme.Font.caption.monospaced() : Theme.Font.heading)
            .foregroundStyle(title == nil ? Theme.inkMuted : Theme.deep)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .paperSurface(radius: Theme.Radius.control)
            .fixedSize()
    }
}
