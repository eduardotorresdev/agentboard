import Foundation

/// A notes block: a shared page on the board. Agents connected to it say where they are working
/// and on what (one status each) and keep notes worth remembering; the user reads and writes
/// them too. The core keeps it, so agents use it while no board runs.
public struct NotesRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let worktree: String
    /// How the block is titled and how connected agents address it; unique in its worktree.
    public var name: String
    public var frame: CGRect
    /// Statuses and notes, oldest first.
    public var entries: [NoteEntry]

    public init(id: UUID, worktree: String, name: String, frame: CGRect, entries: [NoteEntry] = []) {
        self.id = id
        self.worktree = worktree
        self.name = name
        self.frame = frame
        self.entries = entries
    }

    public static let size = CGSize(width: 380, height: 440)

    public var statuses: [NoteEntry] { entries.filter { $0.kind == .status } }
    public var notes: [NoteEntry] { entries.filter { $0.kind == .note } }

    /// Adds `entry`, or replaces the one with its id.
    public mutating func write(_ entry: NoteEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// `base`, or `base 2`, `base 3`… whichever no block in `others` is called.
    public static func uniqueName(_ base: String, among others: [NotesRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

/// One line on a notes block.
public struct NoteEntry: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Where an agent is working and on what; one per agent, replaced as it moves on.
        case status
        /// Something worth remembering: a decision, a convention, a gotcha.
        case note
    }

    public let id: UUID
    public var kind: Kind
    /// The agent that wrote it; nil when the user did.
    public var author: UUID?
    /// The author's name when it wrote it, kept once the agent is gone.
    public var authorName: String
    public var text: String
    /// Statuses only: where the work happens (files, a folder, a branch).
    public var place: String?
    public var updated: Date

    public init(id: UUID = UUID(), kind: Kind, author: UUID?, authorName: String, text: String, place: String? = nil,
                updated: Date = Date()) {
        self.id = id
        self.kind = kind
        self.author = author
        self.authorName = authorName
        self.text = text
        self.place = place
        self.updated = updated
    }

    /// How agents refer to it: the first characters of its id.
    public var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
}
