import Observation
import SwiftUI

/// Adds a worktree to a project. The user names what they'll work on; the branch and folder
/// are derived from that name, and the name becomes the worktree's title.
struct NewWorktreeDialog: View {
    let store: ProjectStore
    let project: Project
    /// Called with the worktree that was added, after the dialog closes.
    let onAdded: (Worktree) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorktreeDraft

    init(store: ProjectStore, project: Project, onAdded: @escaping (Worktree) -> Void) {
        self.store = store
        self.project = project
        self.onAdded = onAdded
        _draft = State(initialValue: WorktreeDraft(repository: project.path))
    }

    var body: some View {
        AppDialog(title: L("New Worktree"), subtitle: project.name) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("Name"), message: message, isError: draft.problem != nil) {
                    TextField("", text: $draft.name, prompt: Text(L("Fix the login redirect")))
                        .onSubmit(create)
                }
                if let error = draft.error {
                    DialogError(message: error)
                }
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Create"), action: create)
                .buttonStyle(DialogButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSubmit)
        }
        // Restarts on each keystroke, so only the last one is checked (see WorktreeDraft).
        .task(id: draft.name) { await draft.validate() }
    }

    /// The problem with the name, or what creating it will do.
    private var message: String? {
        if let problem = draft.problem { return problem }
        guard let check = draft.check, check.branch == draft.branch else { return nil }
        let start: String
        switch check.start {
        case .existingBranch: start = L("Continues the existing branch \(check.branch).")
        case .newBranch(let base?): start = L("Starts \(check.branch) from \(base).")
        case .newBranch(nil): start = L("Starts \(check.branch) from the current commit.")
        }
        return start + " " + L("Creates \(abbreviated(check.location.path))")
    }

    private func create() {
        var added: Worktree?
        guard draft.create(using: { added = try store.addWorktree(branch: $0, to: project) }) else { return }
        dismiss()
        if let added {
            // Hook for F3's worktree titles: the typed name is the title, the slug only the folder.
            store.rename(added, to: draft.trimmedName)
            onAdded(added)
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// What the New Worktree dialog knows about the typed name. Checking runs git, so it happens
/// off the main thread, after typing pauses; once creation starts the check is frozen, so the
/// folder just created never reads back as a conflict.
@MainActor @Observable
final class WorktreeDraft {
    struct Check: Equatable {
        var branch: String
        var location: URL
        var problem: String?
        var start: Git.WorktreeStart
    }

    let repository: String
    var name = "" { didSet { if !isCreating { error = nil } } }
    private(set) var check: Check?
    private(set) var isCreating = false
    var error: String?

    init(repository: String) { self.repository = repository }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var branch: String { Self.slug(trimmedName) }

    /// The current name's problem; nil while it's being checked.
    var problem: String? {
        if !trimmedName.isEmpty && branch.isEmpty { return L("Use at least one letter or number.") }
        return check?.branch == branch ? check?.problem : nil
    }

    var canSubmit: Bool { !isCreating && !branch.isEmpty && check?.branch == branch && check?.problem == nil }

    func validate() async {
        let branch = branch, repository = repository
        guard !branch.isEmpty else { check = nil; return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, !isCreating else { return }
        let result = await Task.detached { Self.inspect(branch, in: repository) }.value
        guard !Task.isCancelled, !isCreating else { return }
        check = result
    }

    /// Runs `add` with the branch once; true when it succeeded. Later calls do nothing.
    func create(using add: (String) throws -> Void) -> Bool {
        guard canSubmit else { return false }
        isCreating = true
        do {
            try add(branch)
            return true
        } catch {
            isCreating = false
            self.error = error.localizedDescription
            return false
        }
    }

    nonisolated static func inspect(_ branch: String, in repository: String) -> Check {
        let location = Git.worktreeLocation(for: branch, in: repository)
        var problem: String?
        if !Git.isValidBranchName(branch) {
            problem = L("This name can't be used for a branch. Try other words.")
        } else if FileManager.default.fileExists(atPath: location.path) {
            problem = L("\((location.path as NSString).abbreviatingWithTildeInPath) already exists. Pick another name.")
        }
        let start = problem == nil ? Git.worktreeStart(for: branch, in: repository) : .newBranch(from: nil)
        return Check(branch: branch, location: location, problem: problem, start: start)
    }

    /// "Fix the Login redirect!" → "fix-the-login-redirect".
    nonisolated static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return String(words.joined(separator: "-").prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// An error under a dialog's form, selectable so it can be copied.
struct DialogError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.danger)
            .textSelection(.enabled)
            .padding(.leading, DialogLayout.labelWidth + DialogLayout.gap)
    }
}
