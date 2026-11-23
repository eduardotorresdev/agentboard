import AgentRuntime
import Foundation
import Orchestration

/// The user's own board: a free canvas that belongs to no project, one per organization. Its
/// cards live in a folder of its own in the data folder, which is where its agents start.
enum MyBoard {
    private static var root: String { DataFolder.url.appendingPathComponent("organizations", isDirectory: true).path + "/" }

    static func worktree(in organization: UUID) -> Worktree {
        Worktree(path: OrganizationHome.folder(organization).appendingPathComponent("board", isDirectory: true).path, branch: nil)
    }

    /// Makes the board's folder, so a card can start in it.
    static func prepare(in organization: UUID) {
        try? FileManager.default.createDirectory(atPath: worktree(in: organization).path, withIntermediateDirectories: true)
    }

    /// Whether `path` is an organization's board, the shown one or not.
    static func isBoard(_ path: String) -> Bool {
        path.hasPrefix(root) && path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false).dropFirst() == ["board"]
    }

    static let symbol = "scribble.variable"

    /// What it is called until the user names it.
    static var defaultTitle: String { L("My Board") }
}
