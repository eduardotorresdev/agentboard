import Observation
import SwiftUI

/// Adds a worktree to a project. The user names what they'll work on; that name is the
/// worktree's title, and the branch and folder are derived from it (or, when it names an
/// existing branch, are that branch).
struct NewWorktreeDialog: View {
    let store: ProjectStore
    let project: Project
    /// The account's hosts; without it (or signed out, or with none) there is no host to pick.
    var hosts: HostStores?
    /// Called with the worktree that was added, after the dialog closes.
    let onAdded: (Worktree) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorktreeDraft
    /// Set when git failed after the worktree was in place (e.g. a hook): shown before closing.
    @State private var created: (worktree: Worktree, warning: String)?
    /// The host picked; nil is this Mac.
    @State private var hostID: UUID?
    /// False once the project is known to have no `origin`, which other hosts clone it from.
    @State private var hasOrigin = true

    init(store: ProjectStore, project: Project, hosts: HostStores? = nil, onAdded: @escaping (Worktree) -> Void) {
        self.store = store
        self.project = project
        self.hosts = hosts
        self.onAdded = onAdded
        _draft = State(initialValue: WorktreeDraft(repository: project.path))
    }

    var body: some View {
        AppDialog(title: L("New Worktree"), subtitle: project.name) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("Name"), message: message, isError: draft.problem != nil,
                        // With the host row under it, room kept for a message is a hole in the form.
                        reservesMessage: remoteHosts.isEmpty) {
                    TextField("", text: $draft.name, prompt: Text(L("Fix the login redirect")))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit(submit)
                        .disabled(draft.isCreating || created != nil)
                }
                // The full path, where the short form above leaves some out.
                .help(draft.check?.fullPath ?? "")
                if !remoteHosts.isEmpty { hostRow }
                if let created {
                    DialogError(message: L("The worktree was created, but git reported a problem: \(created.warning)"))
                } else if let error = draft.error {
                    DialogError(message: error)
                }
            }
        } footer: {
            if let created {
                Button(L("Open Worktree")) { finish(created.worktree) }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L("Cancel"), role: .cancel) {
                    // Stops git if it's running; what it made so far is undone where provably safe.
                    draft.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if draft.isCreating { ProgressView().controlSize(.small) }
                        Text(L("Create"))
                    }
                }
                .buttonStyle(DialogButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmedName.isEmpty || draft.problem != nil || draft.isCreating || (hostID != nil && draft.host == nil))
            }
        }
        .task(id: hostID) { await reach(hostID) }
        // Restarts on each keystroke and after a failure, so only the latest state is checked.
        .task(id: draft.revision) { await draft.validate() }
        .onAppear {
            draft.onCreated = { result in
                if let hostID {
                    Task { opened(await store.hostWorktree(at: result.path, branch: draft.check?.branch, on: hostID, in: project), result) }
                } else if let worktree = store.worktree(at: result.path, in: project) {
                    opened(worktree, result)
                } else {
                    dismiss()
                }
            }
        }
    }

    private func opened(_ worktree: Worktree, _ result: Git.CreatedWorktree) {
        // The typed name is the initial title; agents may refine it, unlike a user rename.
        store.setInitialTitle(draft.trimmedName, path: worktree.path)
        if let warning = result.warning {
            created = (worktree, WorktreeDraft.cause(of: warning))
        } else {
            finish(worktree)
        }
    }

    /// The account's hosts, when signed in.
    private var remoteHosts: [Host] { hosts?.account.account == nil ? [] : hosts?.account.hosts ?? [] }

    /// Where the worktree goes: this Mac, or one of the account's hosts that is online.
    private var hostRow: some View {
        FormRow(label: L("Host"), message: hasOrigin
            ? L("Where the worktree's folder is and its agents and runners run.")
            : L("This project has no origin remote, so its worktrees can only be on this Mac.")) {
            Menu {
                Button(L("This Mac")) { hostID = nil }
                ForEach(remoteHosts) { host in
                    Button(host.online ? host.name : L("\(host.name) (offline)")) { hostID = host.id }
                        .disabled(!host.online || !hasOrigin)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(remoteHosts.first { $0.id == hostID }?.name ?? L("This Mac"))
                    Image(systemName: "chevron.up.chevron.down").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
                }
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect(cornerRadius: Theme.Radius.control))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(draft.isCreating || created != nil)
        }
        .task {
            let repository = project.path
            hasOrigin = await Task.detached { Git.originURL(of: repository) != nil }.value
        }
    }

    /// Connects to the picked host, so the name is checked and the worktree made there.
    private func reach(_ host: UUID?) async {
        if draft.host != nil { draft.host = nil }
        guard let host else { return }
        do {
            let git = try await store.gitHost(host)
            guard !Task.isCancelled else { return }
            draft.host = git
        } catch {
            guard !Task.isCancelled else { return }
            draft.error = error.localizedDescription
        }
    }

    /// The problem with the name, or what creating it will do. Kept while a new check runs, so
    /// the line doesn't flicker as the user types.
    private var message: String? {
        if let problem = draft.problem { return problem }
        guard let check = draft.check else { return nil }
        let start: String
        switch check.start {
        case .existingBranch: start = L("Continues the existing branch \(check.branch).")
        case .remoteBranch(let remote): start = L("Continues the existing branch \(remote).")
        case .newBranch(let base?): start = L("Starts \(check.branch) from \(base).")
        case .newBranch(nil): start = L("Starts \(check.branch) from the current commit.")
        }
        return start + " " + L("Creates \(abbreviated(check.location.path))")
    }

    private func submit() {
        draft.submitTask = Task { await draft.submit() }
    }

    private func finish(_ worktree: Worktree) {
        dismiss()
        onAdded(worktree)
    }

    private func abbreviated(_ path: String) -> String {
        DisplayPath.short(path, base: draft.host?.knownClone(of: project.path) ?? project.path)
    }
}

/// What the New Worktree dialog knows about the typed name. Checking and creating run git, so
/// both happen off the main thread; checks run after typing pauses. Creating happens at most
/// once at a time, and a submit that arrives while the name is being checked waits for it.
@MainActor @Observable
final class WorktreeDraft {
    struct Check: Equatable {
        /// The trimmed name this check is for.
        var name: String
        var branch: String
        var location: URL
        var problem: String?
        var start: Git.WorktreeStart
        /// The folder the message is about, in full, for its tooltip.
        var fullPath: String

        init(name: String, branch: String, location: URL, problem: String? = nil, start: Git.WorktreeStart, fullPath: String? = nil) {
            (self.name, self.branch, self.location, self.problem, self.start) = (name, branch, location, problem, start)
            self.fullPath = fullPath ?? location.path
        }

        /// Creating continues a branch that already exists rather than starting one.
        var continuesBranch: Bool {
            if case .newBranch = start { return false }
            return true
        }
    }

    let repository: String
    /// The host the worktree is made on; nil is this Mac. Checks made for another don't count.
    var host: GitHost? {
        didSet {
            check = nil
            error = nil
            revision += 1
        }
    }
    var name = "" {
        didSet {
            // Return rewrites the binding with the same text; that isn't an edit.
            guard name != oldValue else { return }
            error = nil
            wantsSubmit = false
            revision += 1
        }
    }
    /// The latest finished check; may be for an earlier name while a new one runs.
    private(set) var check: Check?
    private(set) var isCreating = false
    /// Changes whenever the name should be checked again.
    private(set) var revision = 0
    var error: String?
    /// Called on the main actor with what was created.
    var onCreated: ((Git.CreatedWorktree) -> Void)?
    /// The running submit, so Cancel can stop git.
    var submitTask: Task<Void, Never>?
    private var wantsSubmit = false

    init(repository: String) { self.repository = repository }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The current name's problem, if the latest check is for it.
    var problem: String? { check?.name == trimmedName ? check?.problem : nil }

    func validate() async {
        let name = trimmedName, repository = repository, host = host
        guard !name.isEmpty else { check = nil; return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, !isCreating else { return }
        let result = await Task.detached { Self.inspect(name, in: repository, on: host) }.value
        guard !Task.isCancelled, !isCreating, result.name == trimmedName else { return }
        check = result
        if wantsSubmit {
            wantsSubmit = false
            // Continuing an existing branch is shown first: an Enter typed before the user could
            // read that doesn't confirm it.
            if !result.continuesBranch { await submit() }
        }
    }

    /// Creates the worktree for the current name, or, while the name is still being checked,
    /// as soon as the check passes.
    func submit() async {
        guard !isCreating, !trimmedName.isEmpty else { return }
        guard let check, check.name == trimmedName else { wantsSubmit = true; return }
        guard check.problem == nil else { return }
        isCreating = true
        error = nil
        let branch = check.branch, repository = repository, host = host
        let work = Task.detached {
            try host.map { try Git.createWorktree(branch: branch, in: repository, on: $0) } ?? Git.createWorktree(branch: branch, in: repository)
        }
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            onCreated?(result)
        } catch is CancellationError {
            isCreating = false
        } catch {
            isCreating = false
            self.error = Self.cause(of: error.localizedDescription)
            // What's on disk may have changed (or the branch is now known): check again.
            revision += 1
        }
    }

    func cancel() {
        submitTask?.cancel()
    }

    /// What decides the branch and folder for `name`: the name itself when a branch has
    /// exactly that name (locally or on a remote); otherwise a slug of it, numbered past folders
    /// and branches already taken. Branch names are compared ignoring case, as the volume may.
    /// On `host` the folder goes beside its clone of the repository, and what that clone already
    /// has (worktrees, folders, branches) is taken too; where the branch starts is still decided
    /// here, as for a worktree on this Mac.
    nonisolated static func inspect(_ name: String, in repository: String, on host: GitHost? = nil) -> Check {
        let home = host?.clone(of: repository) ?? repository
        func there<T>(_ body: () -> T) -> T { Git.$host.withValue(host, operation: body) }
        let locals = ((Git.refs("refs/heads/", in: repository) ?? []) + (host == nil ? [] : there { Git.refs("refs/heads/", in: home) } ?? []))
            .map { String($0.dropFirst("refs/heads/".count)) }
        let open = there { Git.worktrees(at: home) } ?? []
        let same = { (a: String, b: String) in a.caseInsensitiveCompare(b) == .orderedSame }

        if Git.isValidBranchName(name) {
            let start = Git.worktreeStart(for: name, in: repository)
            if case .newBranch = start {} else {
                let location = Git.worktreeLocation(for: name, in: home)
                if let other = open.first(where: { $0.branch.map { same($0, name) } ?? false }) {
                    return Check(name: name, branch: name, location: location,
                                 problem: L("\(name) is already open in \(DisplayPath.short(other.path, base: home))."),
                                 start: start, fullPath: other.path)
                }
                if there({ Git.exists(location.path) }) {
                    return Check(name: name, branch: name, location: location,
                                 problem: L("\(DisplayPath.short(location.path, base: home)) already exists. Pick another name."), start: start)
                }
                return Check(name: name, branch: name, location: location, start: start)
            }
        }
        let base = slug(name).nonEmptyOr("worktree")
        guard Git.headCommit(in: repository) != nil else {
            return Check(name: name, branch: base, location: Git.worktreeLocation(for: base, in: home),
                         problem: L("The repository has no commits yet. Make a first commit, then add worktrees."), start: .newBranch(from: nil))
        }
        for number in 1 ... 99 {
            let branch = number == 1 ? base : "\(base)-\(number)"
            let location = Git.worktreeLocation(for: branch, in: home)
            // Taken: a folder there, or a branch with this name, inside it ("x/y"), or holding it ("x" for "x/y").
            let clashes = locals.contains { same($0, branch) || $0.lowercased().hasPrefix(branch.lowercased() + "/") || branch.lowercased().hasPrefix($0.lowercased() + "/") }
            guard !clashes, !there({ Git.exists(location.path) }), Git.isValidBranchName(branch) else { continue }
            let start = Git.worktreeStart(for: branch, in: repository)
            guard case .newBranch = start else { continue }
            return Check(name: name, branch: branch, location: location, start: start)
        }
        return Check(name: name, branch: base, location: Git.worktreeLocation(for: base, in: home),
                     problem: L("Too many worktrees already use this name. Pick another name."), start: .newBranch(from: nil))
    }

    /// "Fix the Login redirect!" → "fix-the-login-redirect"; other scripts are transliterated
    /// ("Исправить вход" → "ispravit-vhod"). Empty when nothing usable is left (emoji only).
    nonisolated static func slug(_ name: String) -> String {
        let latin = name.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Lower"), reverse: false) ?? name.lowercased()
        var slug = ""
        // Whole words only, up to 60 characters.
        for word in latin.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }) {
            let next = slug.isEmpty ? String(word) : slug + "-" + word
            if next.count > 60 { return slug.isEmpty ? String(word.prefix(60)) : slug }
            slug = next
        }
        return slug
    }

    /// git's message without its progress chatter ("Preparing worktree…", "HEAD is now at…").
    nonisolated static func cause(of message: String) -> String {
        let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Preparing worktree") && !$0.hasPrefix("HEAD is now at") }
        return lines.isEmpty ? L("git stopped without saying why; often a hook that failed without output.") : lines.joined(separator: "\n")
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// An error under a dialog's form, selectable so it can be copied, wrapping to show all of it.
struct DialogError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.danger)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, DialogLayout.labelWidth + DialogLayout.gap)
    }
}
