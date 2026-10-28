import AppKit
import SwiftUI

struct WorktreeSelection: Hashable {
    let projectID: Project.ID
    let worktree: Worktree
}

struct ContentView: View {
    let store: ProjectStore
    let agents: AgentStore
    let browsers: BrowserStore
    @State private var selection: WorktreeSelection?
    @State private var renaming: Worktree?
    @State private var boardController = BoardController()
    @State private var isSidebarVisible = true
    @State private var addProjectStep: AddProjectDialog.Step?
    /// Set in code per screen; not a user-facing toggle.
    var canvasMode: CanvasMode = .canvas

    private let sidebarWidth: CGFloat = 260

    // A hand-rolled split instead of NavigationSplitView: on macOS the native split snaps the
    // detail column to its final width when the sidebar expands, so content jumps. Animating a
    // plain frame width keeps both columns moving together in both directions.
    var body: some View {
        Group {
            if store.projects.isEmpty {
                // First run: no sidebar, just a quiet canvas with the ways to start.
                CanvasView(mode: .offCanvas) {
                    WelcomeView(onClone: { addProjectStep = .clone },
                                onCreate: { addProjectStep = .create },
                                onOpen: openFolder)
                }
            } else {
                board
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        #if BENCH
        .task { await runBenchScenario() }
        #endif
        .sheet(item: $addProjectStep) { step in
            AddProjectDialog(store: store, initialStep: step, onAdded: select)
        }
        .alert(L("Error"), isPresented: .constant(store.errorMessage != nil)) {
            Button(L("OK")) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var board: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(width: isSidebarVisible ? sidebarWidth : 0, alignment: .trailing)
                .clipped()
            Divider()
                .opacity(isSidebarVisible ? 1 : 0)
            Group {
                if selection == nil {
                    CanvasView(mode: canvasMode) { detail }
                } else {
                    detail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) { Label(L("Toggle Sidebar"), systemImage: "sidebar.left") }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: addProject) { Label(L("Add Project"), systemImage: "plus") }
                Button(action: store.reload) { Label(L("Refresh"), systemImage: "arrow.clockwise") }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
                ForEach(store.projects) { project in
                    Section(project.name) {
                        if let worktrees = store.worktrees[project.id] {
                            ForEach(worktrees) { worktree in
                                WorktreeRow(worktree: worktree, name: store.displayName(of: worktree),
                                            isRenaming: renaming == worktree,
                                            onRename: { name in
                                                store.rename(worktree, to: name)
                                                renaming = nil
                                            })
                                    .tag(WorktreeSelection(projectID: project.id, worktree: worktree))
                                    .contextMenu {
                                        Button(L("Rename")) { renaming = worktree }
                                    }
                            }
                        } else {
                            Label(L("Not a git repository"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(L("Remove Project"), role: .destructive) { store.removeProject(project) }
                    }
                }
            }
            .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            WorktreeCanvas(agents: agents, browsers: browsers, worktree: selection.worktree, board: boardController)
        } else {
            EmptyCanvas(
                symbol: "sidebar.left",
                title: L("Select a worktree"),
                message: L("Pick a worktree in the sidebar to open it on the canvas.")
            ) { EmptyView() }
        }
    }

    private func toggleSidebar() {
        withAnimation(.smooth(duration: 0.3)) { isSidebarVisible.toggle() }
    }

    private func addProject() {
        addProjectStep = .choose
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Add Project")
        guard panel.runModal() == .OK, let url = panel.url,
              let project = store.addProject(at: url) else { return }
        select(project)
    }

    private func select(_ project: Project) {
        if let worktree = store.worktrees[project.id]?.first {
            selection = WorktreeSelection(projectID: project.id, worktree: worktree)
        }
    }

    #if BENCH
    /// Shows the scenario's worktree full screen, then switches to the other one if asked.
    private func runBenchScenario() async {
        guard let worktree = BenchScenario.worktree else { return }
        try? await Task.sleep(for: .seconds(1))
        BenchScenario.arrangeWindow()
        isSidebarVisible = false
        func show(_ path: String) {
            for project in store.projects {
                if let worktree = store.worktrees[project.id]?.first(where: { $0.path == path }) {
                    selection = WorktreeSelection(projectID: project.id, worktree: worktree)
                }
            }
        }
        show(worktree)
        if let other = BenchScenario.switchTo, let after = BenchScenario.switchAfter {
            try? await Task.sleep(for: .seconds(after))
            show(other)
        }
    }
    #endif
}

/// A worktree in the sidebar: its name (alias or folder) first, the branch it is on underneath.
private struct WorktreeRow: View {
    let worktree: Worktree
    let name: String
    let isRenaming: Bool
    let onRename: (String) -> Void
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField(L("Name"), text: $draft, prompt: Text(worktree.name))
                        .textFieldStyle(.plain)
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
                        .lineLimit(1)
                }
                Text(worktree.branch ?? L("Detached HEAD"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: worktree.branch == nil ? "questionmark.folder" : "arrow.triangle.branch")
        }
    }
}
