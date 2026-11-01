import SwiftUI

/// Adds a worktree to a project: the branch it works on, checked out if the repository has it,
/// started from HEAD if not.
struct NewWorktreeDialog: View {
    let store: ProjectStore
    let project: Project
    /// Called with the worktree that was added, after the dialog closes.
    let onAdded: (Worktree) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var errorMessage: String?

    var body: some View {
        AppDialog(title: L("New Worktree"), subtitle: project.name) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("Branch"), message: branchMessage, isError: branchProblem != nil) {
                    TextField("", text: $branch, prompt: Text("feature/my-change"))
                        .onSubmit(create)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.leading, 84)
                }
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Create"), action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .onChange(of: branch) { errorMessage = nil }
    }

    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }

    private var location: URL { Git.worktreeLocation(for: trimmedBranch, in: project.path) }

    private var branchProblem: String? {
        guard !trimmedBranch.isEmpty else { return nil }
        if !Git.isValidBranchName(trimmedBranch) { return L("Git doesn't accept this as a branch name.") }
        if FileManager.default.fileExists(atPath: location.path) {
            return L("\(abbreviated(location.path)) already exists. Pick another branch name.")
        }
        return nil
    }

    /// The problem with the branch, or what creating it will do.
    private var branchMessage: String? {
        if let branchProblem { return branchProblem }
        guard !trimmedBranch.isEmpty else { return nil }
        let start: String
        switch Git.worktreeStart(for: trimmedBranch, in: project.path) {
        case .existingBranch:
            start = L("Checks out the existing branch.")
        case .newBranch(let base?):
            start = L("Starts a new branch from \(base).")
        case .newBranch(nil):
            start = L("Starts a new branch from the current commit.")
        }
        return start + " " + L("Creates \(abbreviated(location.path))")
    }

    private var canSubmit: Bool { !trimmedBranch.isEmpty && branchProblem == nil }

    private func create() {
        guard canSubmit else { return }
        do {
            let worktree = try store.addWorktree(branch: trimmedBranch, to: project)
            dismiss()
            if let worktree { onAdded(worktree) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
