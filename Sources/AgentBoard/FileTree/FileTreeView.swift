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

/// The open file, numbered and colored. Dragging over lines selects them, Command adds more
/// lines to the selection, and Shift extends it; the selection takes a note for the agents.
private struct FileContentView: View {
    let store: FileTreeStore
    let id: UUID
    let model: FileBrowserModel
    @State private var selection: Set<Int> = []
    @State private var anchor: Int?
    @State private var drag: (start: Int, base: Set<Int>, previous: Set<Int>, moved: Bool)?
    @State private var lineTops: [Int: CGFloat] = [:]
    @State private var draft = ""
    @FocusState private var isWriting: Bool

    private static let font = Font.system(size: 12, design: .monospaced)
    private static let lineHeight: CGFloat = 18
    private static let space = "code"

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
            selection = []
            anchor = nil
            drag = nil
            lineTops = [:]
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
        let noted = Set(notes.flatMap(\.lines))
        let gutter = CGFloat(String(lines.count).count) * 7.5 + 22
        let colored = model.highlighted.count == lines.count ? model.highlighted : nil
        let composerLine = drag == nil ? selection.max() : nil
        return GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let number = index + 1
                        line(number, colored.map { $0[index] } ?? AttributedString(lines[index]), gutter: gutter,
                             noted: noted.contains(number))
                        ForEach(notes.filter { $0.lines.last == number }) { note in
                            NoteView(note: note) { store.removeAnnotation(note.id, from: id) }
                                .padding(.leading, gutter + 8)
                        }
                        if composerLine == number {
                            composer(lines)
                                .padding(.leading, gutter + 8)
                        }
                    }
                }
                .padding(.bottom, 12)
                .coordinateSpace(.named(Self.space))
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
            }
        }
    }

    private func line(_ number: Int, _ text: AttributedString, gutter: CGFloat, noted: Bool) -> some View {
        let selected = selection.contains(number)
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Capsule().fill(Theme.accent).frame(width: 3, height: 14).opacity(noted ? 1 : 0)
                Text("\(number)")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: gutter)
            Text(text.characters.isEmpty ? AttributedString(" ") : text)
                .fixedSize()
                .padding(.leading, 12)
                .padding(.trailing, 16)
        }
        .font(Self.font)
        .frame(height: Self.lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.14) : noted ? Theme.accent.opacity(0.05) : .clear)
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { lineTops[number] = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { dragged($0) }
                .onEnded { _ in endDrag() }
        )
        .help(L("Drag over lines to annotate them; Command-drag adds more lines, Shift extends the selection."))
    }

    /// The line under a point in the code's space; notes and the composer belong to the line above them.
    private func line(at y: CGFloat) -> Int? {
        lineTops.filter { $0.value <= y }.max { $0.value < $1.value }?.key ?? lineTops.min { $0.value < $1.value }?.key
    }

    private func dragged(_ value: DragGesture.Value) {
        guard let current = line(at: value.location.y) else { return }
        if drag == nil {
            guard let start = line(at: value.startLocation.y) else { return }
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift), let anchor {
                drag = (anchor, flags.contains(.command) ? selection : [], selection, true)
            } else {
                drag = (start, flags.contains(.command) ? selection : [], selection, false)
            }
            if !flags.contains(.shift) { anchor = start }
        }
        guard var drag else { return }
        if current != drag.start { drag.moved = true }
        self.drag = drag
        selection = drag.base.union(min(drag.start, current)...max(drag.start, current))
    }

    private func endDrag() {
        guard let drag else { return }
        // A click on a selected line takes it out again.
        if !drag.moved, drag.base.contains(drag.start) {
            selection = drag.base.subtracting([drag.start])
        } else if !drag.moved, drag.base.isEmpty, drag.previous == [drag.start] {
            selection = []
        }
        withAnimation(.snappy(duration: 0.2)) { self.drag = nil }
    }

    private func composer(_ lines: [String]) -> some View {
        let sorted = selection.sorted()
        let ranges = FileTreeStore.ranges(of: sorted).map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
        return VStack(alignment: .leading, spacing: 8) {
            Label(sorted.count == 1 ? L("Line \(ranges.joined())") : L("Lines \(ranges.joined(separator: ", "))"),
                  systemImage: "text.bubble")
                .font(.system(size: 12, weight: .semibold))
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Add a note for the agents…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isWriting)
                    .onSubmit { add(lines) }
                    .padding(8)
                    .background(Theme.surface, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line.opacity(0.14)))
                Button { add(lines) } label: {
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
        .onExitCommand { withAnimation(.snappy(duration: 0.2)) { selection = [] } }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
    }

    private func add(_ lines: [String]) {
        let comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let numbers = selection.filter { $0 >= 1 && $0 <= lines.count }.sorted()
        guard !comment.isEmpty, !numbers.isEmpty, let path = model.openFile else { return }
        let excerpt = FileTreeStore.ranges(of: numbers)
            .map { lines[($0.lowerBound - 1)...($0.upperBound - 1)].joined(separator: "\n") }
            .joined(separator: "\n…\n")
        store.annotate(FileAnnotation(path: path, lines: numbers, excerpt: excerpt, comment: comment), on: id)
        draft = ""
        withAnimation(.snappy(duration: 0.2)) {
            selection = []
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
