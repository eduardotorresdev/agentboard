import AppKit
import Orchestration
import SwiftUI

/// A board element the user can mention in a prompt. `type` is its `ElementKind.rawValue` and
/// `id` the one the board tools accept, so the agent can find it with `list_peers`.
struct BoardMention: Hashable {
    let name: String
    let type: String
    let id: UUID

    /// `@[Name](type:id)`; brackets in the name would end it early, so they become parentheses.
    var serialized: String {
        let safe = name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "@[\(safe)](\(type):\(id.uuidString))"
    }

    static let attribute = NSAttributedString.Key("boardMention")

    /// The draft's plain text, with each mention token replaced by its serialized form.
    static func serialize(_ draft: NSAttributedString) -> String {
        var text = ""
        draft.enumerateAttribute(attribute, in: NSRange(location: 0, length: draft.length)) { value, range, _ in
            text += (value as? BoardMention)?.serialized ?? draft.attributedSubstring(from: range).string
        }
        return text
    }
}

extension AgentStore {
    /// Every element on the agent's board except the agent itself: cards, post-its, images and
    /// whatever else the board lists (browsers, file trees…).
    func mentionables(for id: UUID) -> [BoardMention] {
        guard let worktree = record(id)?.worktree else { return [] }
        let cards = agents(in: worktree).map { BoardMention(name: $0.name, type: $0.runner == nil ? "agent" : "runner", id: $0.id) }
        let notes = postIts(in: worktree).map { BoardMention(name: $0.name, type: "postit", id: $0.id) }
        let pictures = images(in: worktree).map { BoardMention(name: $0.name, type: $0.isVideo ? "video" : "image", id: $0.id) }
        let others = elements().filter { $0.worktree == worktree }.map { BoardMention(name: $0.name, type: $0.kind, id: $0.id) }
        return (cards + notes + pictures + others).filter { $0.id != id }
    }

    /// Sends what the user wrote in the agent's composer as their prompt.
    func prompt(_ id: UUID, text: String) {
        send(.prompt(id: id, text: text))
    }
}

/// Below an agent card: a field the user writes a prompt in, apart from the terminal, so a
/// message arriving from another agent never mixes with a half-written draft. `@` mentions
/// board elements.
struct AgentComposer: View {
    let store: AgentStore
    let id: UUID
    @State private var isEmpty = true

    var body: some View {
        HStack(spacing: 6) {
            MentionField(store: store, id: id, isEmpty: $isEmpty)
            Button { MentionField.send(store: store, id: id) } label: {
                Image(systemName: "arrow.up").font(Theme.Font.label).foregroundStyle(isEmpty ? Theme.inkMuted : Theme.onAccent)
                    .frame(width: 24, height: 24)
                    .background(isEmpty ? Theme.surfaceDeep : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .help(L("Sends the text to the agent as your prompt."))
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ComposerGlass())
    }

    /// Whether the agent has unsent text, which keeps its composer shown off focus.
    @MainActor static func hasDraft(_ id: UUID) -> Bool { MentionField.hasDraft(id) }
}

/// Liquid Glass where the system has it, solid paper before that. The paper wash under the text
/// keeps ink at AA over the deepest sky blue (8.2:1 at 60%) and over cloud (14.5:1).
private struct ComposerGlass: ViewModifier {
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Theme.surface.opacity(0.6), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(Theme.surface, in: shape)
        }
    }
}

/// The composer's text view: plain text plus mention tokens, with the `@` picker.
private struct MentionField: NSViewRepresentable {
    let store: AgentStore
    let id: UUID
    @Binding var isEmpty: Bool

    /// Drafts by agent, kept while the board view comes and goes.
    @MainActor private static var drafts: [UUID: NSAttributedString] = [:]
    @MainActor private static var views: [UUID: ComposerTextView] = [:]

    @MainActor static func hasDraft(_ id: UUID) -> Bool {
        !(drafts[id]?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    @MainActor static func send(store: AgentStore, id: UUID) {
        views[id]?.submit()
    }

    func makeNSView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.store = store
        view.agent = id
        view.onChange = { draft in
            Self.drafts[id] = draft
            isEmpty = draft.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let draft = Self.drafts[id] { view.textStorage?.setAttributedString(draft) }
        let empty = view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        DispatchQueue.main.async { isEmpty = empty }
        Self.views[id] = view
        return view
    }

    func updateNSView(_ view: ComposerTextView, context: Context) {}
}

/// One-line text view that turns picked elements into tokens and sends on Return.
final class ComposerTextView: NSTextView, NSTextViewDelegate {
    weak var store: AgentStore?
    var agent = UUID()
    var onChange: ((NSAttributedString) -> Void)?
    private let picker = NSPopover()
    private let pickerModel = MentionPickerModel()
    /// Where the `@` being completed sits.
    private var mentionStart: Int?

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.ink)]

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: 10_000))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        delegate = self
        isRichText = false
        drawsBackground = false
        font = Self.font
        typingAttributes = Self.plain
        textContainerInset = CGSize(width: 0, height: 4)
        setAccessibilityLabel(L("Prompt"))
        picker.behavior = .semitransient
        picker.animates = true
        picker.contentViewController = NSHostingController(rootView: MentionPicker(model: pickerModel) { [weak self] in self?.pick($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    func submit() {
        guard let store, let storage = textStorage else { return }
        let text = BoardMention.serialize(storage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.prompt(agent, text: text)
        storage.setAttributedString(NSAttributedString())
        closePicker()
        onChange?(storage)
    }

    func textDidChange(_ notification: Notification) {
        typingAttributes = Self.plain
        updatePicker()
        if let textStorage { onChange?(NSAttributedString(attributedString: textStorage)) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if mentionStart != nil { updatePicker() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let open = picker.isShown && !pickerModel.matches.isEmpty
        switch selector {
        case #selector(insertNewline(_:)):
            if open { pick(pickerModel.matches[pickerModel.selected]) } else { submit() }
        case #selector(moveDown(_:)) where open:
            pickerModel.selected = min(pickerModel.selected + 1, pickerModel.matches.count - 1)
        case #selector(moveUp(_:)) where open:
            pickerModel.selected = max(pickerModel.selected - 1, 0)
        case #selector(cancelOperation(_:)) where picker.isShown:
            closePicker()
        case #selector(insertTab(_:)) where open:
            pick(pickerModel.matches[pickerModel.selected])
        default:
            return false
        }
        return true
    }

    /// Opens, filters or closes the picker from the `@word` before the cursor.
    private func updatePicker() {
        let cursor = selectedRange().location
        let before = (string as NSString).substring(to: min(cursor, (string as NSString).length))
        guard let at = before.range(of: "@", options: .backwards),
              !before[at.upperBound...].contains(where: \.isWhitespace),
              at.lowerBound == before.startIndex || before[before.index(before: at.lowerBound)].isWhitespace,
              let store else { return closePicker() }
        let start = before.utf16.distance(from: before.startIndex, to: at.lowerBound)
        // An `@` inside a token isn't a new mention.
        guard textStorage?.attribute(BoardMention.attribute, at: start, effectiveRange: nil) == nil else { return closePicker() }
        mentionStart = start
        let query = String(before[at.upperBound...]).lowercased()
        pickerModel.matches = store.mentionables(for: agent).filter { query.isEmpty || $0.name.lowercased().contains(query) }
        pickerModel.selected = 0
        if pickerModel.matches.isEmpty { return closePicker() }
        if !picker.isShown, window != nil {
            let caret = firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            let local = convert(window?.convertFromScreen(caret) ?? .zero, from: nil)
            picker.show(relativeTo: CGRect(x: local.minX, y: bounds.minY, width: 1, height: bounds.height), of: self, preferredEdge: .maxY)
        }
    }

    private func closePicker() {
        mentionStart = nil
        if picker.isShown { picker.performClose(nil) }
    }

    /// Replaces the `@query` with the element's token and a space.
    private func pick(_ mention: BoardMention) {
        guard let start = mentionStart, let storage = textStorage else { return }
        let range = NSRange(location: start, length: selectedRange().location - start)
        var token = Self.plain
        token[BoardMention.attribute] = mention
        token[.foregroundColor] = NSColor(Theme.accent)
        token[.backgroundColor] = NSColor(Theme.accentSoft)
        let inserted = NSMutableAttributedString(string: "@\(mention.name)", attributes: token)
        inserted.append(NSAttributedString(string: " ", attributes: Self.plain))
        guard shouldChangeText(in: range, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        didChangeText()
        setSelectedRange(NSRange(location: start + inserted.length, length: 0))
        closePicker()
    }
}

@MainActor
@Observable
final class MentionPickerModel {
    var matches: [BoardMention] = []
    var selected = 0
}

/// The `@` list: each element with its type.
private struct MentionPicker: View {
    let model: MentionPickerModel
    let pick: (BoardMention) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.matches.enumerated()), id: \.element.id) { index, mention in
                    Button { pick(mention) } label: {
                        HStack {
                            Text(mention.name).font(Theme.Font.body).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(mention.type).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(.rect)
                        .background(index == model.selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(width: 240, height: min(CGFloat(model.matches.count) * 26 + 12, 220))
    }
}
