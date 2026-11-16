import AgentRuntime
import SwiftUI

/// Projects and their worktrees, in a panel floating over the canvas. The canvas shows through
/// it blurred, so the board stays in view behind the list.
struct Sidebar: View {
    let store: ProjectStore
    let agents: AgentStore
    let browsers: BrowserStore
    @Binding var selection: WorktreeSelection?
    @Binding var renaming: Worktree?
    /// Folded projects, kept across launches as comma-separated ids.
    @AppStorage("sidebar.collapsedProjects") private var collapsedIDs = ""
    @State private var pendingRemoval: PendingRemoval?
    /// The project a worktree is being added to.
    @State private var addingWorktreeTo: Project?
    /// The core's session statuses, for the marks; see `refreshStatuses`.
    @State private var statuses: [UUID: SessionStatus] = [:]
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
        .task { await refreshStatuses() }
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
        .sheet(item: $addingWorktreeTo) { project in
            NewWorktreeDialog(store: store, project: project) { worktree in
                collapsed.remove(project.id)
                withAnimation(.snappy(duration: 0.3)) {
                    selection = WorktreeSelection(projectID: project.id, worktree: worktree)
                }
            }
        }
    }

    /// shortcut: polls the core's statuses once a second, since sessions don't publish them to
    /// the main thread while off screen; upgrade if the core gains an observed status feed.
    private func refreshStatuses() async {
        while !Task.isCancelled {
            let known = agents.core?.known ?? [:]
            if known != statuses { statuses = known }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Removes right away when nothing would be lost; otherwise asks first.
    private func requestRemoval(of worktree: Worktree, in project: Project) {
        let removal = PendingRemoval(worktree: worktree, project: project, work: Git.pendingWork(at: worktree.path))
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
        return WorktreeRow(name: store.displayName(of: worktree), contents: contents(of: worktree),
                           isSelected: selection == tag, isRenaming: renaming == worktree,
                           selectionSpace: selectionSpace,
                           onSelect: { withAnimation(.snappy(duration: 0.3)) { selection = tag } },
                           onStartRename: { renaming = worktree },
                           onRename: { name in
                               store.rename(worktree, to: name)
                               renaming = nil
                           })
            .contextMenu {
                Button(L("Rename")) { renaming = worktree }
                if !store.isMain(worktree, in: project) {
                    Divider()
                    Button(L("Remove"), role: .destructive) { requestRemoval(of: worktree, in: project) }
                }
            }
    }

    /// What is on the worktree's canvas, each kind at its most pressing status.
    private func contents(of worktree: Worktree) -> WorktreeContents {
        let cards = agents.agents(in: worktree.path)
        let waiting = Set(agents.attention.map(\.id))
        return WorktreeContents(
            agents: cards.filter { $0.runner == nil }
                .map { CardStatus.agent(statuses[$0.id], waiting: waiting.contains($0.id)) }.max(),
            runners: cards.filter { $0.runner != nil }
                .map { CardStatus.runner(statuses[$0.id], running: agents.runningRunners.contains($0.id)) }.max(),
            hasBrowsers: !browsers.browsers(in: worktree.path).isEmpty)
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
                        .font(.system(size: 9, weight: .semibold))
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
                        .font(.system(size: 11, weight: .semibold))
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

    /// Theme colors that carry white text; no green, teal or flat yellow.
    private static let palette: [Color] = [Theme.accent, Theme.ink, Theme.inkMuted, Theme.danger]

    /// Stable across launches, unlike `hashValue`.
    static func colorIndex(for name: String) -> Int {
        Int(name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(palette.count))
    }

    var body: some View {
        Text(name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.onAccent)
            .frame(width: Self.size, height: Self.size)
            .background(Self.palette[Self.colorIndex(for: name)], in: .rect(cornerRadius: Theme.Radius.thumb))
            .accessibilityHidden(true)
    }
}

/// A worktree: its title, text only, bold when it needs the user, with a small dot on the right
/// while something runs or waits. Double-click renames.
private struct WorktreeRow: View {
    let name: String
    let contents: WorktreeContents
    let isSelected: Bool
    let isRenaming: Bool
    let selectionSpace: Namespace.ID
    let onSelect: () -> Void
    let onStartRename: () -> Void
    let onRename: (String) -> Void
    @State private var isHovered = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// Where the title starts, under the project's name.
    static let textInset: CGFloat = 8 + ProjectTile.size + 9

    private var status: CardStatus? { [contents.agents, contents.runners].compactMap { $0 }.max() }
    private var needsUser: Bool { status == .waiting || status == .crashed }

    var body: some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 0)
            CardStatusDot(status: status ?? .stopped)
                .help(status?.label ?? "")
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .frame(height: 32)
        .background { background }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onStartRename)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status?.label ?? "")
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
                    fieldFocused = true
                }
                .onSubmit { onRename(draft) }
                .onExitCommand { onRename(name) }
                .onChange(of: fieldFocused) { _, focused in if !focused { onRename(draft) } }
        } else {
            Text(name)
                .font(Theme.Font.body.weight(needsUser ? .bold : isSelected ? .medium : .regular))
                .foregroundStyle(needsUser || isSelected ? Theme.ink : Theme.ink.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
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

/// A very light layer over the canvas: the sky and its squares blurred, under a faint paper
/// tint that keeps text AA over the darkest sky (see ThemeContrastTests).
struct SidebarBackdrop: View {
    /// How much paper covers the blurred sky.
    static let tint = 0.35

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Theme.surface.opacity(Self.tint))
            .shadow(color: Theme.line.opacity(0.08), radius: 16, x: 4)
            .ignoresSafeArea()
    }
}
