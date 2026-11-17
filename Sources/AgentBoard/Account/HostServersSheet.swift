import SwiftUI

/// A host's MCP servers: what it ends with and why, and what to change for that host alone
/// (see "Per host" in docs/hosts.md). Saving writes the account's vault and has the host apply it.
struct HostServersSheet: View {
    let hosts: HostStores
    let host: UUID
    /// The server being added (name "") or given a command of this host's own.
    @State private var draft: Draft?
    @State private var isSaving = false

    struct Draft {
        var name: String
        /// Whether the name is the user's to type (a server only this host gets).
        var isNew: Bool
        var command = "", arguments = ""
        /// Environment values are secrets: typed masked, and never shown again.
        var environment: [Variable] = [Variable()]

        struct Variable: Identifiable {
            let id = UUID()
            var name = "", value = ""
        }

        /// What goes in the host's section. Arguments are split at spaces.
        var entry: [String: Any] {
            var entry: [String: Any] = ["command": command.trimmingCharacters(in: .whitespaces)]
            let arguments = arguments.split(separator: " ").map(String.init)
            if !arguments.isEmpty { entry["args"] = arguments }
            let environment = Dictionary(self.environment.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }) { $1 }
            if !environment.isEmpty { entry["env"] = environment }
            return entry
        }

        var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var name: String { hosts.account.hosts.first { $0.id == host }?.name ?? L("the host") }
    private var rows: [Vault.ServerRow] {
        Vault.rows(hosts.vaultManifest ?? [:], host: host, lacking: hosts.reports[host]?.lacking ?? [:], skipped: hosts.skippedServers)
    }

    var body: some View {
        AppDialog(title: L("MCP servers on \(name)"), subtitle: L("What agents on this host are given, and what only this host does differently.")) {
            VStack(alignment: .leading, spacing: 14) {
                if let draft { editor(draft) } else { list }
                if let note = hosts.syncNotes[host], isSaving || hosts.vaultNote != nil {
                    Text(note).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 520, alignment: .leading)
        } footer: {
            if draft != nil {
                Button(L("Cancel"), role: .cancel) { draft = nil }.keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    guard let draft else { return }
                    let name = draft.name.trimmingCharacters(in: .whitespaces), entry = SendableEntry(value: draft.entry), host = host
                    self.draft = nil
                    save { Vault.setServer(entry.value, named: name, on: host, in: &$0) }
                }
                .buttonStyle(DialogButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(draft?.isComplete != true)
            } else {
                Button(L("Add a server only for this host")) { draft = Draft(name: "", isNew: true) }
                    .buttonStyle(DialogButtonStyle())
                    .help(L("A server agents get on this host and nowhere else."))
                // A page of the host's dialog: back to its options.
                Button(L("Back")) { withAnimation(.snappy(duration: 0.25)) { hosts.editingHost?.servers = false } }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isSaving)
    }

    private struct SendableEntry: @unchecked Sendable { let value: [String: Any] }

    private func save(_ edit: @escaping @Sendable (inout Vault.Manifest) -> Void) {
        isSaving = true
        Task {
            await hosts.syncVault(edit: edit)
            isSaving = false
        }
    }

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            Text(L("No servers yet. The ones in your account appear here after a sync.")).foregroundStyle(Theme.inkMuted)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.name).font(Theme.Font.heading).foregroundStyle(Theme.ink)
                            Text(Self.why(row)).font(Theme.Font.caption).foregroundStyle(row.lacking != nil ? Theme.danger : Theme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !row.command.isEmpty {
                            Text(row.command).font(Theme.Font.caption.monospaced()).foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 8) { actions(row) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxHeight: 420)
    }

    /// Where a server comes from, or why the host doesn't have it.
    static func why(_ row: Vault.ServerRow) -> String {
        if let program = row.lacking { return L("Its program, \(program), isn't on this host") }
        return switch row.origin {
        case .account: L("From your account")
        case .ownCommand: L("From your account, with this host's own command")
        case .onlyHere: L("Only on this host")
        case .unused: L("Not used on this host")
        case .macOnly(let reason): L("Not on hosts: \(reason)")
        }
    }

    @ViewBuilder private func actions(_ row: Vault.ServerRow) -> some View {
        let name = row.name, host = host
        switch row.origin {
        case .account:
            action(L("Use another command on this host"), L("This host runs its own program under this name; the others keep the account's.")) {
                draft = Draft(name: name, isNew: false)
            }
            action(L("Don't use on this host"), L("Agents on this host aren't given this server.")) { save { Vault.setUsed(false, name, on: host, in: &$0) } }
        case .ownCommand:
            action(L("Change this host's command"), L("Type the command again, with its environment.")) { draft = Draft(name: name, isNew: false) }
            action(L("Use the account's again"), L("Removes this host's own command.")) { save { Vault.setServer(nil, named: name, on: host, in: &$0) } }
        case .onlyHere:
            action(L("Change"), L("Type the command again, with its environment.")) { draft = Draft(name: name, isNew: false) }
            action(L("Remove from this host"), L("Agents on this host stop being given it.")) { save { Vault.setServer(nil, named: name, on: host, in: &$0) } }
        case .unused:
            action(L("Use on this host again"), L("Agents on this host are given the account's server again.")) { save { Vault.setUsed(true, name, on: host, in: &$0) } }
        case .macOnly:
            action(L("Use another command on this host"), L("Give this host a program of its own under this name.")) { draft = Draft(name: name, isNew: false) }
        }
    }

    private func action(_ title: String, _ explanation: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(DialogButtonStyle()).help(explanation).accessibilityHint(explanation)
    }

    private func editor(_ current: Draft) -> some View {
        let draft = Binding(get: { self.draft ?? current }, set: { self.draft = $0 })
        return VStack(alignment: .leading, spacing: 12) {
            if current.isNew {
                FormRow(label: L("Name"), message: L("What agents on this host call the server.")) {
                    TextField("", text: draft.name, prompt: Text("deploys"))
                }
            } else {
                Text(L("\(current.name) on \(name) runs this instead of what your account has.")).foregroundStyle(Theme.inkMuted)
            }
            FormRow(label: L("Command"), message: L("A program on this host, by name or path.")) {
                TextField("", text: draft.command, prompt: Text("/usr/local/bin/server")).font(Theme.Font.body.monospaced())
            }
            FormRow(label: L("Arguments"), message: L("Separated by spaces.")) {
                TextField("", text: draft.arguments, prompt: Text("--stdio")).font(Theme.Font.body.monospaced())
            }
            FormRow(label: L("Environment"), message: L("Values are kept sealed in your account and are never shown again.")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.environment) { $variable in
                        HStack(spacing: 8) {
                            TextField("", text: $variable.name, prompt: Text("API_KEY")).font(Theme.Font.body.monospaced())
                            SecureField("", text: $variable.value, prompt: Text(L("Value")))
                        }
                    }
                    Button(L("Add a variable")) { self.draft?.environment.append(Draft.Variable()) }
                        .buttonStyle(DialogButtonStyle())
                        .help(L("One more name and value for the server's environment."))
                }
            }
        }
    }
}
