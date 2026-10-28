import AppKit
import SwiftUI

/// Add Project, modeled on Orca: pick how to start (clone, create, open), then fill in that form.
struct AddProjectDialog: View {
    let store: ProjectStore
    /// Called with the project that was added, after the dialog closes.
    let onAdded: (Project) -> Void
    /// Where the dialog opens; the welcome screen jumps straight to a form.
    let initialStep: Step

    @Environment(\.dismiss) private var dismiss
    @AppStorage("projectLocation") private var location = AddProjectDialog.defaultLocation

    @State private var step: Step
    @State private var cloneURL = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var isWorking = false
    @State private var progress: String?
    @State private var errorMessage: String?
    @State private var cloneTask: Task<Void, Never>?

    static let defaultLocation = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("agentboard/projects").path

    enum Step: Identifiable {
        case choose, clone, create
        var id: Self { self }
    }

    init(store: ProjectStore, initialStep: Step = .choose, onAdded: @escaping (Project) -> Void) {
        self.store = store
        self.onAdded = onAdded
        self.initialStep = initialStep
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        Group {
            switch step {
            case .choose: chooseStep
            case .clone: cloneStep
            case .create: createStep
            }
        }
        .transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: Steps

    private var chooseStep: some View {
        AppDialog(title: L("Add Project"), subtitle: L("Start from a remote repository, a new one, or a folder on this Mac.")) {
            HStack(spacing: 12) {
                ChoiceTile(symbol: "arrow.down.circle", title: L("Clone from URL"),
                           detail: L("Copy a git repository from GitHub, GitLab, or any remote.")) { go(.clone) }
                ChoiceTile(symbol: "plus.square.dashed", title: L("Create New"),
                           detail: L("Start an empty repository with a first commit on main.")) { go(.create) }
                ChoiceTile(symbol: "folder", title: L("Open Folder"),
                           detail: L("Add a project that already exists on this Mac."), action: openFolder)
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var cloneStep: some View {
        AppDialog(title: L("Clone from URL")) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("URL")) {
                    TextField("", text: $cloneURL, prompt: Text("https://github.com/owner/repo.git"))
                        .onChange(of: cloneURL) { _, url in
                            if !nameEdited { name = Self.repositoryName(from: url) }
                        }
                }
                nameRow
                locationRow
                statusLine
            }
            .disabled(isWorking)
        } footer: {
            backButton
            Spacer()
            if isWorking {
                Button(L("Stop"), role: .cancel) { cloneTask?.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Button(L("Clone"), action: clone)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || Self.repositoryName(from: cloneURL).isEmpty || isWorking)
        }
    }

    private var createStep: some View {
        AppDialog(title: L("Create New Project")) {
            VStack(alignment: .leading, spacing: 14) {
                nameRow
                locationRow
                statusLine
            }
            .disabled(isWorking)
        } footer: {
            backButton
            Spacer()
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Create"), action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
        }
    }

    // MARK: Shared rows

    private var nameRow: some View {
        FormRow(label: L("Name"), message: destinationConflict, isError: destinationConflict != nil) {
            TextField("", text: Binding(get: { name }, set: { name = $0; nameEdited = true }),
                      prompt: Text("my-project"))
        }
    }

    private var locationRow: some View {
        FormRow(label: L("Location"), message: destination.map { L("Creates \(abbreviated($0.path))") }) {
            HStack(spacing: 8) {
                Text(abbreviated(location))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Change…"), action: chooseLocation)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(.leading, 84)
        } else if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress ?? L("Starting…"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 84)
        }
    }

    @ViewBuilder
    private var backButton: some View {
        if initialStep == .choose {
        Button {
            errorMessage = nil
            go(.choose)
        } label: {
            Label(L("Back"), systemImage: "chevron.left")
        }
        .disabled(isWorking)
        }
    }

    // MARK: Validation

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var destination: URL? {
        guard !trimmedName.isEmpty, !trimmedName.contains("/") else { return nil }
        return URL(fileURLWithPath: location).appendingPathComponent(trimmedName)
    }

    private var destinationConflict: String? {
        if trimmedName.contains("/") { return L("Name can't contain “/”.") }
        guard let destination, FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return L("A folder with this name already exists here. Pick another name or location.")
    }

    private var canSubmit: Bool { destination != nil && destinationConflict == nil }

    // MARK: Actions

    private func go(_ next: Step) {
        withAnimation(.snappy(duration: 0.3)) { step = next }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Add Project")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        finish(with: url)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: location)
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            location = url.path
        }
    }

    private func create() {
        guard let destination else { return }
        errorMessage = nil
        do {
            try Git.createRepository(at: destination)
            finish(with: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clone() {
        guard let destination else { return }
        let url = cloneURL.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        progress = nil
        isWorking = true
        cloneTask = Task {
            do {
                try await Git.clone(url, into: destination) { line in
                    Task { @MainActor in progress = line }
                }
                isWorking = false
                finish(with: destination)
            } catch is CancellationError {
                isWorking = false
                // Leave nothing half-cloned behind.
                try? FileManager.default.removeItem(at: destination)
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    private func finish(with url: URL) {
        guard let project = store.addProject(at: url) else { return }
        dismiss()
        onAdded(project)
    }

    // MARK: Helpers

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// "https://github.com/owner/repo.git" or "git@host:owner/repo" → "repo".
    static func repositoryName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last else { return "" }
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : String(last)
        return name == trimmed ? "" : name
    }
}
