import Orchestration
import AgentRuntime
import AppKit
import SwiftUI

/// The organization, its projects and their worktrees, and at the foot the controls, the
/// computer's stats, the computers and the plan's usage, on a solid panel inset over the
/// canvas's leading edge.
struct Sidebar: View {
    let store: ProjectStore
    let hosts: HostStores
    let browsers: BrowserStore
    @Binding var selection: WorktreeSelection?
    @Binding var renaming: Worktree?
    let board: BoardController
    /// Opens the Add Project dialog.
    let onAddProject: () -> Void
    /// Folded projects, kept across launches as comma-separated ids.
    @AppStorage(Sidebar.collapsedKey, store: AppDefaults.shared) private var collapsedIDs = ""
    /// Per data folder, like the other keys, so another instance keeps its own.
    private static var collapsedKey: String { "sidebar.collapsedProjects:" + DataFolder.url.path }
    @State private var pendingRemoval: PendingRemoval?
    /// The project a worktree is being added to.
    @State private var addingWorktreeTo: Project?
    @Namespace private var selectionSpace
    /// The project or worktree being dragged to another place, if any.
    @State private var drag: ReorderDrag?
    /// Where each reorderable item is; not observed, so scrolling doesn't redraw the sidebar.
    @State private var frames = ReorderFrames()
    /// How far the dragged item follows the pointer; only the floating copy reads it, so a pointer
    /// move redraws that alone, not the sidebar.
    @State private var pointer = ReorderPointer()
    /// True while a press that may become a drag is held: a drag the system cancels (no `onEnded`) is undone when it goes false.
    @GestureState private var isPressing = false
    /// The item being held, before it lifts: it grows slowly toward `pressedScale`.
    @State private var hold: ReorderHold?
    /// Watches the trackpad's force click, which lifts a held item at once.
    @State private var pressureMonitor: Any?
    /// How far a held item grows while the hold runs; past it, it lifts to 1.15.
    static let pressedScale: CGFloat = 1.05
    /// How long a press is held before the item lifts.
    static let holdDuration = 0.3

    /// What the sidebar covers of the canvas's leading edge, its inset from the window's edge included.
    static let width: CGFloat = 264
    /// Its inset from the window's leading and bottom edges, and from the top bar.
    static let inset: CGFloat = 8
    /// Space between projects.
    private static let projectSpacing: CGFloat = 4
    /// Where the dragged item and the pointer are measured.
    fileprivate static let space = "sidebar"

    private var collapsed: Set<Project.ID> {
        get { Set(collapsedIDs.split(separator: ",").compactMap { Int64($0) }) }
        nonmutating set { collapsedIDs = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    var body: some View {
        VStack(spacing: 10) {
            OrganizationSwitcher(store: store, agents: hosts.local, hosts: hosts)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    boardRow
                    projectsHeader
                    let keys = store.projects.map { Self.reorderKey($0) }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.projects) { project in
                            let key = Self.reorderKey(project)
                            reorderable(key, in: keys, spacing: Self.projectSpacing) {
                                group(for: project, reorder: reorderGesture(key, in: keys) { order in
                                    store.moveProjects(to: order.compactMap { key in store.projects.first { Self.reorderKey($0) == key }?.id })
                                })
                            }
                        }
                        reorderEnd(of: keys, spacing: Self.projectSpacing)
                    }
                    // Each item keeps its own space after it, so a dragged one takes it along; not the last.
                    .padding(.bottom, -Self.projectSpacing)
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .scrollDisabled(drag != nil)
            SidebarFooter(hosts: hosts, board: board, organization: store.organizationID)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topLeading) { floating }
        .coordinateSpace(.named(Self.space))
        .background(Theme.plane, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding([.leading, .top, .bottom], Self.inset)
        .frame(width: Self.width)
        .onChange(of: isPressing) { _, pressing in
            guard !pressing else { return }
            // Next turn: a normal release's `onEnded` runs around this reset and starts the drop first.
            Task { @MainActor in
                hold = nil
                if drag?.isDropping == false {
                    drag = nil
                    pointer.offset = .zero
                }
            }
        }
        .onAppear {
            pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { event in
                // Stage 2 is the trackpad's deeper (force) click: no need to wait out the hold.
                if event.stage >= 2, let hold { lift(hold) }
                return event
            }
        }
        .onDisappear { pressureMonitor.map(NSEvent.removeMonitor) }
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

    private func group(for project: Project, reorder: some Gesture) -> some View {
        let isCollapsed = collapsed.contains(project.id)
        let worktrees = store.worktrees[project.id]
        let keys = worktrees?.map(\.id) ?? []
        return VStack(alignment: .leading, spacing: 6) {
            ProjectHeader(name: project.name, count: worktrees?.count, isCollapsed: isCollapsed,
                          onAddWorktree: worktrees == nil ? nil : { addingWorktreeTo = project }) {
                // The release of a hold or drag isn't a click.
                guard drag == nil else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    if isCollapsed { collapsed.remove(project.id) } else { collapsed.insert(project.id) }
                }
            }
            .simultaneousGesture(reorder)
            .contextMenu {
                if worktrees != nil {
                    Button(L("New Worktree…")) { addingWorktreeTo = project }
                    Divider()
                }
                Button(L("Remove Project"), role: .destructive) { store.removeProject(project) }
            }
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    if let worktrees {
                        ForEach(worktrees) { worktree in
                            reorderable(worktree.id, in: keys, spacing: 2) {
                                row(for: worktree, in: project)
                                    .simultaneousGesture(reorderGesture(worktree.id, in: keys) { store.moveWorktrees(to: $0) })
                            }
                        }
                        reorderEnd(of: keys, spacing: 2)
                    } else {
                        Text(L("Not a git repository"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.vertical, 6)
                            .padding(.leading, WorktreeRow.textInset)
                    }
                }
                .padding(.bottom, -2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Clipped for folding, vertically only, so a held row's growth isn't cut at the sides.
        .mask { Rectangle().padding(.horizontal, -24) }
    }

    // MARK: Reordering

    private static func reorderKey(_ project: Project) -> String { "project:\(project.id)" }

    /// An item of a list (`keys`, in order) the user can reorder, with the `spacing` after it. While
    /// one of the list is dragged, the dragged one's own place stays open until it heads elsewhere;
    /// then that place closes as the one it would land in opens over the item it goes before.
    private func reorderable(_ key: String, in keys: [String], spacing: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        let drag = drag?.keys == keys ? drag : nil
        let isDragged = drag?.key == key
        return VStack(alignment: .leading, spacing: 0) {
            placeholder(drag?.slot(before: key) ?? 0, spacing: spacing)
            content()
                .modifier(ReorderMeasure { frames.frames[key] = $0; frames.heights[key] = $0.height + spacing })
                .padding(.bottom, isDragged ? 0 : spacing)
                // Drawn floating instead (see `floating`); kept here, out of sight, as its gesture lives on it.
                .frame(height: isDragged ? 0 : nil, alignment: .top)
                .clipped()
                // Grows over the hold's length, so reaching the threshold feels like the lift.
                .scaleEffect(isHeld(key) && drag == nil ? Self.pressedScale : 1)
                .animation(isHeld(key) ? .smooth(duration: 0.3) : .snappy(duration: 0.25), value: isHeld(key))
        }
    }

    /// The place at the end of `keys`, open while an item is dragged there.
    private func reorderEnd(of keys: [String], spacing: CGFloat) -> some View {
        placeholder(drag?.keys == keys ? drag?.slot(before: nil) ?? 0 : 0, spacing: spacing)
    }

    /// The place a dragged item would land, closed at 0; the open one is measured, for the drop to land on it exactly.
    private func placeholder(_ height: CGFloat, spacing: CGFloat) -> some View {
        ReorderPlaceholder(height: height, spacing: spacing)
            .modifier(ReorderMeasure { if height > 0 { frames.placeholder = $0 } })
    }

    /// The dragged item, over the whole sidebar where the pointer takes it, on a solid fill.
    @ViewBuilder private var floating: some View {
        if let drag {
            FloatingItem(isDropping: drag.isDropping, origin: drag.frame.origin, pointer: pointer) {
                if let project = store.projects.first(where: { Self.reorderKey($0) == drag.key }) {
                    group(for: project, reorder: TapGesture())
                } else if let project = store.projects.first(where: { store.worktrees[$0.id]?.contains { $0.id == drag.key } == true }),
                          let worktree = store.worktrees[project.id]?.first(where: { $0.id == drag.key }) {
                    row(for: worktree, in: project)
                }
            }
            .frame(width: drag.frame.width, alignment: .topLeading)
        }
    }

    private func isHeld(_ key: String) -> Bool { hold?.key == key && hold?.isCancelled == false }

    /// Lifts the held item into the drag, once its hold runs out or on a force click.
    private func lift(_ held: ReorderHold) {
        guard hold?.id == held.id, !held.isCancelled, drag == nil, let frame = frames.frames[held.key] else { return }
        drag = ReorderDrag(key: held.key, keys: held.keys, frame: frame, heights: frames.heights)
        hold = nil
    }

    /// Press and hold (or force click), then drag: moves `key` among `keys`, and on release lands it
    /// in its new place before handing `onMove` the new order.
    private func reorderGesture(_ key: String, in keys: [String], onMove: @escaping ([String]) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                guard drag?.isDropping != true else { return }
                if let current = drag {
                    guard current.key == key else { return }
                    pointer.offset = value.translation
                    // `drag` changes only when the place changes: a plain pointer move leaves the sidebar alone.
                    var next = current
                    next.move(pointer: value.location.y)
                    if next.target != current.target { withAnimation(.snappy(duration: 0.35)) { drag = next } }
                    return
                }
                if hold == nil {
                    let held = ReorderHold(key: key, keys: keys)
                    hold = held
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.holdDuration))
                        lift(held)
                    }
                }
                guard hold?.key == key else { return }
                pointer.offset = value.translation
                // Moving off before the hold runs out is a plain click or drag, not a reorder.
                if hold?.isCancelled == false, hypot(value.translation.width, value.translation.height) > 10 { hold?.isCancelled = true }
            }
            .onEnded { _ in
                hold = nil
                guard var landing = drag, landing.keys == keys else { drag = nil; return }
                landing.isDropping = true
                withAnimation(.snappy(duration: 0.35, extraBounce: 0.1), completionCriteria: .removed) {
                    drag = landing
                    // Onto the open place, as measured; computed from the heights until it is.
                    let place = frames.placeholder?.origin ?? CGPoint(x: landing.frame.minX, y: landing.frame.minY + landing.top(landing.target) - landing.start)
                    pointer.offset = CGSize(width: place.x - landing.frame.minX, height: place.y - landing.frame.minY)
                } completion: {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        onMove(landing.order)
                        drag = nil
                        pointer.offset = .zero
                        frames.placeholder = nil
                    }
                }
            }
    }

    /// "Projects", with adding one; reloading them is in its menu.
    private var projectsHeader: some View {
        HStack(spacing: 6) {
            Text(L("Projects").uppercased())
                .font(Theme.Font.eyebrow)
                .tracking(Theme.Font.eyebrowTracking)
                .foregroundStyle(Theme.inkMuted)
            Spacer(minLength: 4)
            SidebarIconButton(symbol: "plus", title: L("Add Project"), help: L("Clone, create, or open a project."), action: onAddProject)
        }
        .padding(.leading, 8)
        .padding(.top, 4)
        .contextMenu {
            Button(L("Add Project"), action: onAddProject)
            Button(L("Refresh")) {
                store.reload()
                store.refreshHostWorktrees(probing: true)
            }
        }
    }

    /// The user's own board, over the projects: it belongs to none.
    private var boardRow: some View {
        let board = store.board
        let tag = WorktreeSelection(projectID: nil, worktree: board)
        let source: WorktreeRow.Source = store.isNamedByUser(board) ? .user : .fallback
        return WorktreeRow(name: store.displayName(of: board), source: source, isMain: false, contents: contents(of: board),
                           isBoard: true, isSelected: selection == tag, isRenaming: renaming == board,
                           selectionSpace: selectionSpace,
                           onSelect: { withAnimation(.snappy(duration: 0.3)) { selection = tag } },
                           onStartRename: { renaming = board },
                           onRename: { draft, opened, confirmed in
                               if case .set(let name) = WorktreeTitle.renameAction(draft: draft, opened: opened,
                                                                                    openedIsFallback: source == .fallback, confirmed: confirmed) {
                                   store.rename(board, to: name)
                               }
                               renaming = nil
                           })
            .help(L("A free canvas of your own, outside any project: plan here and have agents set up projects and worktrees."))
            .contextMenu {
                Button(L("Rename")) { renaming = board }
                if source == .user { Button(L("Reset Name")) { store.rename(board, to: "") } }
            }
    }

    private func row(for worktree: Worktree, in project: Project) -> some View {
        let tag = WorktreeSelection(projectID: project.id, worktree: worktree)
        let source: WorktreeRow.Source = store.isNamedByUser(worktree) ? .user
            : store.agentTitles[worktree.path] != nil ? .agent : .fallback
        let host = worktree.host.flatMap { id in hosts.account.hosts.first { $0.id == id } }
        return WorktreeRow(name: store.displayName(of: worktree), source: source,
                           isMain: store.isMain(worktree, in: project), contents: contents(of: worktree),
                           host: worktree.host == nil ? nil : host?.name ?? "", isOffline: host?.online == false,
                           isSelected: selection == tag, isRenaming: renaming == worktree,
                           selectionSpace: selectionSpace,
                           onSelect: { if drag == nil { withAnimation(.snappy(duration: 0.3)) { selection = tag } } },
                           onStartRename: { if drag == nil { renaming = worktree } },
                           onRename: { draft, opened, confirmed in
                               if case .set(let name) = WorktreeTitle.renameAction(draft: draft, opened: opened,
                                                                                    openedIsFallback: source == .fallback, confirmed: confirmed) {
                                   store.rename(worktree, to: name)
                               }
                               renaming = nil
                           })
            .contextMenu {
                Button(L("Rename")) { renaming = worktree }
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

/// A project or worktree the user is dragging among its list (`keys`, as shown when the drag began).
/// Places are counted among the others: `target` is where it lands, before the item at that index;
/// the one it started in (`origin`) is its own place, which stays open.
struct ReorderDrag {
    let key: String
    let keys: [String]
    /// Where it was when the drag began, in the sidebar's space.
    let frame: CGRect
    /// Each item's height with the space after it.
    let heights: [String: CGFloat]
    var target: Int
    var isDropping = false

    init(key: String, keys: [String], frame: CGRect, heights: [String: CGFloat]) {
        self.key = key
        self.keys = keys
        self.frame = frame
        self.heights = heights
        target = keys.firstIndex(of: key) ?? 0
    }

    private var others: [String] { keys.filter { $0 != key } }
    private var height: CGFloat { heights[key] ?? 0 }
    private var origin: Int { keys.firstIndex(of: key) ?? 0 }

    /// Where the item at `index` among the others starts, with the dragged one out of the list.
    func top(_ index: Int) -> CGFloat { others.prefix(index).reduce(0) { $0 + (heights[$1] ?? 0) } }
    /// Where the dragged one started.
    var start: CGFloat { top(origin) }
    /// The open place's height before `key` (the dragged one's own place, nil: the end).
    func slot(before key: String?) -> CGFloat {
        if key == self.key { return target == origin ? height : 0 }
        return target != origin && (key.flatMap(others.firstIndex) ?? others.count) == target ? height : 0
    }
    var order: [String] {
        var order = others
        order.insert(key, at: target)
        return order
    }

    /// Lands past each neighbor the pointer (`y`, in the sidebar's space) has crossed: one above once
    /// it goes over that neighbor's middle, one below once it goes under it, as each is laid out
    /// before it moves. Into a taller neighbor it takes only half the dragged one's height, so a
    /// long project is passed without crossing all of it. A function of `y` alone, so it never
    /// flickers between two places.
    mutating func move(pointer y: CGFloat) {
        let y = y - (frame.minY - start)
        target = others.indices.filter { index in
            let neighbor = heights[others[index]] ?? 0, into = min(neighbor, height) / 2
            return y > (index < origin ? top(index) + neighbor - into : top(index) + height + into)
        }.count
    }
}

/// How far the dragged item follows the pointer.
@Observable private final class ReorderPointer {
    var offset: CGSize = .zero
}

/// Where each reorderable item is, by its key: its frame in the sidebar's space, and its height
/// with the space after it.
private final class ReorderFrames {
    var frames: [String: CGRect] = [:]
    var heights: [String: CGFloat] = [:]
    /// The open place a dragged item would land in.
    var placeholder: CGRect?
}

/// Whether a view is the floating copy of a dragged item, which must not measure itself in the list's place.
private extension EnvironmentValues {
    @Entry var isReorderFloating = false
}

/// Keeps an item's frame in the sidebar's space, except in the floating copy.
private struct ReorderMeasure: ViewModifier {
    @Environment(\.isReorderFloating) private var isFloating
    let action: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Sidebar.space)) } action: { if !isFloating { action($0) } }
    }
}

/// A press on a reorderable item, before it lifts; `id` tells one press from the next.
private struct ReorderHold: Equatable {
    let id = UUID()
    let key: String
    let keys: [String]
    var isCancelled = false
}

/// The dragged item lifted: larger, on a surface a step above the sidebar, back to its size as it lands.
private struct FloatingItem<Content: View>: View {
    let isDropping: Bool
    /// Where it was when the drag began, in the sidebar's space.
    let origin: CGPoint
    let pointer: ReorderPointer
    @ViewBuilder let content: Content
    @State private var isLifted = false

    var body: some View {
        content
            .background {
                Theme.surface.clipShape(.rect(cornerRadius: Theme.Radius.control, style: .continuous))
                    // Fades in as it lifts and out as it lands, on its own smooth spring (no bounce on opacity).
                    .opacity(isLifted && !isDropping ? 1 : 0)
                    .animation(.smooth(duration: 0.3), value: isLifted && !isDropping)
            }
            .environment(\.isReorderFloating, true)
            .scaleEffect(isDropping ? 1 : isLifted ? 1.15 : Sidebar.pressedScale)
            .allowsHitTesting(false)
            .offset(x: origin.x + pointer.offset.width, y: origin.y + pointer.offset.height)
            .onAppear { withAnimation(.bouncy(duration: 0.3)) { isLifted = true } }
    }
}

/// Where a dragged item will land: its shape, empty, opening from nothing.
private struct ReorderPlaceholder: View {
    let height: CGFloat
    let spacing: CGFloat

    var body: some View {
        Theme.surface
            .clipShape(.rect(cornerRadius: Theme.Radius.control, style: .continuous))
            // The origin's slot opens at once at lift (nothing may move), so its fill fades in instead.
            .opacity(height > 0 ? 1 : 0)
            .animation(.smooth(duration: 0.3), value: height > 0)
            .padding(.bottom, spacing)
            .frame(height: height, alignment: .top)
            .clipped()
            .accessibilityHidden(true)
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
                    if isHovered {
                        Image(systemName: "chevron.down")
                            .font(Theme.Font.caption.weight(.semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    } else if let count {
                        Text(count, format: .number)
                            .font(Theme.Font.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(isCollapsed ? L("Collapsed") : L("Expanded"))
            if let onAddWorktree, isHovered {
                SidebarIconButton(symbol: "plus", title: L("New Worktree…"), help: L("New Worktree…"), action: onAddWorktree)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 32)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
    }
}

/// A small icon button of the sidebar, on its own fill.
private struct SidebarIconButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Font.caption.weight(.bold))
                .foregroundStyle(isHovered ? Theme.ink : Theme.inkMuted)
                .frame(width: 22, height: 22)
                .background(isHovered ? Theme.surfaceDeep : Theme.surface, in: .rect(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { isHovered = inside } }
        .help(help)
        .accessibilityLabel(title)
    }
}

/// A project's mark: its initial on a small square tile, in a color that stays the same for the
/// same name.
struct ProjectTile: View {
    let name: String
    static let size: CGFloat = 20

    /// Blue and graphite fills, each with a text color that passes AA on it; never red, which means an error.
    private static let palette: [(fill: Color, ink: Color)] = [
        (Theme.accent, Theme.onAccent), (Theme.deep, Theme.onDeep), (Theme.accentTint, Theme.deep), (Theme.surfaceDeep, Theme.ink),
    ]

    /// Stable across launches, unlike `hashValue`.
    static func colorIndex(for name: String) -> Int {
        Int(name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(palette.count))
    }

    var body: some View {
        let colors = Self.palette[Self.colorIndex(for: name)]
        Text(name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•")
            .font(Theme.Font.label)
            .foregroundStyle(colors.ink)
            .frame(width: Self.size, height: Self.size)
            .background(colors.fill, in: .rect(cornerRadius: Theme.Radius.thumb / 1.5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A worktree: where it lives as a glyph, then its title, bold when it needs the user, with a small dot on the right
/// while something runs or waits. Double-click renames.
private struct WorktreeRow: View {
    enum Source { case user, agent, fallback }

    let name: String
    /// Who gave the title: the user's name locks agents out.
    let source: Source
    /// The project's own checkout: marked, so no title can pass for it.
    let isMain: Bool
    let contents: WorktreeContents
    /// The name of the host it lives on, when not this Mac (empty when unknown); nil on this Mac.
    var host: String?
    /// Its host isn't online: what is known of it shows, dimmed.
    var isOffline = false
    /// The user's own board: a top-level row with its own tile and fill, apart from the projects.
    var isBoard = false
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
    /// The floating copy of a dragged row leaves the selection's place to the row in the list.
    @Environment(\.isReorderFloating) private var isFloating

    /// Where the title starts, under the project's name.
    static let textInset: CGFloat = 8 + ProjectTile.size + 9

    private var status: CardStatus? { [contents.agents, contents.runners].compactMap { $0 }.max() }

    /// Running in the accent, waiting for the user in amber, crashed in red, idle faint.
    static func dotColor(_ status: CardStatus?) -> Color {
        switch status {
        case .running: Theme.accentText
        case .waiting: Theme.you
        case .crashed: Theme.danger
        case .stopped, nil: Theme.faint
        }
    }
    private var needsUser: Bool { status == .waiting || status == .crashed }

    var body: some View {
        HStack(spacing: 8) {
            if isBoard {
                Image(systemName: MyBoard.symbol)
                    .font(Theme.Font.caption.weight(.bold))
                    .foregroundStyle(Theme.onDeep)
                    .frame(width: ProjectTile.size, height: ProjectTile.size)
                    .background(Theme.deep, in: .rect(cornerRadius: Theme.Radius.thumb))
                    // The title lines up with the projects' names.
                    .padding(.trailing, 1)
                    .accessibilityHidden(true)
            } else {
                // Under the project's tile: the main checkout's own mark, else where it lives (a cloud
                // for a host, a computer for this Mac).
                Image(systemName: isMain ? "house" : host == nil ? "desktopcomputer" : isOffline ? "icloud.slash" : "icloud")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: ProjectTile.size, height: ProjectTile.size)
                    .padding(.trailing, 1)
                    .help(isMain ? WorktreeTitle.mainLabel : host.map { isOffline ? L("\($0) · offline") : $0 } ?? L("This Mac"))
                    .accessibilityLabel(isMain ? WorktreeTitle.mainLabel : host.map { isOffline ? L("\($0) · offline") : $0 } ?? L("This Mac"))
            }
            title
            Spacer(minLength: 0)
            if isMain && source != .fallback {
                Text(L("main"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkMuted)
            }
            Circle()
                .fill(Self.dotColor(status))
                .frame(width: 6, height: 6)
                .help(status?.label ?? "")
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: isBoard ? 40 : 34)
        .background { background }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onStartRename)
        // Simultaneous: a plain second tap gesture would wait out the double-click interval before selecting.
        .simultaneousGesture(TapGesture().onEnded(onSelect))
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
                .font(isBoard ? Theme.Font.heading : Theme.Font.body)
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
                .font(isBoard ? Theme.Font.heading : Theme.Font.body.weight(needsUser ? .bold : isSelected ? .medium : .regular))
                // Dimmed with the muted ink, which still passes AA, not with opacity.
                .foregroundStyle(isBoard ? Theme.deep : isOffline ? Theme.inkMuted : needsUser || isSelected ? Theme.ink : Theme.ink.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name)
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        if isBoard {
            // Always filled, apart from the projects: blue when open.
            shape.fill(isSelected ? Theme.accentSoft : isHovered ? Theme.surfaceDeep : Theme.surface)
        } else if isSelected && isFloating {
            // Its own fill: a matched one would be drawn where the row is in the list.
            shape.fill(Theme.accentSoft)
        } else if isSelected {
            shape.fill(Theme.accentSoft)
                .matchedGeometryEffect(id: "selection", in: selectionSpace)
        } else {
            shape.fill(isHovered ? Theme.surface : .clear)
        }
    }
}

