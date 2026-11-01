import AppKit
import Orchestration
import SwiftUI

/// Asks what a new runner runs: its name, the command (which the folder's package scripts can
/// fill in), and the folder it runs in, the worktree unless changed. Without a command it opens
/// the login shell, to use as an ordinary terminal.
struct RunnerDialog: View {
    let worktree: String
    let onDone: (_ command: String, _ name: String?, _ directory: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var command = ""
    @State private var scripts: [PackageScript] = []

    var body: some View {
        AppDialog(title: L("New runner")) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("Name")) {
                    TextField("", text: $name, prompt: Text(AgentRecord.runnerName(for: trimmedCommand)))
                }
                if !scripts.isEmpty {
                    FormRow(label: L("Script")) {
                        ScriptSelect(scripts: scripts, command: $command)
                    }
                }
                FormRow(label: L("Command"), message: trimmedCommand.isEmpty ? L("Empty: opens a plain shell to type into.") : nil) {
                    TextField("", text: $command, prompt: Text("npm run dev"))
                        .font(.callout.monospaced())
                }
                FormRow(label: L("Folder")) { folderLine }
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(trimmedCommand.isEmpty ? L("Open terminal") : L("Start runner")) {
                onDone(trimmedCommand, name.trimmingCharacters(in: .whitespaces), folder)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { folder = worktree }
        .onChange(of: folder) { _, folder in loadScripts(in: folder) }
    }

    /// The folder: its path, a way back to the worktree, and Change….
    private var folderLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text((folder as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(folder)
            if folder != worktree {
                Button { folder = worktree } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(L("Back to the worktree's folder"))
            }
            Button(L("Change…"), action: chooseFolder)
        }
    }

    private var trimmedCommand: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Reads the folder's scripts and fills in the one most likely wanted (`dev`, `start`…).
    private func loadScripts(in folder: String) {
        let previous = scripts.first { $0.command == command }
        scripts = PackageScript.read(in: folder)
        let pick = scripts.first { $0.name == previous?.name } ?? PackageScript.likeliest(in: scripts)
        // A command typed by hand stays; one taken from the old folder's scripts follows the new folder.
        if command.isEmpty || previous != nil { command = pick?.command ?? "" }
    }

    /// Opens on the worktree's folder, wherever the runner runs now.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: worktree)
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

/// A pop-up of the folder's scripts that fills in the command. Its list shows five scripts at a
/// time and scrolls for the rest.
private struct ScriptSelect: View {
    let scripts: [PackageScript]
    @Binding var command: String
    @State private var isOpen = false

    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 5

    /// The script the command field holds, if it holds one (not a command typed by hand).
    private var picked: PackageScript? { scripts.first { $0.command == command } }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                Text(picked?.name ?? L("Choose a script"))
                    .foregroundStyle(picked == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(scripts) { script in
                        ScriptRow(script: script, picked: script == picked, height: Self.rowHeight) {
                            command = script.command
                            isOpen = false
                        }
                        .id(script.name)
                    }
                }
                .padding(4)
            }
            .frame(width: 340, height: Self.rowHeight * CGFloat(min(scripts.count, Self.visibleRows)) + 8)
            .onAppear { if let picked { proxy.scrollTo(picked.name, anchor: .center) } }
        }
    }
}

/// One script in the pop-up: its name, and what it runs.
private struct ScriptRow: View {
    let script: PackageScript
    let picked: Bool
    let height: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(script.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(picked ? Theme.accent : .primary)
                Spacer(minLength: 0)
                Text(script.body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) { isHovered = hovering }
        }
    }

    private var fill: Color {
        if picked { return Theme.accent.opacity(0.1) }
        return Color.primary.opacity(isHovered ? 0.06 : 0)
    }
}

/// A script from a folder's package.json, with the command that runs it.
struct PackageScript: Identifiable, Hashable {
    let name: String
    /// What the script does, as package.json has it.
    let body: String
    /// How to run it with the project's package manager, e.g. `pnpm dev`.
    let command: String

    var id: String { name }

    /// Every script, alphabetically.
    static func read(in folder: String) -> [PackageScript] {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        let manager = packageManager(in: folder)
        return scripts.keys.sorted().map { name in
            PackageScript(name: name, body: scripts[name] ?? "", command: manager == "npm" ? "npm run \(name)" : "\(manager) \(name)")
        }
    }

    /// The script that most likely starts the project: `dev`, then `start`, `serve`…
    static func likeliest(in scripts: [PackageScript]) -> PackageScript? {
        let preferred = ["dev", "start", "serve", "watch", "preview", "storybook"]
        return preferred.lazy.compactMap { name in scripts.first { $0.name == name } }.first ?? scripts.first
    }

    /// The package manager whose lockfile the project has; npm when none. A package inside a
    /// monorepo uses the lockfile at the repository's root.
    private static func packageManager(in folder: String) -> String {
        let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun")]
        var directory = folder
        while true {
            if let match = lockfiles.first(where: { FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent($0.0)) }) {
                return match.1
            }
            if FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) || directory == "/" { return "npm" }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }
}
