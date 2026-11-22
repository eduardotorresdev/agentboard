import SwiftUI

@main
struct PhoneApp: App {
    @State private var account = Account()

    var body: some Scene {
        WindowGroup {
            Group {
                if account.token == nil { SignInView(account: account) } else { HostsView(account: account) }
            }
            .preferredColorScheme(.light)
            .tint(Theme.accent)
        }
    }
}

/// GitHub's device flow: a code here, confirmed on any device.
struct SignInView: View {
    let account: Account
    @State private var code: AccountServer.DeviceCode?
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
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
            Fingerprint(account: account)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
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

/// The account's hosts, with whether each is online.
struct HostsView: View {
    let account: Account
    @State private var hosts: [Host] = []
    @State private var error: String?
    @State private var links: [String: HostLink] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hosts) { host in
                        NavigationLink(value: host) { HostRow(host: host) }.disabled(!host.online)
                    }
                    if hosts.isEmpty, error == nil {
                        Text("No hosts on this account yet.").font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                    }
                    if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.danger) }
                    Fingerprint(account: account).padding(.top, 12)
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", role: .destructive) { account.signOut() }
                    } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel("Account")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .navigationDestination(for: Host.self) { host in WorktreesView(account: account, link: link(host)) }
        }
    }

    private func link(_ host: Host) -> HostLink {
        if let link = links[host.id] { return link }
        let link = HostLink(host: host)
        links[host.id] = link
        return link
    }

    private func load() async {
        do {
            let list = try await account.server.hosts()
            withAnimation(.smooth) { hosts = list.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }; error = nil }
        } catch let failure as AccountServer.ServerError where failure.status == 401 {
            account.signOut()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HostRow: View {
    let host: Host

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(host.online ? Theme.accent : Theme.inkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(Theme.Font.title).foregroundStyle(Theme.ink)
                Text(host.online ? "Online" : "Offline").font(Theme.Font.caption).foregroundStyle(host.online ? Theme.accent : Theme.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkMuted)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A host's worktrees, and Needs you first.
struct WorktreesView: View {
    let account: Account
    let link: HostLink
    var catalog: any CatalogSource = HostCardsCatalog()

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
                                row(card.name, detail: Worktree(path: card.worktree).title, fill: Theme.accentSoft)
                            }
                        }
                    }
                    Text("WORKTREES").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.inkMuted).padding(.top, 8)
                    ForEach(catalog.worktrees(on: link)) { worktree in
                        NavigationLink(value: worktree) { row(worktree.title, detail: worktree.project, fill: Theme.surface) }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.canvas)
        .navigationTitle(link.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Worktree.self) { CanvasView(link: link, worktree: $0) }
        .navigationDestination(for: Card.self) { TerminalPage(link: link, card: $0) }
        .task { if link.phase != .connected { link.connect(account: account) } }
    }

    private func row(_ title: String, detail: String, fill: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkMuted)
        }
        .padding(14)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
