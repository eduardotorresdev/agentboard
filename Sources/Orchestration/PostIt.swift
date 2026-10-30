import AgentRuntime
import Foundation

/// A post-it on the board: one markdown text that the user and the agents connected to it read
/// and rewrite. The core keeps it, so agents use it while no board runs.
public struct PostItRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let worktree: String
    /// How the post-it is titled and how connected agents address it; unique in its worktree.
    public var name: String
    public var frame: CGRect
    /// Markdown.
    public var text: String
    /// Who wrote the text last: an agent, or nil for the user.
    public var editor: UUID?
    /// That agent's name when it wrote, kept once it is gone.
    public var editorName: String
    /// When the text last changed; nil while nothing was written.
    public var edited: Date?
    /// The organization it was added in; nil for post-its made before organizations, which
    /// belong to the default one.
    public var organization: UUID?

    public init(id: UUID, worktree: String, name: String, frame: CGRect, text: String = "", editor: UUID? = nil,
                editorName: String = "", edited: Date? = nil, organization: UUID? = nil) {
        self.id = id
        self.worktree = worktree
        self.name = name
        self.frame = frame
        self.text = text
        self.editor = editor
        self.editorName = editorName
        self.edited = edited
        self.organization = organization
    }

    /// The organization the post-it belongs to, with older ones in the default one.
    public var organizationID: UUID { organization ?? OrganizationHome.defaultID }

    public static let size = CGSize(width: 340, height: 320)

    /// Replaces the text, as written by `editor` (nil: the user).
    public mutating func write(_ text: String, by editor: UUID?, named name: String = "", at date: Date = Date()) {
        self.text = text
        self.editor = editor
        editorName = editor == nil ? "" : name
        edited = date
    }

    /// `base`, or `base 2`, `base 3`… whichever no post-it in `others` is called.
    public static func uniqueName(_ base: String, among others: [PostItRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}
