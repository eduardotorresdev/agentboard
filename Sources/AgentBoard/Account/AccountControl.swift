import AgentRuntime
import AppKit
import SwiftUI

/// The account in the top bar, beside the organizations: "Sign in" when there is none, else the
/// user's avatar, which opens the account's hosts and "Sign out".
struct AccountControl: View {
    let hosts: HostStores
    private var account: AccountStore { hosts.account }
    @State private var menu = OrganizationMenuPanel()
    @State private var isHovered = false

    var body: some View {
        if let signedIn = account.account {
            Button { menu.toggle { state, close in AccountMenu(hosts: hosts, state: state, close: close) } } label: {
                AccountAvatar(account: signedIn, size: 22)
                    // A computer is asking to use one of the hosts: waiting for you.
                    .overlay(alignment: .topTrailing) {
                        if hosts.boards.values.contains(where: { !$0.pending.isEmpty }) {
                            Circle().fill(Theme.deep).frame(width: 8, height: 8).offset(x: 2, y: -2)
                        }
                    }
                    .scaleEffect(isHovered ? 1.06 : 1)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .background(OrganizationMenuAnchor(panel: menu))
            .onHover { hovering in withAnimation(.snappy(duration: 0.2)) { isHovered = hovering } }
            .help(L("Account: your hosts, and sign out"))
            .accessibilityLabel(L("Account: \(signedIn.name ?? signedIn.login)"))
            .onAppear {
                // For screenshots of a build under test (see docs/core.md).
                if DebugShow.items.contains("account-menu") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { menu.toggle { state, close in AccountMenu(hosts: hosts, state: state, close: close) } }
                }
            }
        } else {
            // What it is for is said where it leads: the sign-in dialog.
            Button { account.signIn() } label: {
                // Its own ink: the bar grays a plain title, which reads as disabled.
                Text(L("Sign in")).font(Theme.Font.label).foregroundStyle(Theme.ink).padding(.horizontal, 6).frame(height: 30).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(SignInDialog.purpose)
        }
    }
}

extension HostChannel.Path {
    /// How a host is reached, for its row and its stats.
    var note: String {
        switch self {
        case .direct: L("Direct")
        case .relay: L("Relayed, slower")
        }
    }
}

/// Asked before this Mac's skills first go to a host: what goes, and that later syncs won't ask.
struct SyncQuestionDialog: View {
    let hosts: HostStores
    let host: UUID

    var body: some View {
        AppDialog(title: L("Sync skills to \(hosts.account.hosts.first { $0.id == host }?.name ?? L("the host"))?")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Copies \(AgentCatalog.all[0].title)'s skills, commands, subagents, instructions and user-level MCP servers, with their keys, from this Mac. Not its settings, project-level servers or other agents' setups."))
                Text(L("After this, the host is kept in sync each time it connects. Without it, agents there work with what the host has."))
            }
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button(L("Not Now"), role: .cancel) { hosts.answerSync(false) }
                .keyboardShortcut(.cancelAction)
            Button(L("Sync")) { hosts.answerSync(true) }
                .buttonStyle(DialogButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The account's picture from GitHub, or its initial on the accent while it loads or has none.
private struct AccountAvatar: View {
    let account: Account
    let size: CGFloat

    var body: some View {
        AsyncImage(url: account.avatarURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text((account.name ?? account.login).first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.accent)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

/// Signing in: the code to confirm on the sign-in page, which the server waits for.
struct SignInDialog: View {
    /// What signing in gets.
    static var purpose: String { L("Run agents on your other machines and work with them from this board.") }
    let account: AccountStore
    @State private var copied = false

    var body: some View {
        AppDialog(title: L("Sign in"), subtitle: Self.purpose) {
            VStack(alignment: .leading, spacing: 14) {
                if let login = account.login {
                    HStack(spacing: 12) {
                        Text(login.userCode)
                            .font(Theme.Font.headline.monospaced())
                            .tracking(2)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control))
                        Button(copied ? L("Copied") : L("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(login.userCode, forType: .string)
                            withAnimation(.snappy(duration: 0.2)) { copied = true }
                        }
                        .buttonStyle(DialogButtonStyle())
                    }
                    Text(L("Open the sign-in page, enter this code and approve. This window closes by itself."))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = account.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Asking for a code…")).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { account.cancelSignIn() }
                .keyboardShortcut(.cancelAction)
            if let login = account.login {
                Button(L("Open Sign-in Page")) { NSWorkspace.shared.open(login.verificationURL) }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            } else if account.error != nil {
                Button(L("Try Again")) { account.signIn() }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The account menu: signing in, or who is signed in, this Mac and the account's hosts (how
/// each is reached, syncing this Mac's skills to it, forgetting it), then "Sign out".
struct AccountMenu: View {
    let hosts: HostStores
    let state: OrganizationMenuState
    let close: () -> Void
    private var account: AccountStore { hosts.account }
    /// The host "Forget this host" was clicked on once: the next click does it.
    @State private var forgetting: UUID?
    /// "Sign out everywhere" was clicked once: the next click does it.
    @State private var confirmingEverywhere = false
    /// "Sign out" was clicked once: the next click does it, with or without `removingKey`.
    @State private var confirmingSignOut = false
    @State private var removingKey = true
    /// The approval or forgetting of a computer clicked once (host, then key): the next click does it.
    @State private var confirmingBoard: String?
    @State private var copiedKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let signedIn = account.account {
                Text(signedIn.name ?? signedIn.login)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                signedInRows
            }
        }
        .padding(6)
        .onExitCommand(perform: close)
        .task {
            await account.refreshHosts()
            hosts.showSample()
            // Who each host trusts and who asks to be, while the menu is open.
            while !Task.isCancelled {
                for host in account.hosts where host.online && !account.identityChanged(host.id) && hosts[host.id]?.core == nil {
                    await hosts.listBoards(of: host.id)
                }
                for host in hosts.remote.keys where hosts[host]?.core != nil && hosts.boards[host] == nil { await hosts.listBoards(of: host) }
                try? await Task.sleep(for: .seconds(hosts.boardInterval))
            }
        }
        .modifier(MenuChrome(state: state))
    }

    @ViewBuilder private var signedInRows: some View {
        Text(L("Hosts"))
            .font(Theme.Font.eyebrow)
            .tracking(Theme.Font.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
        row(L("This Mac"), detail: L("Online"), isOnline: true)
        if let key = account.boardPublicKey {
            // What a host, or a computer it trusts, shows when this Mac asks to use it.
            note(L("Fingerprint \(Self.whole(AccountStore.fingerprint(of: key)))")).textSelection(.enabled).padding(.leading, 22)
        }
        ForEach(account.hosts) { host in
            let changed = account.identityChanged(host.id)
            let waiting = host.online && !changed ? hosts.waiting[host.id] : nil
            row(host.name, detail: changed ? L("Identity changed") : waiting != nil ? L("Waiting for approval")
                    : host.online ? hosts[host.id]?.hostPath?.note ?? L("Online") : Self.lastSeen(host),
                isOnline: host.online && !changed && waiting == nil, isWrong: changed)
            Group {
                if let waiting, let key = account.boardPublicKey {
                    if waiting > 0, !account.wasTrusted(by: host.id) {
                        note(L("Another computer is already trusted by this host.")).foregroundStyle(Theme.ink)
                    }
                    note(L("Approve \(Self.whole(AccountStore.fingerprint(of: key))) on a computer this host already trusts. Or run `agentboard trust` with the key below on the host, which works even when that approval doesn't."))
                    HStack(spacing: 8) {
                        Text(key).font(Theme.Font.caption.monospaced()).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button(copiedKey ? L("Copied") : L("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key, forType: .string)
                            withAnimation(.snappy(duration: 0.2)) { copiedKey = true }
                        }
                        .buttonStyle(DialogButtonStyle())
                        .help(L("Copies this Mac's key, for `agentboard trust` on the host."))
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
                if let listed = hosts.boards[host.id], host.online, !changed, waiting == nil {
                    ForEach(listed.pending) { board in
                        confirmed("\(host.id)+\(board.key)", title: L("Approve a new computer"),
                                  caption: board.name.isEmpty
                                      ? L("\(Self.whole(board.fingerprint)) wants to use \(host.name). The same fingerprint shows in that computer's account menu.")
                                      : L("\(Self.whole(board.fingerprint)) wants to use \(host.name). It calls itself “\(board.name)”. The same fingerprint shows in that computer's account menu.")) {
                            _ = await hosts.changeBoard(board.key, on: host.id)
                        }
                    }
                    ForEach(listed.trusted) { board in
                        let own = board.key == account.boardPublicKey
                        confirmed("\(host.id)-\(board.key)", title: own ? L("Forget this Mac") : L("Forget a computer"),
                                  caption: own ? L("\(host.name) stops trusting this Mac until it is approved there again.")
                                      : board.name.isEmpty ? L("\(Self.whole(board.fingerprint)) stops reaching \(host.name) until approved again.")
                                      : L("\(Self.whole(board.fingerprint)), which calls itself “\(board.name)”, stops reaching \(host.name) until approved again.")) {
                            _ = await hosts.changeBoard(board.key, on: host.id, forget: true)
                        }
                    }
                }
                if host.online, !changed, case .relay = hosts[host.id]?.hostPath {
                    Text(L("Direct when this Mac and the host share a network, or the host's port 47470 is reachable."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
                if changed {
                    MenuAction(title: L("Trust new identity"),
                               caption: L("Only if `agentboard status` on the host shows \(AccountStore.fingerprint(of: host.publicKey)).")) {
                        account.acceptIdentity(of: host.id)
                    }
                } else if host.online, waiting == nil {
                    MenuAction(title: L("Sync skills"), caption: L("Copies this Mac's skills and MCP servers to this host.")) {
                        Task { await hosts.sync(host.id, from: FileManager.default.homeDirectoryForCurrentUser) }
                    }
                    // What the last sync did.
                    if let note = hosts.syncNotes[host.id] {
                        Text(note)
                            .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                    }
                }
                MenuAction(title: forgetting == host.id ? L("Forget \(host.name)? Click again") : L("Forget this host"),
                           caption: L("Removes it from your account.")) {
                    guard forgetting == host.id else { return forgetting = host.id }
                    forgetting = nil
                    Task { _ = await hosts.forget(host.id) }
                }
            }
            .padding(.leading, 22)
        }
        MenuAction(title: confirmingSignOut ? L("Sign out? Click again") : L("Sign out"),
                   caption: L("Agents on your hosts keep running; this Mac stops showing them.")) {
            guard confirmingSignOut else { return confirmingSignOut = true }
            close()
            Task { await hosts.signOut(removingKey: removingKey) }
        }
        .padding(.top, 8)
        if confirmingSignOut {
            MenuAction(title: (removingKey ? "✓ " : "") + L("Remove this Mac from its hosts first"),
                       caption: L("Online hosts forget this Mac's key: it needs approval there again.")) {
                removingKey.toggle()
            }
            .padding(.leading, 22)
            .accessibilityAddTraits(removingKey ? .isSelected : [])
        }
        MenuAction(title: confirmingEverywhere ? L("Sign out everywhere? Click again") : L("Sign out everywhere"),
                   caption: L("Signs out every computer showing this account. Hosts keep running.")) {
            guard confirmingEverywhere else { return confirmingEverywhere = true }
            Task {
                // The menu stays when the server didn't do it: still signed in, to try again.
                if await account.signOutEverywhere() { close() } else { confirmingEverywhere = false }
            }
        }
    }

    /// A fingerprint that a line never breaks inside.
    private static func whole(_ fingerprint: String) -> String { fingerprint.replacingOccurrences(of: " ", with: "\u{A0}") }

    /// A muted line under a row.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    /// Something that is done on the second click.
    private func confirmed(_ id: String, title: String, caption: String, action: @escaping () async -> Void) -> some View {
        MenuAction(title: confirmingBoard == id ? L("\(title)? Click again") : title, caption: caption) {
            guard confirmingBoard == id else { return confirmingBoard = id }
            confirmingBoard = nil
            Task { await action() }
        }
    }

    private func row(_ name: String, detail: String, isOnline: Bool, isWrong: Bool = false) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? Theme.accent : Theme.inkMuted.opacity(0.45))
                .frame(width: 6, height: 6)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(name).font(Theme.Font.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).font(Theme.Font.caption).foregroundStyle(isWrong ? Theme.danger : Theme.inkMuted).lineLimit(1).layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// "Last seen 3 hours ago", or that it never came online.
    private static func lastSeen(_ host: Host) -> String {
        guard let seen = host.lastSeen else { return L("Never online") }
        let ago = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: seen), relativeTo: Date())
        return L("Last seen \(ago)")
    }
}

/// Something to do in the account menu: its name, and one line on what it does.
private struct MenuAction: View {
    let title: String
    let caption: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.ink)
                Text(caption)
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHovered ? Theme.surfaceDeep : .clear, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { isHovered = inside } }
    }
}
