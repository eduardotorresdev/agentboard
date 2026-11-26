import AgentRuntime
import AppKit
import Connections
import Orchestration
import SwiftUI

extension SearchEntry {
    /// Everything the palette can find in the shown organization, from the stores.
    @MainActor static func all(projects: ProjectStore, hosts: HostStores, selection: WorktreeSelection?) -> [SearchEntry] {
        let organization = projects.organizationID
        let here = selection?.worktree.path
        func place(_ path: String) -> String {
            if path == here { return L("this worktree") }
            let place = projects.place(ofPath: path)
            return [place.project, place.worktree].compactMap { $0 }.joined(separator: " / ")
        }
        let queue = hosts.needsYou
        var entries: [SearchEntry] = []

        for item in queue {
            guard let agents = hosts.store(of: item.agent), let record = agents.record(item.agent) else { continue }
            let title: String = switch item {
            case .decisions: agents.decisionSequence(of: item.agent)?.shown.ask.question ?? record.name
            case .attention(let request):
                request.questions?.first?.question
                    ?? request.context?.split(separator: "\n").first.map(String.init)
                    ?? (request.needsUser ? L("Waiting for you.") : L("Finished its turn. Your move."))
            }
            let full = projects.place(ofPath: record.worktree)
            let detail: [String?] = [record.name, record.provider?.title, [full.project, full.worktree].compactMap { $0 }.joined(separator: " / ")]
            entries.append(SearchEntry(target: .queue(item.agent), group: .queue, title: title,
                                       detail: detail.compactMap { $0 }.joined(separator: " · "),
                                       worktree: record.worktree, isAgent: true, symbol: "hand.raised.fill", hint: L("answer")))
        }

        for agents in hosts.connected {
            for record in agents.agents where record.organizationID == organization {
                let kind = record.runner == nil ? record.provider?.title ?? L("Agent") : L("Runner")
                entries.append(SearchEntry(target: .card(record.id, worktree: record.worktree, isRecord: true), group: .cards,
                                           title: record.name, detail: "\(kind) · \(place(record.worktree))",
                                           worktree: record.worktree, isAgent: record.runner == nil,
                                           symbol: record.runner == nil ? "sparkles" : "terminal",
                                           color: record.runner == nil ? record.provider?.brandColor : nil, hint: L("go to card")))
            }
            for postIt in agents.postIts where postIt.organizationID == organization {
                entries.append(SearchEntry(target: .card(postIt.id, worktree: postIt.worktree, isRecord: false), group: .cards,
                                           title: postIt.name, detail: "\(L("Post-it")) · \(place(postIt.worktree))",
                                           worktree: postIt.worktree, symbol: "note.text", hint: L("go to card")))
            }
            for image in agents.images where (image.organization ?? OrganizationHome.defaultID) == organization {
                entries.append(SearchEntry(target: .card(image.id, worktree: image.worktree, isRecord: false), group: .cards,
                                           title: image.name, detail: "\(image.isVideo ? L("Video") : L("Image")) · \(place(image.worktree))",
                                           worktree: image.worktree, symbol: image.isVideo ? "film" : "photo", hint: L("go to card")))
            }
            let kinds: [String: (String, String)] = [
                ElementKind.browser.rawValue: (L("Browser"), "globe"),
                ElementKind.simulator.rawValue: (L("Simulator"), "iphone"),
                ElementKind.fileTree.rawValue: (L("File tree"), "folder"),
            ]
            for element in agents.elements() where element.organization == nil || element.organization == organization {
                guard let (kind, symbol) = kinds[element.kind] else { continue }
                entries.append(SearchEntry(target: .card(element.id, worktree: element.worktree, isRecord: false), group: .cards,
                                           title: element.name, detail: "\(kind) · \(place(element.worktree))",
                                           worktree: element.worktree, symbol: symbol, hint: L("go to card")))
            }
        }

        let waiting = queue.compactMap { hosts.store(of: $0.agent)?.record($0.agent)?.worktree }
        for project in projects.projects {
            for worktree in projects.worktrees[project.id] ?? [] {
                let count = waiting.filter { $0 == worktree.path }.count
                let queued = count == 0 ? nil : count == 1 ? L("1 agent in your queue") : L("\(count) agents in your queue")
                entries.append(SearchEntry(target: .worktree(worktree.path), group: .worktrees, title: projects.displayName(of: worktree),
                                           detail: [project.name, queued].compactMap { $0 }.joined(separator: " · "),
                                           worktree: worktree.path, symbol: "arrow.triangle.branch", hint: L("open")))
            }
        }

        if let selection {
            let name = projects.displayName(of: selection.worktree)
            for provider in AgentCatalog.all {
                entries.append(SearchEntry(target: .action(.newAgent(provider: provider.id)), group: .actions,
                                           title: L("New \(provider.title) agent in \(name)"), detail: provider.subtitle,
                                           worktree: selection.worktree.path, symbol: "plus", color: provider.brandColor))
            }
        }
        for project in projects.projects {
            entries.append(SearchEntry(target: .action(.newWorktree(project: project.id)), group: .actions,
                                       title: L("New worktree in \(project.name)"), detail: L("A branch of its own, in a folder of its own."),
                                       symbol: "arrow.triangle.branch"))
        }
        entries.append(SearchEntry(target: .action(.addProject), group: .actions, title: L("Add Project"),
                                   detail: L("Clone, create, or open a project."), symbol: "folder.badge.plus"))
        entries.append(SearchEntry(target: .action(.reload), group: .actions, title: L("Refresh"),
                                   detail: L("Reloads the projects and their worktrees."), symbol: "arrow.clockwise"))
        entries.append(SearchEntry(target: .action(.sidebar), group: .actions, title: L("Toggle Sidebar"),
                                   detail: L("Shows or hides the projects beside the canvas."), symbol: "sidebar.left", shortcut: "⌃⌘S"))
        entries.append(SearchEntry(target: .action(.zen), group: .actions, title: L("Zen mode"),
                                   detail: L("Zen mode: hides everything but the canvas, its tools, and Needs you."), symbol: "leaf"))
        entries.append(SearchEntry(target: .action(.caffeinate), group: .actions, title: L("Caffeinate"),
                                   detail: Caffeinate.shared.isOn ? L("Caffeinate on: the Mac and its display stay awake. Click to let them sleep.")
                                       : L("Caffeinate: keeps the Mac and its display awake while agents work."),
                                   symbol: "cup.and.saucer.fill"))
        return entries
    }
}

/// ⌘K: a floating panel over the canvas that finds what waits on the developer, cards across the
/// organization's worktrees, worktrees and actions, and opens one from the keyboard.
struct SearchPalette: View {
    let entries: [SearchEntry]
    /// The worktree on the canvas, for the "this worktree" scope.
    let worktree: String?
    @Binding var isOpen: Bool
    /// Opens the entry; `stay` (⌘↵) keeps the developer on the canvas they are looking at when it can.
    let onOpen: (SearchEntry, _ stay: Bool) -> Void
    @State private var query = ""
    @State private var scope = SearchScope.all
    @State private var selected = 0
    @State private var keyMonitor: Any?
    @FocusState private var isFocused: Bool

    private var results: [SearchEntry] { SearchIndex.results(entries, query: query, scope: scope, worktree: worktree) }

    var body: some View {
        ZStack(alignment: .top) {
            // A click outside closes it.
            Theme.window.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: close)
            panel
                .padding(.top, 24)
                .padding(.horizontal, 16)
        }
        .onAppear {
            isFocused = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handle($0) ? nil : $0 }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .onChange(of: query) { selected = 0 }
        .onChange(of: scope) { selected = 0 }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                TextField("", text: $query, prompt: Text(L("Search agents, cards, worktrees and actions")).foregroundStyle(Theme.inkMuted))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.title.weight(.regular))
                    .foregroundStyle(Theme.ink)
                    .focused($isFocused)
                KeyChip(text: "esc")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            HStack(spacing: 6) {
                ForEach(SearchScope.allCases, id: \.self) { option in
                    Button { scope = option } label: {
                        Text(option.title)
                            .font(Theme.Font.label)
                            .foregroundStyle(option == scope ? Theme.onAccent : Theme.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(option == scope ? Theme.accent : Theme.surfaceDeep,
                                        in: .rect(cornerRadius: Theme.Radius.thumb, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(option.help)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            list
            footer
        }
        .frame(maxWidth: 660)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.dialog, style: .continuous))
        .clipShape(.rect(cornerRadius: Theme.Radius.dialog, style: .continuous))
    }

    private var list: some View {
        let results = results
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        Text(L("Nothing matches."))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.inkMuted)
                            .padding(18)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        if index == 0 || results[index - 1].group != entry.group {
                            Text(entry.group.title)
                                .font(Theme.Font.eyebrow)
                                .tracking(Theme.Font.eyebrowTracking)
                                .foregroundStyle(Theme.inkMuted)
                                .padding(.horizontal, 18)
                                .padding(.top, index == 0 ? 6 : 14)
                                .padding(.bottom, 6)
                        }
                        row(entry, isSelected: index == selected)
                            .id(index)
                            .onTapGesture { open(entry, stay: false) }
                            .onHover { if $0 { selected = index } }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { _, index in proxy.scrollTo(index) }
        }
    }

    private func row(_ entry: SearchEntry, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            tile(entry)
            VStack(alignment: .leading, spacing: 2) {
                highlighted(entry.title)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.ink)
                highlighted(entry.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut { KeyChip(text: shortcut) }
            if !entry.hint.isEmpty {
                Text(entry.group == .queue ? "↵ " + entry.hint : entry.hint)
                    .font(Theme.Font.caption)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkMuted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(isSelected ? Theme.accentSoft : .clear, in: .rect(cornerRadius: Theme.Radius.control, style: .continuous))
        .contentShape(.rect)
        .padding(.horizontal, 8)
    }

    private func tile(_ entry: SearchEntry) -> some View {
        let fill: Color = entry.group == .queue ? Theme.you
            : entry.color.map(Theme.color) ?? (entry.group == .worktrees || entry.group == .actions ? Theme.accent : Theme.surfaceDeep)
        let ink: Color = entry.group == .queue ? Theme.onYou : entry.color == nil && entry.group == .cards ? Theme.ink : Theme.onAccent
        return Image(systemName: entry.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: 28, height: 28)
            .background(fill, in: .rect(cornerRadius: Theme.Radius.thumb, style: .continuous))
    }

    /// The text with the query's match in the accent.
    private func highlighted(_ text: String) -> Text {
        guard let range = SearchIndex.match(query, in: text) else { return Text(verbatim: text) }
        return Text(verbatim: String(text[..<range.lowerBound]))
            + Text(verbatim: String(text[range])).foregroundStyle(Theme.accentText)
            + Text(verbatim: String(text[range.upperBound...]))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(L("↑↓ navigate"))
            Text(L("↵ open"))
            Text(L("⌘↵ open without leaving the canvas"))
            Spacer()
            Text(L("Tab changes the scope"))
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Theme.plane)
    }

    /// The palette's keys, wherever the focus is while it is open. True when it took the key.
    private func handle(_ event: NSEvent) -> Bool {
        let results = results
        switch event.keyCode {
        case 53: close() // esc
        case 125: if !results.isEmpty { selected = min(selected + 1, results.count - 1) } // down
        case 126: selected = max(selected - 1, 0) // up
        case 48: scope = event.modifierFlags.contains(.shift) // tab
            ? SearchScope(rawValue: (scope.rawValue + SearchScope.allCases.count - 1) % SearchScope.allCases.count) ?? .all
            : scope.next
        case 36, 76: // return, enter
            guard results.indices.contains(selected) else { return true }
            open(results[selected], stay: event.modifierFlags.contains(.command))
        default: return false
        }
        return true
    }

    private func open(_ entry: SearchEntry, stay: Bool) {
        close()
        onOpen(entry, stay)
    }

    private func close() {
        withAnimation(.snappy(duration: 0.25)) { isOpen = false }
    }
}

/// A key's name in a small chip, as on the keyboard.
struct KeyChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10.5, weight: .semibold).monospaced())
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.thumb - 2, style: .continuous))
    }
}

extension SearchEntry.Group {
    var title: String {
        switch self {
        case .queue: L("IN MY QUEUE")
        case .cards: L("AGENTS AND CARDS")
        case .worktrees: L("WORKTREES")
        case .actions: L("ACTIONS")
        }
    }
}

extension SearchScope {
    var title: String {
        switch self {
        case .all: L("All")
        case .worktree: L("This worktree")
        case .agents: L("Agents")
        case .cards: L("Cards")
        case .actions: L("Actions")
        }
    }

    var help: String {
        switch self {
        case .all: L("Searches everything in this organization.")
        case .worktree: L("Only what is on the canvas you are looking at.")
        case .agents: L("Only agents, waiting on you or not.")
        case .cards: L("Runners, post-its, browsers and the other cards.")
        case .actions: L("Things to do, such as a new agent or a new worktree.")
        }
    }
}
