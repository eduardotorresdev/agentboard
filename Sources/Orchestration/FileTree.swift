import AgentRuntime
import Foundation

/// A file tree card: its worktree's files, listed by the board through the host (`run`). The
/// core keeps the card, so every board on the host shows it; what it sends travels along lines.
public struct FileTreeRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let worktree: String
    public var name: String
    public var frame: CGRect
    /// The organization it was added in; nil means the default one.
    public var organization: UUID?

    public init(id: UUID, worktree: String, name: String, frame: CGRect, organization: UUID? = nil) {
        self.id = id
        self.worktree = worktree
        self.name = name
        self.frame = frame
        self.organization = organization
    }

    public var organizationID: UUID { organization ?? OrganizationHome.defaultID }

    public static let size = CGSize(width: 1040, height: 680)
}
