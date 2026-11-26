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
    let simulators: SimulatorStore
    let fileTrees: FileTreeStore
    @State private var selection: WorktreeSelection?
    @State private var renaming: Worktree?
    @State private var boardController = BoardController()
    @State private var isSidebarVisible = true
    @State private var addProjectStep: AddProjectDialog.Step?
    @State private var isNeedsYouOpen = false
    @State private var isSearchOpen = false
    @State private var addingWorktreeTo: Project?
    /// Set in code per screen; not a user-facing toggle.
    var canvasMode: CanvasMode = .canvas

    /// This Mac's store: what isn't about one worktree reads it.
    private var agents: AgentStore { hosts.local }
    /// The store with a removal an agent asked for that waits for the user.
    private var removalAsked: AgentStore? { hosts.connected.first { !$0.removalRequests.isEmpty } }

    var body: some View {
        Group {
            if store.projects.isEmpty {
                // First run: no sidebar, just a quiet canvas with the ways to start.
                CanvasView(mode: .offCanvas) {
                    WelcomeView(onClone: { addProjectStep = .clone },
                                onCreate: { addProjectStep = .create },
                                onOpen: openFolder)
                }
                // No sidebar group to sit beside yet: the hosts are still reached from here.
                .toolbar {
                    if #available(macOS 26, *) {
                        ToolbarItem(placement: .navigation) { HostsControl(hosts: hosts) }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .navigation) { HostsControl(hosts: hosts) }
                    }
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
        .overlay {
            if isSearchOpen {
                SearchPalette(entries: SearchEntry.all(projects: store, hosts: hosts, selection: selection),
                              worktree: selection?.worktree.path, isOpen: $isSearchOpen, onOpen: open)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .toolbar {
            // Pushes the search and the queue to the trailing edge.
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            if !boardController.isZen && !store.projects.isEmpty {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .automatic) { searchButton }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .automatic) { searchButton }
                }
            }
            if #available(macOS 26, *) {
                // The strip is its own shape: no toolbar glass around it.
                ToolbarItem(placement: .automatic) { NeedsYouButton(hosts: hosts, projects: store, isOpen: $isNeedsYouOpen) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) { NeedsYouButton(hosts: hosts, projects: store, isOpen: $isNeedsYouOpen) }
            }
            // With projects, the organizations and the account are in the sidebar; without, no
            // sidebar shows, so a new organization's first run can still leave it from here.
            if !boardController.isZen && store.projects.isEmpty {
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
            if let path = DebugShow.worktree {
                #if DEBUG
                // A fresh dev home has no projects yet: the shown worktree's folder becomes one.
                if !store.projects.contains(where: { $0.path == path }), FileManager.default.fileExists(atPath: path + "/.git") {
                    store.addProject(at: URL(fileURLWithPath: path))
                }
                #endif
                OpenWorktree.set(path, in: store.organizationID)
            }
            // The account is the usual way in: asked for once per launch, and the board works without it.
            if hosts.account.account == nil, !hosts.account.isSigningIn, ProcessInfo.processInfo.environment["AGENTBOARD_BACKGROUND"] == nil || DebugShow.items.contains("sign-in") {
                hosts.account.signIn()
            }
            if DebugShow.items.contains("vault-question") { hosts.showSample() }
            if DebugShow.items.contains("search") { isSearchOpen = true }
            if DebugShow.items.contains("removal-dialog") { agents.showSampleRemoval() }
            if let path = DebugShow.worktree, !DebugShow.items.isDisjoint(with: ["image-marks", "image-marks-agent"]) {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await agents.showSampleMarks(in: path, agent: DebugShow.items.contains("image-marks-agent"))
                }
            }
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
        // Worktrees listed after a switch or from a host: one that was open is restored then.
        .onChange(of: store.worktrees) { restoreSelection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dismissAttentionOnScreen()
        }
        #if BENCH
        .task { await runBenchScenario() }
        #endif
        .sheet(isPresented: Binding(get: { hosts.account.isSigningIn }, set: { if !$0 { hosts.account.cancelSignIn() } })) {
            SignInDialog(account: hosts.account)
        }
        .sheet(item: Binding(get: { removalAsked?.removalRequests.first }, set: { if $0 == nil { removalAsked?.answerRemoval(false) } })) { request in
            RemovalDialog(request: request) { removalAsked?.answerRemoval($0) }
        }
        .sheet(isPresented: Binding(get: { hosts.vaultQuestion }, set: { if !$0 { hosts.answerVault(false) } })) {
            VaultQuestionDialog(hosts: hosts)
        }
        .sheet(isPresented: Binding(get: { hosts.editingHost != nil }, set: { if !$0 { hosts.editingHost = nil } })) {
            if let editing = hosts.editingHost { HostDialog(hosts: hosts, editing: editing) }
        }
        .sheet(item: $addingWorktreeTo) { project in
            NewWorktreeDialog(store: store, project: project, hosts: hosts) { worktree in
                selection = WorktreeSelection(projectID: project.id, worktree: worktree)
            }
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
            Sidebar(store: store, hosts: hosts, browsers: browsers, selection: $selection, renaming: $renaming, board: boardController, onAddProject: addProject)
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
        // The sidebar's toggle has no button in the top bar: only its shortcut.
        .background {
            if !boardController.isZen {
                Button(L("Toggle Sidebar"), action: toggleSidebar)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .toolbar {
            // Where the canvas is: the project, then the worktree. No glass behind it.
            if !boardController.isZen {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .navigation) { breadcrumb }.sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .navigation) { addProjectButton }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { breadcrumb }
                    ToolbarItem(placement: .navigation) { addProjectButton }
                }
            }
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

    /// The selected worktree's project in bold, then the worktree.
    private var breadcrumb: some View {
        let place = selection.map { store.place(ofPath: $0.worktree.path) }
        return HStack(spacing: 8) {
            if let project = place?.project {
                Text(verbatim: project)
                    .font(Theme.Font.heading.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text(verbatim: "/")
                    .font(Theme.Font.heading.weight(.regular))
                    .foregroundStyle(Theme.faint)
            }
            if let place {
                Text(verbatim: place.worktree)
                    .font(Theme.Font.heading.weight(.regular))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .lineLimit(1)
        .padding(.leading, 8)
        .animation(.snappy(duration: 0.25), value: place)
    }

    private var addProjectButton: some View {
        Button(action: addProject) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 26, height: 26)
                .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Add Project"))
        .help(L("Clone, create, or open a project."))
    }

    /// Opens the search palette.
    private var searchButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { isSearchOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                Text(L("Search"))
                    .font(Theme.Font.heading.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                KeyChip(text: "⌘K")
            }
            .padding(.leading, 12)
            .padding(.trailing, 7)
            .frame(height: 32)
            .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help(L("Finds agents, cards, worktrees and actions."))
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
            WorktreeCanvas(agents: agents, browsers: browsers, simulators: simulators, fileTrees: fileTrees, worktree: selection.worktree, board: boardController,
                           title: selection.projectID == nil ? store.displayName(of: selection.worktree) : nil,
                           database: store.database,
                           // The user's own board keeps its templates under its own folder.
                           project: store.projects.first { $0.id == selection.projectID }?.path ?? selection.worktree.path,
                           place: store.place(ofPath: selection.worktree.path))
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

    /// Opens what the search palette picked. `stay` (⌘↵) reveals a request's card on the canvas
    /// instead of opening the queue.
    private func open(_ entry: SearchEntry, stay: Bool) {
        switch entry.target {
        case .queue(let id):
            if stay, let record = hosts.store(of: id)?.record(id) { reveal(record) }
            else { withAnimation(.snappy(duration: 0.35)) { isNeedsYouOpen = true } }
        case .card(let id, let worktree, let isRecord):
            if isRecord, let record = hosts.store(of: id)?.record(id) { reveal(record) }
            // shortcut: only agents and runners can be framed (BoardController.reveal); other cards open their worktree.
            else { select(path: worktree) }
        case .worktree(let path):
            select(path: path)
        case .action(let action):
            perform(action)
        }
    }

    private func perform(_ action: SearchEntry.Action) {
        switch action {
        case .newAgent(let id): if let provider = AgentCatalog.provider(id: id) { boardController.add(provider) }
        case .newWorktree(let id): addingWorktreeTo = store.projects.first { $0.id == id }
        case .addProject: addProject()
        case .reload:
            store.reload()
            store.refreshHostWorktrees(probing: true)
        case .zen: boardController.isZen.toggle()
        case .caffeinate: Caffeinate.shared.isOn.toggle()
        case .sidebar: toggleSidebar()
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


/// No title in the top bar; in zen mode, no top bar background either.
private struct WindowChrome: ViewModifier {
    let isZen: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(Theme.window, for: .windowToolbar)
                .toolbarBackgroundVisibility(isZen ? .hidden : .visible, for: .windowToolbar)
                .toolbarColorScheme(.dark, for: .windowToolbar)
        } else {
            content.toolbarBackground(isZen ? .hidden : .automatic, for: .windowToolbar)
        }
    }
}
