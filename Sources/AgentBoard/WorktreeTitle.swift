import Connections
import Foundation

/// What a worktree is called in the sidebar: the user's name for it, else the title an agent (or
/// its creation) gave it, else its folder name made readable.
enum WorktreeTitle {
    /// Longest title kept, in characters and in UTF-8 bytes; agents are asked for a few words.
    static let maxLength = 60
    static let maxBytes = 240

    static func resolve(user: String?, agent: String?, folder: String, isMain: Bool) -> String {
        user ?? agent ?? fallback(folder: folder, isMain: isMain)
    }

    /// The main checkout says so; another worktree shows its folder name with dashes and
    /// underscores as spaces and the first letter capitalized. No word or dot is dropped.
    static func fallback(folder: String, isMain: Bool) -> String {
        if isMain { return mainLabel }
        let words = folder.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
        return words.isEmpty ? folder : words.prefix(1).uppercased() + words.dropFirst()
    }

    static var mainLabel: String { L("Main checkout") }

    /// One line of visible text within the limits; see `DisplayText.clean`.
    static func clean(_ title: String) -> String? {
        DisplayText.clean(title, maxLength: maxLength, maxBytes: maxBytes)
    }

    /// Whether a title would pass for one the app shows itself (the main checkout's label), in
    /// any case, accents, width or a lookalike script.
    static func isReserved(_ title: String) -> Bool {
        let reserved = ["Main checkout", mainLabel].map(skeleton)
        return reserved.contains(skeleton(title))
    }

    private static func skeleton(_ text: String) -> String {
        (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    enum RenameAction: Equatable {
        case none
        case set(String)
    }

    /// What ending a rename does. Leaving the field saves only an edit, compared with what the
    /// field opened on, so a title an agent changed meanwhile isn't locked by a stale draft.
    /// Confirming (Return) saves too, pinning an unchanged title an agent or the creation gave,
    /// but not an unchanged fallback, which would lock agents out with a name nobody chose. An
    /// empty name saves as empty, which hands the title back to agents.
    static func renameAction(draft: String, opened: String, openedIsFallback: Bool, confirmed: Bool) -> RenameAction {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = trimmed == opened.trimmingCharacters(in: .whitespacesAndNewlines)
        if unchanged && (!confirmed || openedIsFallback) { return .none }
        return .set(trimmed)
    }
}
