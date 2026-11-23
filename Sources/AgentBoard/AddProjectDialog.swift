import AppKit
import SwiftUI
import Orchestration

/// Add Project, modeled on Orca: pick how to start (clone, create, open), then fill in that form.
struct AddProjectDialog: View {
    let store: ProjectStore
    /// Called with the project that was added, after the dialog closes.
    let onAdded: (Project) -> Void
    /// Where the dialog opens; the welcome screen jumps straight to a form.
    let initialStep: Step

    @Environment(\.dismiss) private var dismiss
    @AppStorage("projectLocation", store: AppDefaults.shared) private var location = AddProjectDialog.defaultLocation

    @State private var step: Step
    @State private var cloneURL = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var isWorking = false
    @State private var progress: String?
    @State private var errorMessage: String?
    /// The full path an error's short form names, for its tooltip.
    @State private var errorPath: String?
    @State private var cloneTask: Task<Void, Never>?
    /// The repository this dialog made or cloned, once it exists: it never reads back as a
    /// conflict, and Create then only retries adding it to the list.
    @State private var created: URL?
    /// Added although its first commit failed: the dialog stays to say so.
    @State private var addedWithoutCommit: Project?

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
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
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
                .buttonStyle(DialogButtonStyle(prominent: true))
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
            if let project = addedWithoutCommit {
                Button(L("Open Project")) {
                    dismiss()
                    onAdded(project)
                }
                .buttonStyle(DialogButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            } else if let created {
                Button(L("Add to List")) { finish(with: created) }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L("Create"), action: create)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
    }

    // MARK: Shared rows

    private var nameRow: some View {
        FormRow(label: L("Name"), message: destinationConflict, isError: destinationConflict != nil) {
            TextField("", text: Binding(get: { name }, set: { name = $0; nameEdited = true }),
                      prompt: Text("my-project"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }

    private var locationRow: some View {
        FormRow(label: L("Location"), message: destination.map { L("Creates \(abbreviated($0.path))") }) {
            HStack(spacing: 8) {
                Text(abbreviated(location))
                    .help(location)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Change…"), action: chooseLocation)
                    .buttonStyle(DialogButtonStyle())
            }
        }
        .help(destination?.path ?? location)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorMessage {
            DialogError(message: errorMessage)
                .help(errorPath ?? "")
        } else if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress ?? L("Starting…"))
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            .padding(.leading, DialogLayout.labelWidth + DialogLayout.gap)
        }
    }

    @ViewBuilder
    private var backButton: some View {
        if initialStep == .choose {
        Button {
            errorMessage = nil
            errorPath = nil
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
        guard !trimmedName.isEmpty, Self.nameProblem(trimmedName) == nil else { return nil }
        return URL(fileURLWithPath: location).appendingPathComponent(trimmedName)
    }

    private var destinationConflict: String? {
        if let problem = Self.nameProblem(trimmedName) { return problem }
        guard created == nil, !isWorking, let destination, FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return L("A folder with this name already exists here. Pick another name or location.")
    }

    private var canSubmit: Bool { created == nil && !isWorking && destination != nil && destinationConflict == nil }

    /// Why `name` can't be a project folder's name: "." and ".." aren't new folders, a leading
    /// dot hides it, and "/" or ":" would make it a path.
    static func nameProblem(_ name: String) -> String? {
        if name.contains("/") || name.contains(":") { return L("Name can't contain “/” or “:”.") }
        if name.hasPrefix(".") { return L("Name can't start with “.”.") }
        return nil
    }

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
        guard canSubmit, let destination else { return }
        errorMessage = nil
        errorPath = nil
        isWorking = true
        Task {
            do {
                // Off the main thread; on failure it removes the folder it made, so a retry works.
                try await Task.detached { try Git.createRepository(at: destination) }.value
                created = destination
                isWorking = false
                finish(with: destination)
            } catch let failure as Git.InitialCommitFailed {
                // The repository exists: keep it, add it, and say what's missing.
                isWorking = false
                created = destination
                guard let project = store.addProject(at: destination) else {
                    errorPath = destination.path
                    errorMessage = L("The repository is at \(abbreviated(destination.path)), but it couldn't be added to the list. Try again, or add it later with Open Folder.")
                    return
                }
                addedWithoutCommit = project
                errorMessage = L("Initial commit failed: \(WorktreeDraft.cause(of: failure.cause)) The project was added without it; fix the problem (often commit signing) and commit in its folder.")
            } catch {
                isWorking = false
                errorMessage = WorktreeDraft.cause(of: error.localizedDescription)
            }
        }
    }

    private func clone() {
        guard canSubmit, let destination else { return }
        let url = cloneURL.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        errorPath = nil
        progress = nil
        isWorking = true
        cloneTask = Task {
            do {
                try await Git.clone(url, into: destination) { line in
                    Task { @MainActor in progress = line }
                }
                created = destination
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
        guard let project = store.addProject(at: url) else {
            errorPath = url.path
            errorMessage = L("The repository is at \(abbreviated(url.path)), but it couldn't be added to the list. Try again, or add it later with Open Folder.")
            return
        }
        dismiss()
        onAdded(project)
    }

    // MARK: Helpers

    private func abbreviated(_ path: String) -> String {
        DisplayPath.short(path)
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
