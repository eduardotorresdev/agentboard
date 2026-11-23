import AgentRuntime
import AppKit
import Connections
import Orchestration
import SwiftUI

/// A board element the user can mention in a prompt. `type` is its `ElementKind.rawValue` and
/// `id` the one the board tools accept, so the agent can find it with `list_peers`.
struct BoardMention: Hashable {
    let name: String
    let type: String
    let id: UUID

    /// `@[Name](type:id)`, on one line; brackets in the name would end it early, so they become
    /// parentheses.
    var serialized: String {
        let safe = (BoardName.clean(name) ?? type).replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "@[\(safe)](\(type):\(id.uuidString))"
    }

    /// The type as people read it; the raw `type` stays in the serialized mention.
    var typeLabel: String {
        switch type {
        case "agent": L("Agent")
        case "runner": L("Runner")
        case "postit": L("Post-it")
        case "image": L("Image")
        case "video": L("Video")
        case "browser": L("Browser")
        case "simulator": L("Simulator")
        case "filetree": L("File tree")
        default: type.capitalized
        }
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

    /// `serialize` read back: the text, with a mention wherever `@[Name](type:id)` stood.
    static func parse(_ text: String) -> [Either] {
        var parts: [Either] = []
        var rest = Substring(text)
        while let match = rest.firstMatch(of: pattern) {
            if match.range.lowerBound > rest.startIndex { parts.append(.text(String(rest[..<match.range.lowerBound]))) }
            if let id = UUID(uuidString: String(match.output.3)) {
                parts.append(.mention(BoardMention(name: String(match.output.1), type: String(match.output.2), id: id)))
            } else {
                parts.append(.text(String(rest[match.range])))
            }
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return parts
    }

    enum Either: Equatable {
        case text(String)
        case mention(BoardMention)
    }

    nonisolated(unsafe) private static let pattern = #/@\[([^\]\n]*)\]\(([a-z]+):([0-9A-Fa-f-]{36})\)/#
}

extension AgentStore {
    /// Every element on the agent's board except the agent itself: cards, post-its, images and
    /// whatever else the board lists (browsers, file trees…).
    func mentionables(for id: UUID) -> [BoardMention] {
        guard let worktree = record(id)?.worktree else { return [] }
        let cards = agents(in: worktree).map { BoardMention(name: $0.name, type: $0.runner == nil ? "agent" : "runner", id: $0.id) }
        let notes = postIts(in: worktree).map { BoardMention(name: $0.name, type: "postit", id: $0.id) }
        let pictures = images(in: worktree).map { BoardMention(name: $0.name, type: $0.isVideo ? "video" : "image", id: $0.id) }
        let others = elements().filter { $0.worktree == worktree && ($0.organization ?? organizationID) == organizationID }.map { BoardMention(name: $0.name, type: $0.kind, id: $0.id) }
        return (cards + notes + pictures + others).filter { $0.id != id }
    }

    /// Sends what the user wrote in the agent's composer as their prompt; false (and the draft
    /// stays) when the agent can't take it, with `promptBlocker` saying why.
    func prompt(_ id: UUID, text: String) -> Bool {
        guard promptBlocker(id) == nil else { return false }
        send(.prompt(id: id, text: text))
        return true
    }

    /// Why the agent can't take a prompt now, or nil.
    func promptBlocker(_ id: UUID) -> String? {
        guard coreTakesPrompts else { return L("The running core is older than this board; reopen the app to send from here.") }
        if attention.contains(where: { $0.id == id && $0.needsUser }) { return L("It is waiting for your answer.") }
        switch sessions[id]?.state {
        case .running: return nil
        case .starting: return L("It is still starting.")
        case .exited, .stopped: return L("It exited. Click the card to restart it.")
        case .failed(let reason): return reason
        case nil: return L("It hasn't started yet.")
        }
    }
}

/// Unsent composer text by agent: kept while the board view comes and goes, and across launches.
@MainActor
enum ComposerDrafts {
    private static var drafts: [UUID: NSAttributedString] = [:]
    fileprivate static var views: [UUID: ComposerTextView] = [:]
    private static var lineCounts: [UUID: Int] = [:]
    /// Posted with the agent's id as object when its composer grows or shrinks a line.
    static let linesChanged = Notification.Name("ComposerLinesChanged")

    /// Lines the agent's draft takes in its composer, at least one.
    static func lines(_ id: UUID) -> Int { lineCounts[id] ?? 1 }

    fileprivate static func setLines(_ lines: Int, for id: UUID) {
        let lines = min(max(lines, 1), CardMetrics.composerMaxLines)
        guard lines != self.lines(id) else { return }
        lineCounts[id] = lines
        NotificationCenter.default.post(name: linesChanged, object: id)
    }
    private static var uploadCounts: [UUID: Int] = [:]
    /// Files being sent shown under the agent's composer, one row each.
    static func uploads(_ id: UUID) -> Int { uploadCounts[id] ?? 0 }

    static func setUploads(_ count: Int, for id: UUID) {
        guard count != uploads(id) else { return }
        uploadCounts[id] = count
        NotificationCenter.default.post(name: linesChanged, object: id)
    }
    /// Serialized drafts, read from the data folder once and written back on each change.
    private static var saved: [String: String] = {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }()
    private static var file: URL { DataFolder.url.appendingPathComponent("composer-drafts.json") }

    static func draft(_ id: UUID) -> NSAttributedString? {
        if let draft = drafts[id] { return draft }
        guard let text = saved[id.uuidString] else { return nil }
        let draft = ComposerTextView.attributed(BoardMention.parse(text))
        drafts[id] = draft
        return draft
    }

    static func save(_ draft: NSAttributedString, for id: UUID) {
        drafts[id] = draft
        let text = BoardMention.serialize(draft)
        store(text.isEmpty ? nil : text, for: id)
    }

    static func hasDraft(_ id: UUID) -> Bool {
        !(draft(id)?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The card is gone: so is its draft.
    static func forget(_ id: UUID) {
        drafts[id] = nil
        views[id] = nil
        lineCounts[id] = nil
        store(nil, for: id)
    }

    /// A prompt the core gave back: in front of whatever the user wrote since.
    static func restore(_ text: String, for id: UUID) {
        let returned = NSMutableAttributedString(attributedString: ComposerTextView.attributed(BoardMention.parse(text)))
        if let current = views[id]?.textStorage ?? draft(id).map(NSMutableAttributedString.init), current.length > 0 {
            returned.append(NSAttributedString(string: " ", attributes: ComposerTextView.plain))
            returned.append(current)
        }
        if let view = views[id] {
            view.textStorage?.setAttributedString(returned)
            view.textDidChange(Notification(name: NSText.didChangeNotification))
        } else {
            save(returned, for: id)
        }
    }

    private static var pendingWrite: DispatchWorkItem?

    private static func store(_ text: String?, for id: UUID) {
        guard saved[id.uuidString] != text else { return }
        saved[id.uuidString] = text
        // Written once the typing pauses: a file write on every key stalls the field.
        pendingWrite?.cancel()
        let write = DispatchWorkItem { flush() }
        pendingWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: write)
    }

    /// Writes the drafts still waiting to be written; the app calls it as it leaves.
    static func flush() {
        guard let write = pendingWrite else { return }
        write.cancel()
        pendingWrite = nil
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: [.atomic])
    }
}

/// At the bottom of an agent card: a field the user writes a prompt in, apart from the terminal,
/// so a message arriving from another agent never mixes with a half-written draft. `@` mentions
/// board elements, `/` commands go to the agent as typed, Shift-Return breaks the line.
struct AgentComposer: View {
    let store: AgentStore
    let id: UUID
    @State private var isEmpty = true
    /// Why the last send didn't go, shown until the text changes.
    @State private var notice: String?

    var body: some View {
        let blocker = store.promptBlocker(id)
        let notice = notice ?? store.composerNotices[id]
        VStack(spacing: 0) {
        HStack(alignment: .bottom, spacing: 6) {
            MentionField(store: store, id: id, isEmpty: $isEmpty, notice: $notice)
                .padding(.vertical, 5)
            if let held = store.heldMessages[id] {
                Button { store.send(.deliverHeld(id)) } label: {
                    Text(held == 1 ? L("1 message waiting · Deliver now") : L("\(held) messages waiting · Deliver now"))
                        .font(Theme.Font.label).foregroundStyle(Theme.ink).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(L("Messages wait while you have text typed in the terminal. Delivers them now; your typed text is submitted with the first one."))
            }
            if let notice = notice ?? blocker {
                Text(notice).font(Theme.Font.caption).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    .frame(height: 26)
                    .help(notice)
            }
            let off = isEmpty || blocker != nil
            Button { ComposerDrafts.views[id]?.submit() } label: {
                Image(systemName: "arrow.up").font(Theme.Font.label).foregroundStyle(off ? Theme.inkMuted : Theme.onAccent)
                    .frame(width: 24, height: 24)
                    .background(off ? Theme.surfaceDeep : Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(off)
            .help(blocker ?? L("Sends the text to the agent as your prompt."))
            .accessibilityLabel(L("Send"))
            .padding(.bottom, 6)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        ForEach(store.uploads[id] ?? []) { UploadRow(upload: $0) }
        }
        .padding(.bottom, store.uploads[id]?.isEmpty == false ? 4 : 0)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .modifier(ComposerGlass())
    }
}

/// A file on its way to the host: "Sending name", a bar that eases toward its share, the percent.
private struct UploadRow: View {
    let upload: Upload

    var body: some View {
        HStack(spacing: 8) {
            Text(L("Sending \(upload.name)")).font(Theme.Font.caption).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceDeep)
                    Capsule().fill(Theme.accent).frame(width: box.size.width * upload.progress)
                }
            }
            .frame(height: 5)
            .animation(.smooth(duration: 0.6), value: upload.progress)
            Text("\(Int(upload.progress * 100))%").font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.inkMuted)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: CardMetrics.uploadRowHeight)
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Liquid Glass where the system has it, solid paper before that; a capsule on one line that
/// keeps its round ends as it grows. The paper wash under the text keeps ink at AA over the
/// deepest sky blue (8.2:1 at 60%) and over cloud (14.5:1).
private struct ComposerGlass: ViewModifier {
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

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
    @Binding var notice: String?

    @Environment(\.boardZoom) private var zoom

    func makeNSView(context: Context) -> ZoomFollowing {
        let view = ComposerTextView()
        view.store = store
        view.agent = id
        view.onChange = { draft in
            ComposerDrafts.save(draft, for: id)
            ComposerDrafts.setLines(view.lineCount, for: id)
            // Each only when it changes: a write redraws what reads it, on every key otherwise.
            let empty = draft.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty != empty { isEmpty = empty }
            if notice != nil { notice = nil }
            if store.composerNotices[id] != nil { store.composerNotices[id] = nil }
        }
        view.onBlocked = { notice = $0 }
        if let draft = ComposerDrafts.draft(id) { view.textStorage?.setAttributedString(draft) }
        let empty = view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        DispatchQueue.main.async { isEmpty = empty }
        ComposerDrafts.views[id] = view
        let scroll = PassingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        view.isVerticallyResizable = true
        view.autoresizingMask = .width
        scroll.documentView = view
        DispatchQueue.main.async { ComposerDrafts.setLines(view.lineCount, for: id) }
        let host = ZoomFollowing(scroll)
        host.zoom = zoom
        return host
    }

    func updateNSView(_ view: ZoomFollowing, context: Context) {
        view.zoom = zoom
    }
}

/// Holds the field at the board's zoom. The composer is scaled inside SwiftUI (`ZoomedView`) so
/// its buttons take clicks where they're drawn, but SwiftUI only sizes an AppKit view, it doesn't
/// scale it: this view's bounds do, in zoom-1 points, so AppKit draws and hit-tests the field
/// at the zoom.
final class ZoomFollowing: NSView {
    private let content: NSView
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { needsLayout = true } } }

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let zoom = max(zoom, 0.01)
        setBoundsSize(CGSize(width: frame.width / zoom, height: frame.height / zoom))
        content.frame = bounds
    }
}

/// Hands the wheel to the board while the draft fits, so panning over a card doesn't stall here.
private final class PassingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let fits = (documentView?.frame.height ?? 0) <= contentSize.height + 1
        if fits { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// Text view that turns picked elements into tokens, sends on Return and breaks the line on
/// Shift- or Option-Return. A token is
/// one piece: editing inside it replaces it whole.
final class ComposerTextView: NSTextView, NSTextViewDelegate {
    weak var store: AgentStore?
    var agent = UUID()
    var onChange: ((NSAttributedString) -> Void)?
    var onBlocked: ((String) -> Void)?
    private lazy var picker = MentionPanel { [weak self] in self?.pick($0) }
    /// Where the `@` being completed sits.
    private var mentionStart: Int?

    static let font = NSFont.systemFont(ofSize: Theme.Font.bodySize)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    /// Lines the text takes, wrapped at the field's width.
    var lineCount: Int {
        guard let layoutManager, let textContainer else { return 1 }
        layoutManager.ensureLayout(for: textContainer)
        return max(1, Int((layoutManager.usedRect(for: textContainer).height / Self.lineHeight).rounded()))
    }
    static let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.ink)]

    static func token(_ mention: BoardMention) -> NSAttributedString {
        var attributes = plain
        attributes[BoardMention.attribute] = mention
        attributes[.foregroundColor] = NSColor(Theme.ink)
        attributes[.backgroundColor] = NSColor(Theme.accentSoft)
        return NSAttributedString(string: "@\(BoardName.clean(mention.name) ?? mention.type)", attributes: attributes)
    }

    static func attributed(_ parts: [BoardMention.Either]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .text(let string): text.append(NSAttributedString(string: string, attributes: plain))
            case .mention(let mention): text.append(token(mention))
            }
        }
        return text
    }

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
        insertionPointColor = NSColor(Theme.accent)
        textContainerInset = CGSize(width: 0, height: 4)
        setAccessibilityLabel(L("Prompt"))
        setAccessibilityPlaceholderValue(Self.placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let placeholder = L("Write to the agent; @ mentions a card")

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // A narrower card wraps the draft onto more lines.
        if widthChanged { ComposerDrafts.setLines(lineCount, for: agent) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (Self.placeholder as NSString).draw(at: origin, withAttributes: [.font: Self.font, .foregroundColor: NSColor(Theme.inkMuted)])
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closePicker() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func paste(_ sender: Any?) {
        if !attach(from: .general) { super.paste(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        attach(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /// Copied or dropped files (or a picture with no text) go in as their paths on the agent's
    /// machine, copied to its host first, instead of the bare file name a text view would paste.
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        let sources = AgentStore.attachments(on: pasteboard)
        let hasFiles = sources.contains { if case .file = $0 { true } else { false } }
        guard let store, !sources.isEmpty, hasFiles || pasteboard.string(forType: .string) == nil else { return false }
        Task { @MainActor [weak self, agent] in
            let paths = await store.attachmentPaths(sources, for: agent)
            guard let self, !paths.isEmpty else { return NSSound.beep() }
            insertText(AgentStore.typed(paths), replacementRange: selectedRange())
        }
        return true
    }

    func submit() {
        guard let store, let storage = textStorage else { return }
        let text = BoardMention.serialize(storage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard store.prompt(agent, text: text) else {
            onBlocked?(store.promptBlocker(agent) ?? "")
            return
        }
        storage.setAttributedString(NSAttributedString())
        closePicker()
        onChange?(storage)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        typingAttributes = Self.plain
        updatePicker()
        if let textStorage { onChange?(NSAttributedString(attributedString: textStorage)) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        typingAttributes = Self.plain
        if mentionStart != nil { updatePicker() }
    }

    /// The mention token around `location`, when `location` falls inside one (not at its edges).
    private func token(around location: Int) -> NSRange? {
        guard let storage = textStorage, location > 0, location < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(BoardMention.attribute, at: location, longestEffectiveRange: &range,
                                in: NSRange(location: 0, length: storage.length)) != nil,
              range.location < location else { return nil }
        return range
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        var target = range
        if let start = token(around: range.location) { target = NSUnionRange(target, start) }
        if let end = token(around: NSMaxRange(range)) { target = NSUnionRange(target, end) }
        // Backspace or delete right next to a token takes the whole token.
        if range.length == 1, replacementString?.isEmpty == true, let storage = textStorage,
           storage.attribute(BoardMention.attribute, at: range.location, effectiveRange: nil) != nil {
            var whole = NSRange()
            _ = storage.attribute(BoardMention.attribute, at: range.location, longestEffectiveRange: &whole,
                                  in: NSRange(location: 0, length: storage.length))
            target = NSUnionRange(target, whole)
        }
        guard target != range, let storage = textStorage else { return true }
        // Typing inside a token goes after it instead of splitting it.
        if range.length == 0 { target = NSRange(location: NSMaxRange(target), length: 0) }
        let replacement = NSAttributedString(string: replacementString ?? "", attributes: Self.plain)
        storage.replaceCharacters(in: target, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: target.location + replacement.length, length: 0))
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let model = picker.model
        let open = picker.isShown && !model.matches.isEmpty
        switch selector {
        case #selector(insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
             #selector(insertNewlineIgnoringFieldEditor(_:)):
            insertText("\n", replacementRange: selectedRange())
        case #selector(insertNewline(_:)):
            if open { pick(model.matches[model.selected]) } else { submit() }
        case #selector(moveDown(_:)) where open:
            model.selected = min(model.selected + 1, model.matches.count - 1)
        case #selector(moveUp(_:)) where open:
            model.selected = max(model.selected - 1, 0)
        case #selector(cancelOperation(_:)) where picker.isShown:
            closePicker()
        case #selector(insertTab(_:)) where open:
            pick(model.matches[model.selected])
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
        picker.model.matches = store.mentionables(for: agent).filter { query.isEmpty || $0.name.lowercased().contains(query) }
        picker.model.selected = 0
        if picker.model.matches.isEmpty { return closePicker() }
        if let window {
            // Below the field, where the composer leaves the canvas free.
            picker.show(below: window.convertToScreen(convert(bounds, to: nil)), in: window)
        }
    }

    private func closePicker() {
        mentionStart = nil
        picker.close()
    }

    /// Replaces the `@query` with the element's token and a space.
    private func pick(_ mention: BoardMention) {
        guard let start = mentionStart, let storage = textStorage else { return }
        let range = NSRange(location: start, length: selectedRange().location - start)
        let inserted = NSMutableAttributedString(attributedString: Self.token(mention))
        inserted.append(NSAttributedString(string: " ", attributes: Self.plain))
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

/// The `@` list, in a borderless panel of its own under the composer, so the card's view
/// doesn't clip it. It never takes focus: typing stays in the composer.
@MainActor
private final class MentionPanel {
    let model = MentionPickerModel()
    private let pick: (BoardMention) -> Void
    private var panel: NSPanel?

    init(pick: @escaping (BoardMention) -> Void) {
        self.pick = pick
    }

    var isShown: Bool { panel?.isVisible == true }

    func show(below field: CGRect, in window: NSWindow) {
        let panel = self.panel ?? makePanel()
        let size = CGSize(width: MentionPicker.width + MentionPicker.margin * 2, height: MentionPicker.maxHeight + MentionPicker.margin * 2)
        panel.setFrame(CGRect(x: field.minX - MentionPicker.margin, y: field.minY - size.height - 2, width: size.width, height: size.height),
                       display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: MentionPicker(model: model, pick: pick))
        self.panel = panel
        return panel
    }
}

/// Each element with its type; the chosen row follows the arrow keys into view.
struct MentionPicker: View {
    static let width: CGFloat = 260
    static let maxHeight: CGFloat = 232
    /// Room between the list and the panel's edge.
    static let margin: CGFloat = 4
    private static let row: CGFloat = 28

    let model: MentionPickerModel
    let pick: (BoardMention) -> Void

    var body: some View {
        VStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.matches.enumerated()), id: \.element.id) { index, mention in
                            Button { pick(mention) } label: {
                                HStack {
                                    Text(BoardName.clean(mention.name) ?? mention.type).font(Theme.Font.body).foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(mention.typeLabel).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: Self.row - 2)
                                .contentShape(.rect)
                                .background(index == model.selected ? Theme.accentSoft : .clear,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selected) { _, selected in
                    withAnimation(.snappy) { reader.scrollTo(selected) }
                }
            }
            .frame(width: Self.width, height: min(CGFloat(model.matches.count) * Self.row + 12, Self.maxHeight))
            .paperSurface(radius: Theme.Radius.card)
            Spacer(minLength: 0)
        }
        .padding(Self.margin)
        .frame(width: Self.width + Self.margin * 2, height: Self.maxHeight + Self.margin * 2, alignment: .top)
    }
}
