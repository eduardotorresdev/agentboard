import AgentRuntime
import AppKit
import Orchestration
import SwiftUI

struct WorktreeSelection: Hashable {
    /// nil for the user's own board, which no project holds.
    let projectID: Project.ID?
    let worktree: Worktree
}

/// The worktree open on the canvas in each organization, kept per data folder so another
/// instance keeps its own.
enum OpenWorktree {
    private static func key(_ organization: UUID) -> String {
        "openWorktree:" + DataFolder.url.path + ":" + organization.uuidString
    }
    /// Before organizations kept their own.
    private static var legacyKey: String { "openWorktree:" + DataFolder.url.path }

    static func path(in organization: UUID) -> String? {
        AppDefaults.shared.string(forKey: key(organization)) ?? AppDefaults.shared.string(forKey: legacyKey)
    }

    static func set(_ path: String, in organization: UUID) {
        AppDefaults.shared.set(path, forKey: key(organization))
    }
}

struct ContentView: View {
    let store: ProjectStore
    let hosts: HostStores
    let browsers: BrowserStore
    let fileTrees: FileTreeStore
    @State private var selection: WorktreeSelection?
    @State private var renaming: Worktree?
    @State private var boardController = BoardController()
    @State private var isSidebarVisible = true
    @State private var addProjectStep: AddProjectDialog.Step?
    @State private var isNeedsYouOpen = false
    /// Set in code per screen; not a user-facing toggle.
    var canvasMode: CanvasMode = .canvas

    /// This Mac's store: what isn't about one worktree reads it.
    private var agents: AgentStore { hosts.local }

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
        .modifier(WindowChrome(isZen: boardController.isZen))
        // On every screen, the first run of a new organization included.
        .overlay {
            if isNeedsYouOpen {
                NeedsYouDeck(hosts: hosts, projects: store, isOpen: $isNeedsYouOpen, onReveal: reveal)
                    .transition(.opacity)
            }
        }
        .toolbar {
            if #available(macOS 26, *) {
                // The button is its own capsule: no toolbar glass around it.
                ToolbarItem(placement: .principal) { NeedsYouButton(hosts: hosts, isOpen: $isNeedsYouOpen) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { NeedsYouButton(hosts: hosts, isOpen: $isNeedsYouOpen) }
            }
            if !boardController.isZen {
                ToolbarItem(placement: .primaryAction) { AccountControl(hosts: hosts) }
                ToolbarItem(placement: .primaryAction) { OrganizationSwitcher(store: store, agents: agents) }
            }
        }
        .onChange(of: store.organizationID, initial: true) { old, id in
            hosts.organizationID = id
            if old != id {
                selection = nil
                withAnimation(.snappy(duration: 0.3)) { isNeedsYouOpen = false }
                // Back where the developer left this organization.
                restoreSelection()
            }
        }
        .onAppear {
            if let path = DebugShow.worktree { OpenWorktree.set(path, in: store.organizationID) }
            // The account is the usual way in: asked for once per launch, and the board works without it.
            if hosts.account.account == nil, !hosts.account.isSigningIn, ProcessInfo.processInfo.environment["AGENTBOARD_BACKGROUND"] == nil || DebugShow.items.contains("sign-in") {
                hosts.account.signIn()
            }
            if DebugShow.items.contains("vault-question") { hosts.showSample() }
            restoreSelection()
        }
        .onChange(of: selection) { _, selection in
            if let path = selection?.worktree.path { OpenWorktree.set(path, in: store.organizationID) }
            // Connects to the worktree's host, the first time one of its worktrees opens.
            hosts.store(for: selection?.worktree.host)
            dismissAttentionOnScreen()
        }
        .onChange(of: hosts.attention) { dismissAttentionOnScreen() }
        // The hosts are known a moment after launch, and what they hold later still: a worktree
        // of one that was open is restored then.
        .onChange(of: hosts.account.hosts, initial: true) {
            store.refreshHostWorktrees()
            restoreSelection()
        }
        .onChange(of: store.hostWorktrees) { restoreSelection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dismissAttentionOnScreen()
        }
        #if BENCH
        .task { await runBenchScenario() }
        #endif
        .sheet(isPresented: Binding(get: { hosts.account.isSigningIn }, set: { if !$0 { hosts.account.cancelSignIn() } })) {
            SignInDialog(account: hosts.account)
        }
        .sheet(isPresented: Binding(get: { hosts.vaultQuestion }, set: { if !$0 { hosts.answerVault(false) } })) {
            VaultQuestionDialog(hosts: hosts)
        }
        .sheet(isPresented: Binding(get: { hosts.editingServers != nil }, set: { if !$0 { hosts.editingServers = nil } })) {
            if let host = hosts.editingServers { HostServersSheet(hosts: hosts, host: host) }
        }
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
            Sidebar(store: store, hosts: hosts, browsers: browsers, selection: $selection, renaming: $renaming)
                // Past its width, so the shadow leaves with it.
                // The Needs you screen takes the whole window: the sidebar steps aside for it.
                .offset(x: showsSidebar && !isNeedsYouOpen ? 0 : -(Sidebar.width + 32))
                .animation(.snappy(duration: 0.32), value: isNeedsYouOpen)
                .animation(.snappy(duration: 0.32), value: boardController.isZen)
                .allowsHitTesting(showsSidebar)
                .accessibilityHidden(!showsSidebar)
        }
        .onChange(of: showsSidebar, initial: true) { _, visible in
            boardController.leadingInset = visible ? sidebarInset : 0
        }
        .toolbar {
            // The sidebar and the project actions, one group beside the title.
            if !boardController.isZen { ToolbarItemGroup(placement: .navigation) {
                Button(action: toggleSidebar) { Label(L("Toggle Sidebar"), systemImage: "sidebar.left") }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(action: addProject) { Label(L("Add Project"), systemImage: "plus") }
                    .help(L("Clone, create, or open a project."))
                Button {
                    store.reload()
                    store.refreshHostWorktrees(probing: true)
                } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .help(L("Reloads the projects and their worktrees."))
            } }
            // A build of the checkout (`./run`) says so, to tell it apart from the installed app.
            if Bundle.main.bundleURL.pathExtension != "app" {
                if #available(macOS 26, *) {
                    // Plain text beside the glass group, not inside it.
                    ToolbarItem(placement: .navigation) { devLabel }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { devLabel }
                }
            }
        }
    }

    private var devLabel: some View {
        Text(verbatim: "dev")
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.inkMuted)
    }

    /// Zen mode hides the sidebar without forgetting whether it was open.
    private var showsSidebar: Bool { isSidebarVisible && !boardController.isZen }

    /// How much of the canvas's leading edge the sidebar covers.
    private var sidebarInset: CGFloat { Sidebar.width }

    @ViewBuilder
    private var detail: some View {
        if let selection, let agents = hosts[selection.worktree.host] {
            WorktreeCanvas(agents: agents, browsers: browsers, fileTrees: fileTrees, worktree: selection.worktree, board: boardController,
                           title: selection.projectID == nil ? store.displayName(of: selection.worktree) : nil)
                // Another host's cards are another store's: the board is built again for it.
                .id(selection.worktree.host)
        } else if selection != nil {
            SkyCanvas()
        } else {
            SkyBlobEmptyState(title: L("Select a worktree"),
                              message: L("Pick a worktree in the sidebar to open it on the canvas."))
            // Centered on the canvas the sidebar leaves uncovered.
            .padding(.leading, showsSidebar ? sidebarInset : 0)
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

    /// Reopens the worktree last open in this organization, as after a rebuild or a switch.
    private func restoreSelection() {
        guard selection == nil, let path = OpenWorktree.path(in: store.organizationID) else { return }
        select(path: path)
    }

    /// Opens the shown organization's worktree at `path`, or its own board.
    private func select(path: String) {
        if path == store.board.path { selection = WorktreeSelection(projectID: nil, worktree: store.board) }
        for project in store.projects {
            if let worktree = store.worktrees[project.id]?.first(where: { $0.path == path }) {
                selection = WorktreeSelection(projectID: project.id, worktree: worktree)
            }
        }
    }

    /// An agent in the worktree the developer is looking at doesn't need to call them: they see it.
    private func dismissAttentionOnScreen() {
        guard NSApp.isActive, !isNeedsYouOpen, let worktree = selection?.worktree, let agents = hosts[worktree.host] else { return }
        let path = worktree.path
        for request in agents.attention where agents.record(request.id)?.worktree == path {
            agents.dismissAttention(request.id)
        }
    }

    /// Opens the agent's worktree and frames its card, in focus.
    private func reveal(_ record: AgentRecord) {
        guard store.organizationID == record.organizationID else {
            // Switching organizations clears the selection: select after it has.
            store.selectOrganization(record.organizationID)
            DispatchQueue.main.async { reveal(record) }
            return
        }
        select(path: record.worktree)
        boardController.reveal(record.id)
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


/// No title in the top bar; in zen mode, no top bar background either.
private struct WindowChrome: ViewModifier {
    let isZen: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(Color.white, for: .windowToolbar)
                .toolbarBackgroundVisibility(isZen ? .hidden : .visible, for: .windowToolbar)
                .toolbarColorScheme(.light, for: .windowToolbar)
        } else {
            content.toolbarBackground(isZen ? .hidden : .automatic, for: .windowToolbar)
        }
    }
}
