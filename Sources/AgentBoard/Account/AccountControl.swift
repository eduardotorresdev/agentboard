import AgentRuntime
import AppKit
import SwiftUI

/// The account in the top bar, beside the organizations: "Sign in" when there is none, else the
/// user's avatar, which opens "Sign out".
struct AccountControl: View {
    let hosts: HostStores
    private var account: AccountStore { hosts.account }
    @State private var menu = OrganizationMenuPanel()
    @State private var isHovered = false

    var body: some View {
        if let signedIn = account.account {
            Button { menu.toggle { state, close in AccountMenu(hosts: hosts, state: state, close: close) } } label: {
                AccountAvatar(account: signedIn, size: 22)
                    .scaleEffect(isHovered ? 1.06 : 1)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .background(OrganizationMenuAnchor(panel: menu))
            .onHover { hovering in withAnimation(.snappy(duration: 0.2)) { isHovered = hovering } }
            .help(L("Account: sign out"))
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

/// The account at the foot of the sidebar: a box as wide as it, flush with its bottom, with the
/// user's avatar and name, which opens "Sign out"; "Sign in" when there is no account.
struct AccountBlock: View {
    let hosts: HostStores
    private var account: AccountStore { hosts.account }
    @State private var menu = OrganizationMenuPanel(leading: true, above: true)
    @State private var isHovered = false

    var body: some View {
        let signedIn = account.account
        Button {
            if signedIn != nil { toggle() } else { account.signIn() }
        } label: {
            HStack(spacing: 10) {
                if let signedIn {
                    AccountAvatar(account: signedIn, size: 26)
                    Text(signedIn.name ?? signedIn.login).font(Theme.Font.heading).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "person.crop.circle").font(Theme.Font.title).foregroundStyle(Theme.accent).frame(width: 26, height: 26)
                    Text(L("Sign in")).font(Theme.Font.heading).foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(isHovered ? Theme.surfaceDeep : Theme.surface)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(OrganizationMenuAnchor(panel: menu))
        .onHover { hovering in withAnimation(.snappy(duration: 0.2)) { isHovered = hovering } }
        .help(signedIn != nil ? L("Account: sign out") : SignInDialog.purpose)
        .accessibilityLabel(signedIn.map { L("Account: \($0.name ?? $0.login)") } ?? L("Sign in"))
        .onAppear {
            // For screenshots of a build under test (see docs/core.md).
            if DebugShow.items.contains("account-menu") { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: toggle) }
        }
    }

    private func toggle() {
        menu.toggle { state, close in AccountMenu(hosts: hosts, state: state, close: close, anchor: .bottomLeading) }
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

/// Asked once per account, before anything of this Mac is kept in it: what is kept, who can
/// read it, and where it lands.
struct VaultQuestionDialog: View {
    let hosts: HostStores

    var body: some View {
        AppDialog(title: L("Keep your skills in your account?")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Keeps \(AgentCatalog.all[0].title)'s skills, commands, subagents and instructions from this Mac, its user-level MCP servers with their keys, and your GitHub login, so every host of yours has them."))
                Text(L("It is sealed with a key only the computers you approved hold: the account server can't read it."))
                Text(L("On a host it lands in the home every agent there shares. After this, changes here are kept without asking."))
            }
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 440, alignment: .leading)
        } footer: {
            Button(L("Not Now"), role: .cancel) { hosts.answerVault(false) }
                .keyboardShortcut(.cancelAction)
            Button(L("Keep and Sync")) { hosts.answerVault(true) }
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

/// The account menu: who is signed in, and signing out (here, or everywhere).
struct AccountMenu: View {
    let hosts: HostStores
    let state: OrganizationMenuState
    let close: () -> Void
    /// The corner it grows from: the one it hangs from.
    var anchor: UnitPoint = .topTrailing
    private var account: AccountStore { hosts.account }
    /// "Sign out everywhere" was clicked once: the next click does it.
    @State private var confirmingEverywhere = false
    /// "Sign out" was clicked once: the next click does it, with or without `removingKey`.
    @State private var confirmingSignOut = false
    @State private var removingKey = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let signedIn = account.account {
                Text(signedIn.name ?? signedIn.login)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                macHostActions
                MenuAction(title: confirmingSignOut ? L("Sign out? Click again") : L("Sign out"),
                           caption: L("Agents on your hosts keep running; this Mac stops showing them.")) {
                    guard confirmingSignOut else { return confirmingSignOut = true }
                    close()
                    Task { await hosts.signOut(removingKey: removingKey) }
                }
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
        }
        .padding(6)
        .onExitCommand(perform: close)
        .modifier(MenuChrome(state: state, anchor: anchor))
    }

    /// This Mac as a host: on or off, its own sign-in, and the boards waiting for approval.
    @ViewBuilder private var macHostActions: some View {
        let host = hosts.macHost
        MenuAction(title: (host.isWanted ? "✓ " : "") + L("This Mac as host"),
                   caption: L("Your other boards can run agents here, once you approve each one.")) {
            host.setWanted(!host.isWanted, signedIn: account.account != nil)
        }
        .accessibilityAddTraits(host.isWanted ? .isSelected : [])
        if let signIn = host.signIn {
            MenuAction(title: L("Confirm code \(signIn.code)"),
                       caption: L("The host signs in on its own, apart from this board: open the page and enter this code.")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(signIn.code, forType: .string)
                NSWorkspace.shared.open(signIn.page)
            }
            .padding(.leading, 22)
        }
        if let error = host.error {
            Text(error).font(Theme.Font.caption).foregroundStyle(Theme.danger)
                .padding(.horizontal, 8).padding(.leading, 22)
        }
        ForEach(host.waiting) { board in
            MenuAction(title: L("Approve \(board.fingerprint)"),
                       caption: board.name.isEmpty ? L("A board wants to use this Mac. Its own account menu shows the same fingerprint.")
                           : L("“\(board.name)” wants to use this Mac. Its own account menu shows the same fingerprint.")) {
                host.approve(board)
            }
            .padding(.leading, 22)
        }
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
