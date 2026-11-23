import AgentRuntime
import SwiftUI

@main
struct PhoneApp: App {
    @State private var account = Account()

    var body: some Scene {
        WindowGroup {
            Group {
                if account.token == nil { SignInView(account: account) } else { BrowseView(account: account) }
            }
            .preferredColorScheme(.light)
            #if DEBUG
            .onAppear { account.logKey() }
            #endif
            .tint(Theme.accent)
        }
    }
}

/// GitHub's device flow: a code here, confirmed on any device.
#if DEBUG
/// Launch arguments that walk the app to a screen by themselves (`-name value`). Debug builds only.
enum DebugLaunch {
    static func value(_ name: String) -> String? { UserDefaults.standard.string(forKey: name) }
}
#endif

struct SignInView: View {
    let account: Account
    @State private var code: AccountServer.DeviceCode?
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            // The whole scene, clouds included, stays inside the margin.
            // The leftmost cloud starts 6 points into the frame: its edge lines up with the text.
            SkyBlob().padding(.leading, -6)
            Text("Sign in").font(Theme.Font.headline).tracking(Theme.Font.headlineTracking).foregroundStyle(Theme.ink)
            if let code {
                Text("Enter this code on GitHub, from any device.").font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                Text(code.user_code).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Theme.deep)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("userCode")
                Button("Open GitHub") { if let url = URL(string: code.verification_uri) { openURL(url) } }
                    .buttonStyle(SolidButton())
                Text("Waiting for confirmation…").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            } else {
                Text("Use the GitHub account your hosts are signed in to.").font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                Button("Sign in with GitHub") { Task { await start() } }.buttonStyle(SolidButton())
            }
            if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.danger) }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        #if DEBUG
        // `-autoSignIn YES`: asks for a device code at launch.
        .task { if UserDefaults.standard.bool(forKey: "autoSignIn"), code == nil { await start() } }
        #endif
    }

    private func start() async {
        error = nil
        do {
            let code = try await account.server.startLogin()
            withAnimation(.smooth) { self.code = code }
            var interval = UInt64(max(code.interval, 1))
            while true {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                switch try await account.server.poll(code.device_code) {
                case .pending: continue
                case .slowDown: interval += 5
                case .token(let token): return account.signedIn(token)
                case .failed(let why):
                    withAnimation(.smooth) { self.code = nil }
                    error = why == "expired" ? "The code expired. Try again." : "Sign-in was not confirmed."
                    return
                }
            }
        } catch {
            self.code = nil
            self.error = error.localizedDescription
        }
    }
}

/// This phone's key, for `agentboard trust` on a host.
struct Fingerprint: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("THIS PHONE'S KEY").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.inkMuted)
            Text(account.fingerprint).font(Theme.Font.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                .accessibilityIdentifier("fingerprint")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// The account's hosts and their channels, shared by every screen.
@MainActor @Observable final class Hosts {
    private(set) var list: [Host] = []
    private(set) var links: [String: HostLink] = [:]
    var error: String?
    var loaded = false

    func link(_ host: Host) -> HostLink {
        if let link = links[host.id.lowercased()] { return link }
        let link = HostLink(host: host)
        links[host.id.lowercased()] = link
        return link
    }

    func link(id: String) -> HostLink? { links[id.lowercased()] }

    /// Every host on the account, the online ones connecting.
    func load(account: Account) async {
        do {
            let hosts = try await account.server.hosts()
            #if DEBUG
            DebugTerm.log("hosts: 200, \(hosts.count) hosts, \(hosts.filter(\.online).count) online")
            #endif
            withAnimation(.smooth) { list = hosts.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }; error = nil }
            for host in hosts where host.online { link(host).connect(account: account) }
        } catch let failure as AccountServer.ServerError where failure.status == 401 {
            #if DEBUG
            DebugTerm.log("hosts: 401")
            #endif
            account.signOut()
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// How many agents in a worktree wait for the user: in their terminal, or on a decision (as
    /// the Mac's Needs you counts them).
    func waiting(in worktree: Worktree) -> Int {
        guard let link = link(id: worktree.host) else { return 0 }
        let agents = Set(link.attention.map(\.id) + link.decisions.filter { $0.state != .closed }.map(\.agent))
        return link.cards.filter { agents.contains($0.id) && $0.worktree == worktree.path }.count
    }

    /// Every agent waiting for the user now, on any host: in its terminal or on a decision.
    var waitingAgents: [(link: HostLink, card: Card)] {
        links.values.flatMap { link in
            let ids = Set(link.attention.map(\.id) + link.decisions.filter { $0.state != .closed }.map(\.agent))
            return link.cards.filter { ids.contains($0.id) }.map { (link: link, card: $0) }
        }
    }

    /// A link's phase, as the browsing screens see it.
    func phase(_ link: HostLink?) -> HostLink.Phase? {
        #if DEBUG
        // `-forceHostState pending|failed`: shows every host so, for screenshots of those rows.
        switch DebugLaunch.value("forceHostState") {
        case "pending": return .pending(trusted: 0)
        case "failed": return .failed("Forced")
        case "offline": return nil
        default: break
        }
        #endif
        return link?.phase
    }

    /// What a host's worktrees can do right now, in a few words.
    func state(_ host: Host) -> (text: String, color: Color) {
        switch phase(links[host.id.lowercased()]) {
        case .connected: ("Online", Theme.accent)
        case .pending: ("Waiting for trust", Theme.deep)
        case .failed: ("Unreachable", Theme.inkMuted)
        case .connecting: host.online ? ("Connecting", Theme.inkMuted) : ("Offline", Theme.inkMuted)
        case nil: ("Offline", Theme.inkMuted)
        }
    }
}

enum Route: Hashable { case hosts }

/// The in-app banner for an agent that starts waiting for the user while they look elsewhere.
enum WaitingBanner {
    /// The terminal on screen, if any: its agent waiting needs no banner.
    @MainActor static var viewing: UUID?
    /// The board on screen, if any: its agents' balloons already show there.
    @MainActor static var board: Worktree?

    /// The agents that started waiting since `before`, but those on screen (`shown`).
    static func arrived(before: Set<UUID>, now: Set<UUID>, shown: Set<UUID>) -> [UUID] {
        now.subtracting(before).subtracting(shown).sorted { $0.uuidString < $1.uuidString }
    }

    /// Of `waiting`, the agents the user already sees: the open terminal's, and every one on the open board.
    @MainActor static func shown(_ waiting: [(link: HostLink, card: Card)]) -> Set<UUID> {
        Set(waiting.filter { $0.card.id == viewing || onBoard(card: $0.card.worktree, host: $0.link.host.id, board) }.map(\.card.id))
    }

    /// Whether a card in folder `card` on `host` belongs to `board`.
    static func onBoard(card: String, host: String, _ board: Worktree?) -> Bool {
        guard let board else { return false }
        return board.path == card && board.host.lowercased() == host.lowercased()
    }
}

/// The root, as the Mac's sidebar: an organization, its projects, each project's worktrees from
/// any host.
struct BrowseView: View {
    let account: Account
    @State private var hosts = Hosts()
    @State private var groups: [OrganizationGroup] = []
    @State private var selected: String?
    @State private var path = NavigationPath()
    @State private var banner: (card: Card, link: HostLink, more: Int)?
    @Environment(\.scenePhase) private var scenePhase

    private var current: OrganizationGroup? { groups.first { $0.id == selected } ?? groups.first }
    /// Changes whenever a host connects, drops or is asked to trust.
    private var phases: String { hosts.links.values.map { "\($0.host.id)\($0.phase)" }.sorted().joined() }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // As the Mac's bar: every organization's avatar, even when there is only one.
                    if !groups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(groups) { group in
                                    let on = group.id == current?.id
                                    Button { withAnimation(.snappy) { selected = group.id } } label: {
                                        HStack(spacing: 8) {
                                            Avatar(organization: group.organization, size: 28)
                                            Text(group.organization.name).font(Theme.Font.label).foregroundStyle(on ? Theme.deep : Theme.ink)
                                        }
                                        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                                        .background(on ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    if let current {
                        Text("PROJECTS").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.inkMuted)
                        ForEach(current.projects) { project in
                            let waiting = project.worktrees.reduce(0) { $0 + hosts.waiting(in: $1) }
                            NavigationLink(value: project) {
                                ListRow(title: project.name, detail: project.worktrees.count == 1 ? "1 worktree" : "\(project.worktrees.count) worktrees",
                                        state: waiting == 0 ? nil : ("\(waiting) waiting for you", Theme.deep))
                            }
                        }
                        if current.projects.isEmpty {
                            Text("No worktrees in this organization on your hosts yet.").font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                        }
                    } else if hosts.loaded {
                        Text(hosts.list.isEmpty ? "No hosts on this account yet." : "No projects on your hosts yet.")
                            .font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                    if let error = hosts.error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.danger) }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            // No large title: the selected organization chip already says where you are.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.hosts) { Image(systemName: "server.rack") }.accessibilityLabel("Hosts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", role: .destructive) { account.signOut() }
                    } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel("Account")
                }
            }
            .refreshable { await reload() }
            // Back from the background: channels that died while the app slept open again.
            .onChange(of: scenePhase) { _, phase in if phase == .active { hosts.links.values.forEach { $0.resume() } } }
            .task { await reload() }
            .task(id: phases) { await browse() }
            .navigationDestination(for: Route.self) { _ in HostsView(account: account, hosts: hosts) }
            .navigationDestination(for: OrganizationGroup.Project.self) { ProjectView(project: $0, hosts: hosts) }
            .navigationDestination(for: Host.self) { host in WorktreesView(account: account, link: hosts.link(host), path: $path) }
            .navigationDestination(for: Worktree.self) { worktree in
                if let link = hosts.link(id: worktree.host) { CanvasView(link: link, worktree: worktree) }
            }
        }
        .onChange(of: Set(hosts.waitingAgents.map(\.card.id))) { before, now in
            let arrived = WaitingBanner.arrived(before: before, now: now, shown: WaitingBanner.shown(hosts.waitingAgents))
            guard let first = arrived.first, let found = hosts.waitingAgents.first(where: { $0.card.id == first }) else { return }
            withAnimation(.snappy) { banner = (found.card, found.link, arrived.count - 1) }
            #if DEBUG
            DebugTerm.log("banner: \(found.card.name), board open: \(WaitingBanner.board?.path ?? "none")")
            #endif
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if banner?.card.id == first { withAnimation(.snappy) { banner = nil } }
            }
        }
        // A banner shown before its board opened goes once the board is on screen.
        .onChange(of: path.count) {
            Task { @MainActor in
                if let shown = banner, WaitingBanner.shown(hosts.waitingAgents).contains(shown.card.id) { withAnimation(.snappy) { banner = nil } }
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTerm.leaveBoard)) { _ in path = NavigationPath() }
        #endif
        .overlay(alignment: .top) {
            if let banner {
                Button {
                    path.append(Worktree(path: banner.card.worktree, host: banner.link.host.id.lowercased()))
                    withAnimation(.snappy) { self.banner = nil }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill").font(Theme.Font.label)
                        VStack(alignment: .leading, spacing: 2) {
                            let asks = banner.link.attention.contains { $0.id == banner.card.id && !($0.questions ?? []).isEmpty }
                            Text(asks ? "\(banner.card.name) has a question for you" : "\(banner.card.name) is waiting for you").font(Theme.Font.heading)
                            Text(banner.more == 0 ? "Tap to open its board." : "And \(banner.more) more. Tap to open its board.")
                                .font(Theme.Font.caption)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(14)
                    .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("waitingBanner")
            }
        }
    }

    private func reload() async {
        await hosts.load(account: account)
        await browse()
        #if DEBUG
        // `-openHost <id>` / `-openProject <name>`: straight there, for screenshots nobody taps through.
        if path.isEmpty, let id = DebugLaunch.value("openHost"), let host = hosts.list.first(where: { $0.id.lowercased() == id.lowercased() }) {
            path.append(host)
        }
        #endif
    }

    private func browse() async {
        let catalog: any CatalogSource = AccountCatalog(server: account.server)
        let found = OrganizationGroup.group(await catalog.browse(hosts.list.map(hosts.link)))
        withAnimation(.smooth) { groups = found }
        #if DEBUG
        if let name = DebugLaunch.value("openProject"), let project = found.flatMap(\.projects).first(where: { $0.name == name }) {
            if path.isEmpty { path.append(project) }
            // `-openProjectWorktree YES`: on into its first worktree once its host is connected.
            if path.count == 1, UserDefaults.standard.bool(forKey: "openProjectWorktree"), let worktree = project.worktrees.first,
               hosts.link(id: worktree.host)?.phase == .connected {
                path.append(worktree)
            }
        }
        #endif
    }
}

/// An organization's avatar: its initial on its palette color, as on the Mac.
struct Avatar: View {
    let organization: Organization
    let size: CGFloat
    /// The Mac's palette (OrganizationAvatar); white initials pass AA on each.
    static let palette = [Theme.accent, Theme.deep, Theme.ink, Theme.inkMuted]

    var body: some View {
        if let data = organization.image, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(.circle)
        } else {
            Text(organization.name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .frame(width: size, height: size)
                .background(Self.palette[abs(organization.color) % Self.palette.count], in: .circle)
        }
    }
}

/// A project's worktrees, from every host, each with its host's name and state.
struct ProjectView: View {
    let project: OrganizationGroup.Project
    let hosts: Hosts

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("WORKTREES").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.inkMuted)
                ForEach(project.worktrees) { worktree in
                    let link = hosts.link(id: worktree.host)
                    let state = link.map { hosts.state($0.host) } ?? ("Offline", Theme.inkMuted)
                    let row = ListRow(title: worktree.title, detail: link?.host.name, state: state)
                    switch hosts.phase(link) {
                    case .connected: NavigationLink(value: worktree) { row }
                    // Opens the host's screen, which says how to trust this phone.
                    case .pending: if let link { NavigationLink(value: link.host) { row } }
                    default: row.opacity(0.6)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.canvas)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The account's hosts, to see their state and trust this phone on them.
struct HostsView: View {
    let account: Account
    let hosts: Hosts

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(hosts.list) { host in
                    NavigationLink(value: host) { ListRow(title: host.name, detail: nil, state: hosts.state(host)) }.disabled(!host.online)
                }
                if hosts.list.isEmpty, hosts.error == nil {
                    Text("No hosts on this account yet.").font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                }
                Fingerprint(account: account).padding(.top, 12)
            }
            .padding(16)
        }
        .background(Theme.canvas)
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await hosts.load(account: account) }
    }
}

/// A tappable row: a title, a caption, and optionally a state after it.
struct ListRow: View {
    let title: String
    let detail: String?
    var state: (text: String, color: Color)? = nil
    var fill: Color = Theme.surface

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    if let detail, !detail.isEmpty { Text(detail).foregroundStyle(Theme.inkMuted) }
                    if let state { Text(state.text).foregroundStyle(state.color) }
                }
                .font(Theme.Font.caption)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkMuted)
        }
        .padding(14)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A host's worktrees, and Needs you first.
struct WorktreesView: View {
    let account: Account
    let link: HostLink
    @Binding var path: NavigationPath
    @State private var worktrees: [Worktree] = []
    /// What the alert is asking for: a new project, a clone, or a branch of the project at that path.
    enum Making: Equatable { case project, clone, worktree(of: String) }
    @State private var making: Making?
    @State private var draft = ""
    @State private var name = ""
    @State private var busy = false
    @State private var refused: String?

    /// Each project's main worktree: git lists it first.
    private var projects: [Worktree] {
        var seen = Set<String>()
        return worktrees.filter { !$0.project.isEmpty && seen.insert($0.project).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch link.phase {
                case .connecting:
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                case .pending(let trusted):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This host doesn't trust this phone yet").font(Theme.Font.title).foregroundStyle(Theme.ink)
                        Text(trusted == 0 ? "On the host, run:" : "On the host, or from a computer it trusts, run:")
                            .font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                        Text("agentboard trust \(account.publicKeyBase64)").font(Theme.Font.caption.monospaced())
                            .foregroundStyle(Theme.ink).textSelection(.enabled)
                        Text("Or approve it from a computer this host already trusts: it lists this phone as waiting.")
                            .font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                        Button("Try again") { link.connect(account: account) }.buttonStyle(SolidButton())
                    }
                    Fingerprint(account: account)
                case .failed(let why):
                    Text(why).font(Theme.Font.body).foregroundStyle(Theme.danger)
                    Button("Try again") { link.connect(account: account) }.buttonStyle(SolidButton())
                case .connected:
                    let waiting = link.attention.compactMap { request in link.cards.first { $0.id == request.id } }
                    if !waiting.isEmpty {
                        Text("NEEDS YOU").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.deep)
                        ForEach(waiting) { card in
                            NavigationLink(value: card) {
                                ListRow(title: card.name, detail: (card.worktree as NSString).lastPathComponent, fill: Theme.accentSoft)
                            }
                        }
                    }
                    Text("WORKTREES").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.inkMuted).padding(.top, 8)
                    ForEach(worktrees) { worktree in
                        NavigationLink(value: worktree) {
                            ListRow(title: worktree.title, detail: worktree.project)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.canvas)
        .navigationTitle(link.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Card.self) { TerminalPage(link: link, card: $0) }
        .toolbar {
            if link.phase == .connected {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { draft = ""; making = .project } label: {
                            Text("New project")
                            Text("An empty repository on this host, with a first commit.")
                        }
                        Button { draft = ""; name = ""; making = .clone } label: {
                            Text("Clone a repository")
                            Text("Copies one from an https or ssh address.")
                        }
                        if !projects.isEmpty {
                            Section("New worktree") {
                                ForEach(projects) { project in
                                    Button { draft = ""; making = .worktree(of: project.path) } label: {
                                        Text(project.project)
                                        Text("A new branch of this project, in its own folder.")
                                    }
                                }
                            }
                        }
                    } label: { if busy { ProgressView() } else { Image(systemName: "plus") } }
                    .disabled(busy)
                    .accessibilityLabel("Create")
                }
            }
        }
        .alert(making == .project ? "New project" : making == .clone ? "Clone a repository" : "New worktree",
               isPresented: Binding(get: { making != nil }, set: { if !$0 { making = nil } })) {
            TextField(making == .project ? "Name" : making == .clone ? "https://… or git@…" : "Branch", text: $draft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if making == .clone {
                TextField("Name (optional)", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("Create") { if let making { Task { await create(making, draft) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(making == .project ? "Made in the host's projects folder." : making == .clone ? "Named after the repository unless you give a name." : "A branch name, like feature/login.")
        }
        .alert("Couldn't create it", isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(refused ?? "") }
        .task { if link.phase != .connected { link.connect(account: account) } }
        .task(id: link.phase) {
            guard link.phase == .connected else { return }
            let catalog = AccountCatalog(server: account.server)
            let list = await catalog.worktrees(on: link, document: await catalog.document())
            withAnimation(.smooth) { worktrees = list }
            #if DEBUG
            // `-openWorktree <path>` and `-openCard <uuid>`, once. `agent` for either: the first
            // agent card's worktree, or that card.
            if path.count == 1 {
                let agent = link.cards.first { $0.runner == nil }
                if var wanted = DebugLaunch.value("openWorktree") {
                    if wanted == "agent", let agent { wanted = agent.worktree }
                    path.append(list.first { $0.path == wanted } ?? Worktree(path: wanted, host: link.host.id.lowercased()))
                }
                let wanted = DebugLaunch.value("openCard")
                if let card = wanted == "agent" ? agent : link.cards.first(where: { $0.id == wanted.flatMap(UUID.init) }) {
                    path.append(card)
                }
            }
            #endif
        }
    }

    /// Asks the host's core, then opens what it made.
    private func create(_ making: Making, _ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        let made = await link.create { id in
            switch making {
            case .project: BoardSay.createProject(id, name: text, clone: nil)
            case .clone: BoardSay.createProject(id, name: name.isEmpty ? nil : name, clone: text)
            case .worktree(let project): BoardSay.createWorktree(id, project: project, branch: text)
            }
        }
        busy = false
        guard let made = made.path else { return refused = made.error ?? "The host didn't say why." }
        var project = (made as NSString).lastPathComponent
        if case .worktree(let of) = making { project = worktrees.first { $0.path == of }?.project ?? project }
        let worktree = Worktree(path: made, branch: making == .project || making == .clone ? nil : text, project: project,
                                host: link.host.id.lowercased())
        withAnimation(.smooth) { if !worktrees.contains(worktree) { worktrees.append(worktree) } }
        path.append(worktree)
    }
}
