import Foundation

/// What a worktree is called in the sidebar: the user's name for it, else the title an agent on
/// its canvas gave it, else its folder name made readable. Never its branch.
enum WorktreeTitle {
    /// Longest title kept; agents are asked for a few words.
    static let maxLength = 60

    static func resolve(user: String?, agent: String?, folder: String) -> String {
        user ?? agent ?? humanize(folder)
    }

    /// `board-input_mentions` → `Board input mentions`.
    static func humanize(_ folder: String) -> String {
        let words = folder.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " })
        guard let first = words.first else { return folder }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst().map(String.init)).joined(separator: " ")
    }

    /// Trimmed to one line and `maxLength`; nil when nothing is left.
    static func clean(_ title: String) -> String? {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(maxLength))
    }
}
