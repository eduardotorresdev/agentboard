import Foundation

/// One thing the search palette can find: a request in the queue, a card, a worktree or an action.
struct SearchEntry: Identifiable, Equatable {
    /// The palette's groups, in the order they show.
    enum Group: Int, CaseIterable, Comparable {
        case queue, cards, worktrees, actions
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    enum Action: Hashable {
        case newAgent(provider: String)
        case newWorktree(project: Int64)
        case addProject, reload, zen, caffeinate, sidebar
    }

    enum Target: Hashable {
        /// An agent waiting on the developer, by its card's id.
        case queue(UUID)
        /// A card on a worktree's canvas; `isRecord` when it is an agent's or a runner's.
        case card(UUID, worktree: String, isRecord: Bool)
        case worktree(String)
        case action(Action)
    }

    var id: Target { target }
    let target: Target
    let group: Group
    let title: String
    let detail: String
    /// The worktree it belongs to, for the "this worktree" scope.
    var worktree: String?
    /// An agent (as opposed to another kind of card), for the "agents" scope.
    var isAgent = false
    /// SF Symbol for its tile.
    var symbol = "square"
    /// sRGB hex of its tile (an agent's brand color); nil uses the theme's.
    var color: UInt32?
    /// What opening it does, said on the right of the row.
    var hint = ""
    /// The key that does the same outside the palette, shown on the right.
    var shortcut: String?
}

/// Which entries the palette searches. Tab steps through them.
enum SearchScope: Int, CaseIterable {
    case all, worktree, agents, cards, actions

    var next: SearchScope { SearchScope(rawValue: (rawValue + 1) % SearchScope.allCases.count) ?? .all }

    func contains(_ entry: SearchEntry, worktree: String?) -> Bool {
        switch self {
        case .all: true
        case .worktree: entry.worktree != nil && entry.worktree == worktree
        case .agents: entry.isAgent
        case .cards: entry.group == .cards && !entry.isAgent
        case .actions: entry.group == .actions
        }
    }
}

/// Case- and diacritic-insensitive substring search over an entry's title and detail, ranked by
/// where the query lands: at the start of the title, at the start of a word in it, inside it,
/// then in the detail.
enum SearchIndex {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    /// shortcut: a fixed cap per group keeps the list short; upgrade to scrolling pages if users miss results.
    static let perGroup = 8

    /// Lower is better; nil when the entry doesn't match.
    static func rank(_ entry: SearchEntry, _ query: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return 0 }
        if let range = entry.title.range(of: query, options: options) {
            if range.lowerBound == entry.title.startIndex { return 0 }
            let before = entry.title[entry.title.index(before: range.lowerBound)]
            return before.isLetter || before.isNumber ? 2 : 1
        }
        return entry.detail.range(of: query, options: options) == nil ? nil : 3
    }

    /// The entries in `scope` that match `query`, grouped in order, best first in each group.
    static func results(_ entries: [SearchEntry], query: String, scope: SearchScope, worktree: String?) -> [SearchEntry] {
        let ranked = entries.enumerated().compactMap { index, entry -> (SearchEntry, Int, Int)? in
            guard scope.contains(entry, worktree: worktree), let rank = rank(entry, query) else { return nil }
            return (entry, rank, index)
        }
        .sorted { ($0.0.group, $0.1, $0.2) < ($1.0.group, $1.1, $1.2) }
        return Dictionary(grouping: ranked.map(\.0), by: \.group)
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.prefix(perGroup) }
    }

    /// Where `query` shows in `text`, to highlight it.
    static func match(_ query: String, in text: String) -> Range<String.Index>? {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : text.range(of: query, options: options)
    }
}
