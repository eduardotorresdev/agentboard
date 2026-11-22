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
            withAnimation(.smooth) { list = hosts.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }; error = nil }
            for host in hosts where host.online { link(host).connect(account: account) }
        } catch let failure as AccountServer.ServerError where failure.status == 401 {
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

/// The root, as the Mac's sidebar: an organization, its projects, each project's worktrees from
/// any host.
struct BrowseView: View {
    let account: Account
    @State private var hosts = Hosts()
    @State private var groups: [OrganizationGroup] = []
    @State private var selected: String?
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    private var current: OrganizationGroup? { groups.first { $0.id == selected } ?? groups.first }
    /// Changes whenever a host connects, drops or is asked to trust.
    private var phases: String { hosts.links.values.map { "\($0.host.id)\($0.phase)" }.sorted().joined() }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if groups.count > 1 {
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
}
