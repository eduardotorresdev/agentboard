import Orchestration
import AgentRuntime
import SwiftUI

/// Projects and their worktrees, in a panel floating over the canvas. The canvas shows through
/// it blurred, so the board stays in view behind the list.
struct Sidebar: View {
    let store: ProjectStore
    let hosts: HostStores
    let browsers: BrowserStore
    @Binding var selection: WorktreeSelection?
    @Binding var renaming: Worktree?
    /// Folded projects, kept across launches as comma-separated ids.
    @AppStorage(Sidebar.collapsedKey, store: AppDefaults.shared) private var collapsedIDs = ""
    /// Per data folder, like the other keys, so another instance keeps its own.
    private static var collapsedKey: String { "sidebar.collapsedProjects:" + DataFolder.url.path }
    @State private var pendingRemoval: PendingRemoval?
    /// The project a worktree is being added to.
    @State private var addingWorktreeTo: Project?
    @Namespace private var selectionSpace

    static let width: CGFloat = 264

    private var collapsed: Set<Project.ID> {
        get { Set(collapsedIDs.split(separator: ",").compactMap { Int64($0) }) }
        nonmutating set { collapsedIDs = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(store.projects) { project in
                        group(for: project)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background { SidebarBackdrop() }
        .confirmationDialog(pendingRemoval.map { L("Remove \(store.displayName(of: $0.worktree))?") } ?? "",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { removal in
            Button(L("Commit and Push")) {
                if selection?.worktree == removal.worktree { selection = nil }
                store.commitPushAndRemove(removal.worktree, from: removal.project)
            }
            Button(L("Remove"), role: .destructive) { remove(removal) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { removal in
            Text(removal.warning)
        }
        .task {
            guard DebugShow.items.contains("new-worktree") else { return }
            try? await Task.sleep(for: .seconds(2))
            addingWorktreeTo = store.projects.first
        }
        .sheet(item: $addingWorktreeTo) { project in
            NewWorktreeDialog(store: store, project: project, hosts: hosts) { worktree in
                collapsed.remove(project.id)
                withAnimation(.snappy(duration: 0.3)) {
                    selection = WorktreeSelection(projectID: project.id, worktree: worktree)
                }
            }
        }
    }

    /// Removes right away when nothing would be lost; otherwise asks first.
    private func requestRemoval(of worktree: Worktree, in project: Project) {
        if let host = worktree.host {
            // Asked on its host; one that can't be reached says so when the removal fails.
            Task {
                let work = try? await store.onHost(host) { _ in Git.pendingWork(at: worktree.path) }
                confirm(PendingRemoval(worktree: worktree, project: project, work: work ?? Git.PendingWork(changedFiles: 0, unpushedCommits: 0)))
            }
            return
        }
        confirm(PendingRemoval(worktree: worktree, project: project, work: Git.pendingWork(at: worktree.path)))
    }

    private func confirm(_ removal: PendingRemoval) {
        if removal.work.isEmpty { remove(removal) } else { pendingRemoval = removal }
    }

    private func remove(_ removal: PendingRemoval) {
        if selection?.worktree == removal.worktree { selection = nil }
        store.removeWorktree(removal.worktree, from: removal.project, force: !removal.work.isEmpty)
    }

    private func group(for project: Project) -> some View {
        let isCollapsed = collapsed.contains(project.id)
        let worktrees = store.worktrees[project.id]
        return VStack(alignment: .leading, spacing: 6) {
            ProjectHeader(name: project.name, count: worktrees?.count, isCollapsed: isCollapsed,
                          onAddWorktree: worktrees == nil ? nil : { addingWorktreeTo = project }) {
                withAnimation(.snappy(duration: 0.28)) {
                    if isCollapsed { collapsed.remove(project.id) } else { collapsed.insert(project.id) }
                }
            }
            .contextMenu {
                if worktrees != nil {
                    Button(L("New Worktree…")) { addingWorktreeTo = project }
                    Divider()
                }
                Button(L("Remove Project"), role: .destructive) { store.removeProject(project) }
            }
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 2) {
                    if let worktrees {
                        ForEach(worktrees) { worktree in
                            row(for: worktree, in: project)
                        }
                    } else {
                        Text(L("Not a git repository"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.vertical, 6)
                            .padding(.leading, WorktreeRow.textInset)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func row(for worktree: Worktree, in project: Project) -> some View {
        let tag = WorktreeSelection(projectID: project.id, worktree: worktree)
        let source: WorktreeRow.Source = store.isNamedByUser(worktree) ? .user
            : store.agentTitles[worktree.path] != nil ? .agent : .fallback
        let host = worktree.host.flatMap { id in hosts.account.hosts.first { $0.id == id } }
        return WorktreeRow(name: store.displayName(of: worktree), source: source,
                           isMain: store.isMain(worktree, in: project), contents: contents(of: worktree),
                           host: host?.name, isOffline: host?.online == false,
                           isSelected: selection == tag, isRenaming: renaming == worktree,
                           selectionSpace: selectionSpace,
                           onSelect: { withAnimation(.snappy(duration: 0.3)) { selection = tag } },
                           onStartRename: { renaming = worktree },
                           onRename: { draft, opened, confirmed in
                               if case .set(let name) = WorktreeTitle.renameAction(draft: draft, opened: opened,
                                                                                    openedIsFallback: source == .fallback, confirmed: confirmed) {
                                   store.rename(worktree, to: name)
                               }
                               renaming = nil
                           })
            .contextMenu {
                Button(L("Rename")) { renaming = worktree }
                if source == .user {
                    // Your name stays until you hand the title back.
                    Button(L("Let Agents Rename")) { store.rename(worktree, to: "") }
                }
                Button(L("Pull")) { store.pull(worktree) }
                if !store.isMain(worktree, in: project) {
                    Divider()
                    Button(L("Remove"), role: .destructive) { requestRemoval(of: worktree, in: project) }
                }
            }
    }

    /// What is on the worktree's canvas, each kind at its most pressing status.
    private func contents(of worktree: Worktree) -> WorktreeContents {
        // A host not in use, or one that doesn't answer, shows no status.
        guard let agents = hosts[worktree.host], hosts.connected.contains(where: { $0 === agents }) else { return WorktreeContents(agents: nil, runners: nil) }
        let cards = agents.agents(in: worktree.path)
        return WorktreeContents(agents: cards.filter { $0.runner == nil }.map(agents.cardStatus).max(),
                                runners: cards.filter { $0.runner != nil }.map(agents.cardStatus).max())
    }

}

/// A worktree waiting on the user to confirm its removal, with what removing it would lose.
private struct PendingRemoval {
    let worktree: Worktree
    let project: Project
    let work: Git.PendingWork

    var warning: String {
        var parts: [String] = []
        if work.changedFiles > 0 { parts.append(L("\(work.changedFiles) files with uncommitted changes")) }
        if work.unpushedCommits > 0 { parts.append(L("\(work.unpushedCommits) commits not pushed")) }
        return parts.joined(separator: "\n") + "\n\n" + L("Commit and Push saves this work to the remote, then removes the worktree. Remove deletes its folder and loses it.")
    }
}

/// A project's name over its worktrees, after its tile; clicking folds them away.
private struct ProjectHeader: View {
    let name: String
    /// Worktrees in the project, nil when it isn't a git repository.
    let count: Int?
    let isCollapsed: Bool
    /// Adds a worktree; nil when the project can't have one.
    let onAddWorktree: (() -> Void)?
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 9) {
                    ProjectTile(name: name)
                    Text(name)
                        .font(Theme.Font.heading)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let count, isCollapsed, !isHovered {
                        Text(count, format: .number)
                            .font(Theme.Font.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Image(systemName: "chevron.down")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .opacity(isHovered || isCollapsed ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(isCollapsed ? L("Collapsed") : L("Expanded"))
            if let onAddWorktree, isHovered {
                Button(action: onAddWorktree) {
                    Image(systemName: "plus")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(L("New Worktree…"))
                .accessibilityLabel(L("New Worktree…"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
    }
}

/// A project's mark: its initial on a small square tile, in a color that stays the same for the
/// same name.
struct ProjectTile: View {
    let name: String
    static let size: CGFloat = 20

    /// Blue and slate steps that carry white text at AA; never red, which means an error.
    private static let palette: [Color] = [Theme.accent, Theme.deep, Theme.ink, Theme.inkMuted]

    /// Stable across launches, unlike `hashValue`.
    static func colorIndex(for name: String) -> Int {
        Int(name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(palette.count))
    }

    var body: some View {
        Text(name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•")
            .font(Theme.Font.label)
            .foregroundStyle(Theme.onAccent)
            .frame(width: Self.size, height: Self.size)
            .background(Self.palette[Self.colorIndex(for: name)], in: .rect(cornerRadius: Theme.Radius.thumb))
            .accessibilityHidden(true)
    }
}

/// A worktree: its title, text only, bold when it needs the user, with a small dot on the right
/// while something runs or waits. Double-click renames.
private struct WorktreeRow: View {
    enum Source { case user, agent, fallback }

    let name: String
    /// Who gave the title: the user's name locks agents out.
    let source: Source
    /// The project's own checkout: marked, so no title can pass for it.
    let isMain: Bool
    let contents: WorktreeContents
    /// The name of the host it lives on, when not this Mac.
    var host: String?
    /// Its host isn't online: what is known of it shows, dimmed.
    var isOffline = false
    let isSelected: Bool
    let isRenaming: Bool
    let selectionSpace: Namespace.ID
    let onSelect: () -> Void
    let onStartRename: () -> Void
    /// The draft, the title the field opened on, and whether Return confirmed it.
    let onRename: (_ draft: String, _ opened: String, _ confirmed: Bool) -> Void
    @State private var isHovered = false
    @State private var draft = ""
    @State private var opened = ""
    @FocusState private var fieldFocused: Bool

    /// Where the title starts, under the project's name.
    static let textInset: CGFloat = 8 + ProjectTile.size + 9

    private var status: CardStatus? { [contents.agents, contents.runners].compactMap { $0 }.max() }
    private var needsUser: Bool { status == .waiting || status == .crashed }

    var body: some View {
        HStack(spacing: 8) {
            // The title gets the row's width; where it lives goes under it.
            VStack(alignment: .leading, spacing: 1) {
                title
                if let host {
                    Text(isOffline ? L("\(host) · offline") : host)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isMain && source != .fallback {
                Text(L("main"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkMuted)
            }
            CardStatusDot(status: status ?? .stopped)
                .help(status?.label ?? "")
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .frame(height: host == nil ? 32 : 46)
        .background { background }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onStartRename)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status?.label ?? L("No cards"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    @ViewBuilder private var title: some View {
        if isRenaming {
            TextField(L("Name"), text: $draft, prompt: Text(name))
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($fieldFocused)
                .onAppear {
                    draft = name
                    opened = name
                    fieldFocused = true
                }
                .onSubmit { onRename(draft, opened, true) }
                .onExitCommand { onRename(opened, opened, false) }
                .onChange(of: fieldFocused) { _, focused in if !focused { onRename(draft, opened, false) } }
        } else {
            Text(name)
                .font(Theme.Font.body.weight(needsUser ? .bold : isSelected ? .medium : .regular))
                // Dimmed with the muted ink, which still passes AA, not with opacity.
                .foregroundStyle(isOffline ? Theme.inkMuted : needsUser || isSelected ? Theme.ink : Theme.ink.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(source == .user ? L("\(name) · Named by you; agents can't rename it") : name)
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        if isSelected {
            shape.fill(Theme.ink.opacity(0.08))
                .matchedGeometryEffect(id: "selection", in: selectionSpace)
        } else {
            shape.fill(Theme.ink.opacity(isHovered ? 0.04 : 0))
        }
    }
}

/// A light translucent layer over the canvas: the sky and its squares blurred, under a white
/// tint and a faint slate one, so the sidebar reads as its own layer even over an empty, near-white
/// sky. No border, no shadow. Text stays AA over the darkest sky (see ThemeContrastTests).
struct SidebarBackdrop: View {
    /// How much white covers the blurred sky.
    static let tint = 0.55
    /// The slate (ink) tint over that, which sets the sidebar apart.
    static let shade = 0.05

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Theme.surface.opacity(Self.tint))
            .overlay(Theme.ink.opacity(Self.shade))
            .ignoresSafeArea()
    }
}
