import Foundation
import Testing
@testable import AgentBoard

struct SearchIndexTests {
    private func card(_ title: String, _ detail: String = "", worktree: String = "/a", agent: Bool = false) -> SearchEntry {
        SearchEntry(target: .card(UUID(), worktree: worktree, isRecord: agent), group: .cards, title: title, detail: detail,
                    worktree: worktree, isAgent: agent)
    }

    @Test func ignoresCaseAndDiacritics() {
        let entries = [card("Ação rápida"), card("Other")]
        #expect(SearchIndex.results(entries, query: "acao RAP", scope: .all, worktree: nil).map(\.title) == ["Ação rápida"])
    }

    @Test func ranksTitlePrefixThenWordThenInsideThenDetail() {
        let entries = [card("x", "relay in detail"), card("prerelay"), card("the relay"), card("relay-server")]
        #expect(SearchIndex.results(entries, query: "relay", scope: .all, worktree: nil).map(\.title)
            == ["relay-server", "the relay", "prerelay", "x"])
    }

    @Test func groupsKeepTheirOrderAndAreCapped() {
        let action = SearchEntry(target: .action(.zen), group: .actions, title: "Zen", detail: "")
        let queued = SearchEntry(target: .queue(UUID()), group: .queue, title: "Zen question?", detail: "")
        let cards = (0 ..< 12).map { card("Zen \($0)") }
        let results = SearchIndex.results([action] + cards + [queued], query: "zen", scope: .all, worktree: nil)
        #expect(results.first == queued)
        #expect(results.last == action)
        #expect(results.filter { $0.group == .cards }.count == SearchIndex.perGroup)
    }

    @Test func scopesFilter() {
        let agent = card("Claude", worktree: "/a", agent: true)
        let postIt = card("Notes", worktree: "/b")
        let action = SearchEntry(target: .action(.zen), group: .actions, title: "Zen", detail: "")
        let entries = [agent, postIt, action]
        #expect(SearchIndex.results(entries, query: "", scope: .worktree, worktree: "/b") == [postIt])
        #expect(SearchIndex.results(entries, query: "", scope: .agents, worktree: nil) == [agent])
        #expect(SearchIndex.results(entries, query: "", scope: .cards, worktree: nil) == [postIt])
        #expect(SearchIndex.results(entries, query: "", scope: .actions, worktree: nil) == [action])
        #expect(SearchScope.actions.next == .all)
    }

    @Test func matchFindsTheRangeToHighlight() {
        let text = "Timeout do Relay"
        let range = SearchIndex.match("relay", in: text)
        #expect(range.map { String(text[$0]) } == "Relay")
        #expect(SearchIndex.match(" ", in: text) == nil)
    }
}
