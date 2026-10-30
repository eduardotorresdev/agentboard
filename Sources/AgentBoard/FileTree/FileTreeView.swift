import AppKit
import Observation
import SwiftUI

/// How a file tree card's hosted views are sized: the card's content at zoom 1, and the zoom.
@MainActor
@Observable
final class FileTreeHost {
    var size: CGSize = .zero
    var zoom: CGFloat = 1
}

/// Draws `content` at its size at zoom 1, scaled to the board's zoom.
struct Zoomed<Content: View>: View {
    let host: FileTreeHost
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: host.size.width, height: host.size.height)
            .scaleEffect(host.zoom, anchor: .topLeading)
            .frame(width: host.size.width * host.zoom, height: host.size.height * host.zoom, alignment: .topLeading)
    }
}

/// The inside of a file tree card: the worktree's folders on the left, the open file on the right.
struct FileTreeView: View {
    let store: FileTreeStore
    let id: UUID
    let model: FileBrowserModel

    var body: some View {
        HStack(spacing: 0) {
            FileTreeSidebar(model: model)
                .frame(width: 260)
                .background(Theme.line.opacity(0.035))
            FileContentView(store: store, id: id, model: model)
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct FileTreeSidebar: View {
    let model: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(model.rows, id: \.entry.id) { row in
                            FileRow(entry: row.entry, depth: row.depth, model: model, label: row.entry.name)
                        }
                    } else {
                        ForEach(model.matches) { entry in
                            FileRow(entry: entry, depth: 0, model: model, label: entry.path)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search files"), text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(.plain)
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Reads the folders and the git status again."))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.line.opacity(0.12)))
            .padding(8)
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let depth: Int
    let model: FileBrowserModel
    let label: String
    @State private var isHovered = false

    var body: some View {
        let selected = model.openFile == entry.path
        let status = model.status[entry.path]
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(model.expanded.contains(entry.path) ? 90 : 0))
                .opacity(entry.isFolder ? 0.5 : 0)
                .frame(width: 10)
            Image(systemName: entry.isFolder ? "folder.fill" : Self.symbol(for: entry.name))
                .font(.system(size: 12))
                .foregroundStyle(entry.isFolder ? Theme.accent.opacity(0.75) : Color.secondary)
                .frame(width: 16)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(status.map(Self.color) ?? Color.primary.opacity(0.85))
            Spacer(minLength: 4)
            if let status {
                Text(String(status))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.color(status))
            }
        }
        .font(.system(size: 12.5))
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(selected ? Theme.accent.opacity(0.14) : isHovered ? Theme.line.opacity(0.06) : .clear,
                    in: .rect(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) {
                if entry.isFolder { model.toggle(entry.path) } else { model.open(entry.path) }
            }
        }
    }

    static func color(_ status: Character) -> Color {
        switch status {
        case "U", "A": Theme.accent
        case "D": .red
        default: Theme.secondary
        }
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns": "photo"
        case "md", "txt": "doc.text"
        case "json", "yml", "yaml", "toml", "plist": "curlybraces"
        case "": "doc"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// The open file, numbered; clicking a line number selects it (shift extends) to annotate it.
private struct FileContentView: View {
    let store: FileTreeStore
    let id: UUID
    let model: FileBrowserModel
    @State private var selection: ClosedRange<Int>?
    @State private var anchor: Int?
    @State private var draft = ""
    @FocusState private var isWriting: Bool

    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.content {
            case .lines(let lines): code(lines)
            case .binary: notice("doc.badge.ellipsis", L("This file is binary and can't be shown."))
            case .tooLarge: notice("exclamationmark.triangle", L("This file is too large to show."))
            case .unreadable: notice("exclamationmark.triangle", L("This file can't be read."))
            case nil: notice("doc.text.magnifyingglass", L("Pick a file to read it and annotate its lines."))
            }
        }
        .onChange(of: model.openFile) { _, _ in
            selection = nil
            anchor = nil
            draft = ""
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.openFile ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
            Spacer()
            if model.openFile != nil {
                Button(action: model.closeFile) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Closes the file."))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func notice(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(Theme.accent.opacity(0.6))
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func code(_ lines: [String]) -> some View {
        let notes = (store.annotations[id] ?? []).filter { $0.path == model.openFile }
        let gutter = CGFloat(String(lines.count).count) * 7.5 + 22
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let number = index + 1
                    line(number, lines[index], gutter: gutter, noted: notes.contains { $0.lines.contains(number) })
                    ForEach(notes.filter { $0.lines.upperBound == number }) { note in
                        NoteView(note: note) { store.removeAnnotation(note.id, from: id) }
                            .padding(.leading, gutter + 8)
                    }
                    if let selection, selection.upperBound == number {
                        composer(lines, selection: selection)
                            .padding(.leading, gutter + 8)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func line(_ number: Int, _ text: String, gutter: CGFloat, noted: Bool) -> some View {
        let selected = selection?.contains(number) ?? false
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Capsule().fill(Theme.accent).frame(width: 3, height: 14).opacity(noted ? 1 : 0)
                Text("\(number)")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: gutter)
            .contentShape(.rect)
            .onTapGesture { select(number) }
            .help(L("Select the line to annotate it; shift-click to select several."))
            Text(text.isEmpty ? " " : text)
                .fixedSize()
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .textSelection(.enabled)
        }
        .font(Self.font)
        .frame(height: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.12) : .clear)
    }

    private func composer(_ lines: [String], selection: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(selection.count == 1 ? L("Line \(selection.lowerBound)") : L("Lines \(selection.lowerBound)–\(selection.upperBound)"),
                  systemImage: "text.bubble")
                .font(.system(size: 12, weight: .semibold))
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Add a note for the agents…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isWriting)
                    .onSubmit { add(lines, selection: selection) }
                    .padding(8)
                    .background(Theme.surface, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line.opacity(0.14)))
                Button { add(lines, selection: selection) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(L("Keeps the note; send every note at once from below the card."))
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .background(Theme.canvas, in: .rect(cornerRadius: 12))
        .shadow(color: Theme.line.opacity(0.14), radius: 10, y: 4)
        .padding(.vertical, 6)
        .onAppear { isWriting = true }
        .onExitCommand { withAnimation(.snappy(duration: 0.2)) { self.selection = nil } }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
    }

    private func select(_ number: Int) {
        withAnimation(.snappy(duration: 0.2)) {
            if NSEvent.modifierFlags.contains(.shift), let anchor {
                selection = min(anchor, number)...max(anchor, number)
            } else if selection == number...number {
                selection = nil
                anchor = nil
            } else {
                selection = number...number
                anchor = number
            }
        }
    }

    private func add(_ lines: [String], selection: ClosedRange<Int>) {
        let comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty, let path = model.openFile else { return }
        let excerpt = lines[(selection.lowerBound - 1)...(min(selection.upperBound, lines.count) - 1)].joined(separator: "\n")
        store.annotate(FileAnnotation(path: path, lines: selection, excerpt: excerpt, comment: comment), on: id)
        draft = ""
        withAnimation(.snappy(duration: 0.2)) {
            self.selection = nil
            anchor = nil
        }
    }
}

private struct NoteView: View {
    let note: FileAnnotation
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
            Text(note.comment).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Removes the note."))
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(width: 440, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 10))
        .padding(.vertical, 4)
    }
}

/// Below a card with notes: sends them all to the connected agents.
struct SendAnnotationsBar: View {
    let store: FileTreeStore
    let id: UUID

    var body: some View {
        let count = store.annotations[id]?.count ?? 0
        let agents = store.connectedAgents(of: id)
        HStack(spacing: 4) {
            Button { store.sendAnnotations(of: id) } label: {
                Label(count == 1 ? L("Send 1 note") : L("Send \(count) notes"), systemImage: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Theme.accent.opacity(agents.isEmpty ? 0.4 : 1), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(agents.isEmpty)
            .help(agents.isEmpty ? L("Connect an agent to this card to send it the notes.")
                                 : L("Sends every note to \(agents.map(\.name).joined(separator: ", "))."))
            Button { store.clearAnnotations(of: id) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Discards the notes."))
        }
        .padding(4)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: Theme.line.opacity(0.14), radius: 10, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
