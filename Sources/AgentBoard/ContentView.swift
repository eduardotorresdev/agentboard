import AgentRuntime
import AppKit
import SwiftUI

struct WorktreeSelection: Hashable {
    let projectID: Project.ID
    let worktree: Worktree
}

/// The worktree open on the canvas, kept per data folder so another instance keeps its own.
enum OpenWorktree {
    private static var key: String { "openWorktree:" + DataFolder.url.path }

    static var path: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
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
    @State private var isNeedsYouOpen = false
    /// Set in code per screen; not a user-facing toggle.
    var canvasMode: CanvasMode = .canvas

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
        // On every screen, the first run of a new organization included.
        .overlay {
            if isNeedsYouOpen {
                NeedsYouDeck(agents: agents, projects: store, isOpen: $isNeedsYouOpen)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { NeedsYouButton(agents: agents, isOpen: $isNeedsYouOpen) }
            ToolbarItem(placement: .primaryAction) { OrganizationSwitcher(store: store) }
            // The organizations and the project actions sit in groups of their own.
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if !store.projects.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: addProject) { Label(L("Add Project"), systemImage: "plus") }
                    Button(action: store.reload) { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                }
            }
        }
        .onChange(of: store.organizationID, initial: true) { old, id in
            agents.organizationID = id
            if old != id { selection = nil }
        }
        .onAppear(perform: restoreSelection)
        .onChange(of: selection) { _, selection in OpenWorktree.path = selection?.worktree.path }
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

    /// The canvas spans the whole window; the sidebar floats over its leading edge.
    private var board: some View {
        ZStack(alignment: .leading) {
            Group {
                if selection == nil {
                    CanvasView(mode: canvasMode) { detail }
                } else {
                    detail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Always in the tree and slid off-screen when hidden: removing it from the ZStack drops
            // it behind the board while it leaves, so the slide never shows.
            Sidebar(store: store, agents: agents, browsers: browsers, selection: $selection, renaming: $renaming)
                // Past its width, so the shadow leaves with it.
                // The Needs you screen takes the whole window: the sidebar steps aside for it.
                .offset(x: isSidebarVisible && !isNeedsYouOpen ? 0 : -(Sidebar.width + 32))
                .animation(.snappy(duration: 0.32), value: isNeedsYouOpen)
                .allowsHitTesting(isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
        }
        .onChange(of: isSidebarVisible, initial: true) { _, visible in
            boardController.leadingInset = visible ? sidebarInset : 0
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) { Label(L("Toggle Sidebar"), systemImage: "sidebar.left") }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }

    /// How much of the canvas's leading edge the sidebar covers.
    private var sidebarInset: CGFloat { Sidebar.width }

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
            // Centered on the canvas the sidebar leaves uncovered.
            .padding(.leading, isSidebarVisible ? sidebarInset : 0)
        }
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.32)) { isSidebarVisible.toggle() }
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

    /// Reopens the worktree that was open when the board last ran, as after a rebuild.
    private func restoreSelection() {
        guard selection == nil, let path = OpenWorktree.path else { return }
        for project in store.projects {
            if let worktree = store.worktrees[project.id]?.first(where: { $0.path == path }) {
                selection = WorktreeSelection(projectID: project.id, worktree: worktree)
            }
        }
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
