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
    /// An agent's provider, for its mark in the picker; never serialized.
    var provider: String? = nil

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
        draft.enumerateAttributes(in: NSRange(location: 0, length: draft.length)) { attributes, range, _ in
            // The `@@` chip only marks the picker's mode: nothing of it is sent or kept.
            guard attributes[ComposerTextView.chip] == nil else { return }
            text += (attributes[attribute] as? BoardMention)?.serialized ?? draft.attributedSubstring(from: range).string
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
        let cards = agents(in: worktree).map {
            BoardMention(name: $0.name, type: $0.runner == nil ? "agent" : "runner", id: $0.id, provider: $0.runner == nil ? $0.providerID : nil)
        }
        let notes = postIts(in: worktree).map { BoardMention(name: $0.name, type: "postit", id: $0.id) }
        let pictures = images(in: worktree).map { BoardMention(name: $0.name, type: $0.isVideo ? "video" : "image", id: $0.id) }
        let others = elements().filter { $0.worktree == worktree && ($0.organization ?? organizationID) == organizationID }.map { BoardMention(name: $0.name, type: $0.kind, id: $0.id) }
        return (cards + notes + pictures + others).filter { $0.id != id }
    }

    /// The organization's agents this store runs outside the agent's worktree, for `@@`: a
    /// message mentioning one goes to it, not to this agent.
    /// Every host's agents in use, theirs named; this one's alone without the app's links.
    func remoteAgents(for id: UUID) -> [RemoteAgent] {
        guard let here = record(id)?.worktree, let projects = projectTools?.projects else { return [] }
        let stores = agentLinks?.stores() ?? [self]
        var found: [RemoteAgent] = []
        for store in stores {
            let hostName: String? = store.host?.id == host?.id ? nil : store.host?.name ?? Foundation.Host.current().localizedName
            for record in store.agents where record.organizationID == organizationID && record.runner == nil {
                if store === self && record.worktree == here { continue }
                let place = projects.place(ofPath: record.worktree)
                let mention = BoardMention(name: record.name, type: "agent", id: record.id, provider: record.providerID)
                found.append(RemoteAgent(project: place.project ?? RemoteAgent.project(ofFolder: record.worktree), worktree: place.worktree,
                                         isBoard: MyBoard.isBoard(record.worktree), agent: mention, host: hostName))
            }
        }
        return found.sorted { $0.shown.localizedStandardCompare($1.shown) == .orderedAscending }
    }

    /// The agents of the draft in another worktree or host than `id`'s, with their stores: the
    /// draft goes to them instead.
    func remoteTargets(of draft: NSAttributedString, from id: UUID) -> [(id: UUID, store: AgentStore)] {
        guard let here = record(id)?.worktree else { return [] }
        var targets: [(id: UUID, store: AgentStore)] = []
        draft.enumerateAttribute(BoardMention.attribute, in: NSRange(location: 0, length: draft.length)) { value, _, _ in
            guard let mention = value as? BoardMention, mention.type == "agent", !targets.contains(where: { $0.id == mention.id }),
                  let store = agentLinks?.store(of: mention.id) ?? (record(mention.id) == nil ? nil : self),
                  let target = store.record(mention.id), store !== self || target.worktree != here else { return }
            targets.append((target.id, store))
        }
        return targets
    }

    /// Sends the draft to the agents of other worktrees or hosts it mentions, links each with
    /// agent `id`, and tells `id` so; the reason when one can't take it (and nothing is sent).
    func sendElsewhere(_ text: String, to targets: [(id: UUID, store: AgentStore)], from id: UUID) -> String? {
        if let blocker = targets.lazy.compactMap({ $0.store.promptBlocker($0.id) }).first { return blocker }
        var names: [String] = []
        for target in targets {
            _ = target.store.prompt(target.id, text: text)
            guard let links = agentLinks, let link = links.link(id, in: self, with: target.id, in: target.store),
                  let end = link.ends.first(where: { $0.agent == id }) else { continue }
            names.append(BoardName.quoted(links.relayName(on: end, in: link)))
        }
        if !names.isEmpty, promptBlocker(id) == nil { _ = prompt(id, text: Self.linkNotice(names: names, text: text)) }
        return nil
    }

    /// What the agent whose composer sent a `@@` message is told: by the board, short.
    nonisolated static func linkNotice(names: [String], text: String) -> String {
        let them = names.joined(separator: ", ")
        return "[Board] The user sent the message below to \(them), in another worktree, and connected you: "
            + "reach \(names.count == 1 ? "it" : "them") with send_message to \(them); replies arrive here as messages.\n\n\(text)"
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

    /// Puts the cursor in the agent's composer; false when it has none on screen.
    @discardableResult
    static func focus(_ id: UUID) -> Bool {
        guard let view = views[id], let window = view.window else { return false }
        return window.makeFirstResponder(view)
    }

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

    func makeNSView(context: Context) -> NSScrollView {
        let view = ComposerTextView()
        view.store = store
        view.agent = id
        view.onChange = { draft in
            ComposerDrafts.save(draft, for: id)
            ComposerDrafts.setLines(view.lineCount, for: id)
            // Past the last line it grows to, the field scrolls; keep the caret in sight once the new height lands.
            DispatchQueue.main.async { view.scrollRangeToVisible(view.selectedRange()) }
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
        return scroll
    }

    // SwiftUI's scale (`ZoomedView`) already draws and hit-tests the field at the board's zoom.
    func updateNSView(_ view: NSScrollView, context: Context) {}
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
    private lazy var picker = MentionPanel { [weak self] item in
        self?.pick(item)
        if case .command = item { self?.submit() }
    }
    /// Where the `@` being completed sits.
    private var mentionStart: Int?
    /// Marks the `@@` chip: while it is in the draft, what follows it up to the cursor filters
    /// the organization's other agents.
    static let chip = NSAttributedString.Key("otherProjectsChip")

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

    /// A plain-text view greys out Paste for a picture alone, so `paste` would never run.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.takesAttachment(from: .general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// Control-V pastes a picture, as in the agent's terminal; otherwise it keeps its text-view meaning.
    override func keyDown(with event: NSEvent) {
        // Esc leaves the `@@` mode before anything else can take it.
        if event.keyCode == 53, chipRange != nil { return exitOtherProjects() }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == "v",
           attach(from: .general) { return }
        super.keyDown(with: event)
    }

    /// Back in the field with the `@@` chip in it: the mode's list comes back.
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if chipRange != nil { DispatchQueue.main.async { [weak self] in self?.updatePicker() } }
        return true
    }

    /// Typing the second `@` of a word turns `@@` into the chip, once the text view has finished
    /// its own edit: changing the text inside it leaves the layout behind.
    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        let before = (string as NSString).substring(to: min(selectedRange().location, (string as NSString).length))
        guard chipRange == nil, case .place(let start, "") = PickerQuery.parse(before),
              textStorage?.attribute(BoardMention.attribute, at: start, effectiveRange: nil) == nil else { return }
        enterOtherProjects(at: start)
    }

    /// Copied files, or a picture with no text: what goes in as paths instead of pasted text.
    static func takesAttachment(from pasteboard: NSPasteboard) -> Bool {
        let sources = AgentStore.attachments(on: pasteboard)
        let hasFiles = sources.contains { if case .file = $0 { true } else { false } }
        return !sources.isEmpty && (hasFiles || pasteboard.string(forType: .string) == nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        attach(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /// Copied or dropped files (or a picture with no text) go in as their paths on the agent's
    /// machine, copied to its host first, instead of the bare file name a text view would paste.
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        guard let store, Self.takesAttachment(from: pasteboard) else { return false }
        let sources = AgentStore.attachments(on: pasteboard)
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
        // Mentioning an agent of another worktree (`@@`) sends the draft to it, as its prompt.
        let targets = store.remoteTargets(of: storage, from: agent)
        if targets.isEmpty {
            guard store.prompt(agent, text: text) else { return onBlocked?(store.promptBlocker(agent) ?? "") ?? () }
        } else if let blocker = store.sendElsewhere(text, to: targets, from: agent) {
            return onBlocked?(blocker) ?? ()
        }
        storage.setAttributedString(NSAttributedString())
        closePicker()
        onChange?(storage)
        needsDisplay = true
        // A command may open a menu in the agent's terminal: keys go there, the board being first
        // responder for the focused card.
        if targets.isEmpty, Self.isCommand(text),
           let board = sequence(first: self as NSView, next: { $0.superview }).first(where: { $0 is BoardView }) {
            window?.makeFirstResponder(board)
        }
    }

    /// `/name …`, not a path like `/Users/…`.
    static func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/") && !(text.dropFirst().prefix { !$0.isWhitespace }.contains("/")) && text.count > 1
    }

    func textDidChange(_ notification: Notification) {
        typingAttributes = Self.plain
        updatePicker()
        if let textStorage { onChange?(NSAttributedString(attributedString: textStorage)) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        typingAttributes = Self.plain
        if mentionStart != nil || chipRange != nil { updatePicker() }
    }

    /// The whole mention token or `@@` chip at `location`, if one is there.
    private func piece(at location: Int) -> NSRange? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        for key in [BoardMention.attribute, Self.chip] {
            var range = NSRange()
            if storage.attribute(key, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil {
                return range
            }
        }
        return nil
    }

    /// The token around `location`, when `location` falls inside one (not at its edges).
    private func token(around location: Int) -> NSRange? {
        guard location > 0, let range = piece(at: location), range.location < location else { return nil }
        return range
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        var target = range
        if let start = token(around: range.location) { target = NSUnionRange(target, start) }
        if let end = token(around: NSMaxRange(range)) { target = NSUnionRange(target, end) }
        // Backspace or delete right next to a token takes the whole token.
        // On the `@@` chip, with nothing typed after it, that ends the mode.
        if range.length == 1, replacementString?.isEmpty == true, let whole = piece(at: range.location) {
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
            guard open else { submit(); break }
            let item = model.matches[model.selected]
            pick(item)
            // Return on a command runs it, as in the agent's own input; Tab only completes it.
            if case .command = item { submit() }
        case #selector(moveDown(_:)) where open:
            model.selected = min(model.selected + 1, model.matches.count - 1)
        case #selector(moveUp(_:)) where open:
            model.selected = max(model.selected - 1, 0)
        case #selector(deleteBackward(_:)) where selectedRange().length == 0:
            // Backspace right after a token or the chip takes it whole: selected here, deleted by
            // the text view itself, which keeps its layout in step.
            let cursor = selectedRange().location
            if let piece = piece(at: cursor - 1), NSMaxRange(piece) == cursor { setSelectedRange(piece) }
            return false
        case #selector(cancelOperation(_:)) where chipRange != nil, #selector(complete(_:)) where chipRange != nil:
            exitOtherProjects()
        case #selector(cancelOperation(_:)) where picker.isShown:
            closePicker()
        case #selector(insertTab(_:)) where open:
            pick(model.matches[model.selected])
        default:
            return false
        }
        return true
    }

    /// Opens, filters or closes the picker from the `@word` before the cursor, or from a `/command`
    /// that starts the draft.
    private func updatePicker() {
        let text = string as NSString
        let cursor = min(selectedRange().location, text.length)
        let before = text.substring(to: cursor)
        // `@@` mode: the chip, then a free query (spaces too) up to the cursor.
        if let chip = chipRange {
            let end = NSMaxRange(chip)
            guard cursor >= end, let store else { return closePicker() }
            mentionStart = chip.location
            let query = text.substring(with: NSRange(location: end, length: cursor - end))
            return showPicker(store.remoteAgents(for: agent).filter { $0.matches(query) }.map(PickerItem.remote))
        }
        guard let store else { return closePicker() }
        let contains = { (name: String, query: String) in query.isEmpty || name.lowercased().contains(query) }
        switch PickerQuery.parse(before) {
        case .command(let query):
            guard let record = store.record(agent) else { return closePicker() }
            mentionStart = 0
            let commands = record.provider?.commands(in: record.worktree) ?? []
            showPicker(commands.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }.map(PickerItem.command))
        case .mention(let start, let query):
            // An `@` inside a token isn't a new mention.
            guard textStorage?.attribute(BoardMention.attribute, at: start, effectiveRange: nil) == nil else { return closePicker() }
            mentionStart = start
            showPicker(store.mentionables(for: agent).filter { contains($0.name, query) }.map(PickerItem.mention))
        case .place, nil:
            closePicker()
        }
    }

    /// Where the `@@` chip sits in the draft, while it is there.
    var chipRange: NSRange? {
        guard let storage = textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(Self.chip, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { found = range; stop.pointee = true }
        }
        return found
    }

    /// The `@@` query: what follows the chip up to the cursor; nil out of the mode.
    var otherProjectsQuery: String? {
        guard let chip = chipRange, selectedRange().location >= NSMaxRange(chip) else { return nil }
        return (string as NSString).substring(with: NSRange(location: NSMaxRange(chip), length: selectedRange().location - NSMaxRange(chip)))
    }

    /// Turns the `@@` at `start` into the chip, the cursor after it.
    private func enterOtherProjects(at start: Int) {
        guard let storage = textStorage else { return }
        let cursor = selectedRange().location
        var attributes = Self.plain
        attributes[Self.chip] = true
        attributes[.backgroundColor] = NSColor(Theme.accentSoft)
        let chip = NSAttributedString(string: L("Other projects") + " ", attributes: attributes)
        let range = NSRange(location: start, length: 2)
        guard shouldChangeText(in: range, replacementString: chip.string) else { return }
        storage.replaceCharacters(in: range, with: chip)
        didChangeText()
        setSelectedRange(NSRange(location: cursor - 2 + chip.length, length: 0))
        updatePicker()
    }

    /// Takes the chip out; what was typed after it stays as text.
    private func exitOtherProjects() {
        guard let chip = chipRange, let storage = textStorage else { return }
        let cursor = selectedRange().location
        guard shouldChangeText(in: chip, replacementString: "") else { return }
        storage.replaceCharacters(in: chip, with: NSAttributedString())
        didChangeText()
        setSelectedRange(NSRange(location: cursor >= NSMaxRange(chip) ? cursor - chip.length : min(cursor, chip.location), length: 0))
        closePicker()
    }

    private func showPicker(_ matches: [PickerItem]) {
        picker.model.matches = matches
        picker.model.selected = 0
        if matches.isEmpty { return closePicker() }
        if let window {
            // Below the field, where the composer leaves the canvas free.
            picker.show(below: window.convertToScreen(convert(bounds, to: nil)), in: window)
        }
    }

    private func closePicker() {
        mentionStart = nil
        picker.close()
    }

    /// Replaces the `@query` (or the `@@` chip and its query) with the element's token, or the
    /// `/query` with the command, and a space.
    private func pick(_ item: PickerItem) {
        guard let start = mentionStart, let storage = textStorage else { return }
        let range = NSRange(location: start, length: selectedRange().location - start)
        let inserted = switch item {
        case .mention(let mention): NSMutableAttributedString(attributedString: Self.token(mention))
        // Where the agent is shows in its token.
        case .remote(let remote):
            NSMutableAttributedString(attributedString: Self.token(BoardMention(name: remote.shown, type: "agent", id: remote.agent.id)))
        case .command: NSMutableAttributedString(string: item.title, attributes: Self.plain)
        }
        inserted.append(NSAttributedString(string: " ", attributes: Self.plain))
        storage.replaceCharacters(in: range, with: inserted)
        didChangeText()
        setSelectedRange(NSRange(location: start + inserted.length, length: 0))
        closePicker()
    }
}

/// What the text before the cursor asks the picker for: a `/command` that starts the draft, or
/// a word starting with `@@` (a worktree) or `@` (a board element), with where it starts.
enum PickerQuery: Equatable {
    case command(String)
    case mention(at: Int, String)
    case place(at: Int, String)

    static func parse(_ before: String) -> PickerQuery? {
        if before.hasPrefix("/"), !before.contains(where: \.isWhitespace) { return .command(before.dropFirst().lowercased()) }
        guard let at = before.range(of: "@", options: .backwards),
              !before[at.upperBound...].contains(where: \.isWhitespace) else { return nil }
        let query = before[at.upperBound...].lowercased()
        let startsWord = { (i: String.Index) in i == before.startIndex || before[before.index(before: i)].isWhitespace }
        let offset = { (i: String.Index) in before.utf16.distance(from: before.startIndex, to: i) }
        if startsWord(at.lowerBound) { return .mention(at: offset(at.lowerBound), query) }
        let first = before.index(before: at.lowerBound)
        return before[first] == "@" && startsWord(first) ? .place(at: offset(first), query) : nil
    }
}

/// An agent of another worktree, offered after `@@`.
struct RemoteAgent: Hashable {
    /// Nil on the user's own board, which no project holds.
    let project: String?
    let worktree: String
    let isBoard: Bool
    let agent: BoardMention
    /// The host it runs on, when not the composer's.
    var host: String? = nil

    /// The project a folder git no longer lists under any project belongs to, by the
    /// `<project>-worktrees/<branch>` layout new worktrees get; else the folder itself.
    static func project(ofFolder path: String) -> String? {
        guard !MyBoard.isBoard(path) else { return nil }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.hasSuffix("-worktrees") ? String(parent.dropLast("-worktrees".count)) : (path as NSString).lastPathComponent
    }

    /// Compact, for its token: Project › Worktree › Agent.
    var shown: String { [project, worktree, agent.name].compactMap(\.self).joined(separator: " › ") }

    /// Every word of `query` is in one of the three names, in any order.
    func matches(_ query: String) -> Bool {
        let names = [project ?? "", worktree, agent.name, host ?? ""].joined(separator: " ").lowercased()
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { names.contains($0) }
    }
}

/// A row of the composer's picker: a board element after `@`, the agent's command after `/`, or
/// another worktree's agent after `@@`.
enum PickerItem: Hashable {
    case mention(BoardMention)
    case command(AgentCommand)
    case remote(RemoteAgent)

    var title: String {
        switch self {
        case .mention(let mention): BoardName.clean(mention.name) ?? mention.type
        case .command(let command): "/" + command.name
        case .remote(let remote): remote.shown
        }
    }

    var detail: String {
        switch self {
        case .mention(let mention): mention.typeLabel
        case .command(let command): command.summary
        case .remote: ""
        }
    }

    /// The same icons the board's cards show; commands by where they come from.
    var icon: CardIcon {
        let symbol: String
        switch self {
        case .mention(let mention):
            if mention.type == "agent" { return CardFrame.agentIcon(provider: mention.provider) }
            symbol = Self.elementSymbols[mention.type] ?? "square.dashed"
        case .command(let command):
            symbol = switch command.kind {
            case .builtin: "command"
            case .skill: "sparkles"
            case .command: "doc.text"
            }
        case .remote(let remote): return CardFrame.agentIcon(provider: remote.agent.provider)
        }
        return .symbol(symbol, color: Theme.Hex.inkMuted)
    }

    private static let elementSymbols = ["runner": "play.rectangle", "postit": "note.text", "image": "photo", "video": "film",
                                         "browser": "globe", "simulator": "iphone", "filetree": "folder"]
}

@MainActor
@Observable
final class MentionPickerModel {
    var matches: [PickerItem] = []
    var selected = 0
}

/// The `@` list, in a borderless panel of its own under the composer, so the card's view
/// doesn't clip it. It never takes focus: typing stays in the composer.
@MainActor
private final class MentionPanel {
    let model = MentionPickerModel()
    private let pick: (PickerItem) -> Void
    private var panel: NSPanel?

    init(pick: @escaping (PickerItem) -> Void) {
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
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 232
    /// Room between the list and the panel's edge.
    static let margin: CGFloat = 4
    private static let row: CGFloat = 28

    let model: MentionPickerModel
    let pick: (PickerItem) -> Void
    @Environment(\.displayScale) private var scale

    @ViewBuilder private func glyph(_ icon: CardIcon) -> some View {
        if let image = icon.image(size: 13, scale: scale) { Image(decorative: image, scale: scale).frame(width: 16) }
    }

    var body: some View {
        VStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.matches.enumerated()), id: \.element) { index, item in
                            Button { pick(item) } label: {
                                HStack {
                                    if case .remote(let remote) = item {
                                        RemoteAgentRow(remote: remote, agentIcon: glyph(item.icon))
                                    } else {
                                        glyph(item.icon)
                                        Text(item.title).font(Theme.Font.body).foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(item.detail).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                                    }
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

/// `{project tile} Project  {worktree glyph} Worktree  {agent icon} Agent`, each name shrinking
/// before the next.
private struct RemoteAgentRow<Icon: View>: View {
    let remote: RemoteAgent
    let agentIcon: Icon

    var body: some View {
        HStack(spacing: 6) {
            if let project = remote.project {
                ProjectTile(name: project).scaleEffect(0.8).frame(width: 16, height: 16)
                name(project)
            }
            Image(systemName: remote.isBoard ? MyBoard.symbol : "arrow.triangle.branch")
                .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).frame(width: 16)
            name(remote.host.map { "\(remote.worktree) · \($0)" } ?? remote.worktree)
            agentIcon
            Text(BoardName.clean(remote.agent.name) ?? remote.agent.name).font(Theme.Font.body.weight(.semibold))
                .foregroundStyle(Theme.ink).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 0)
        }
    }

    private func name(_ text: String) -> some View {
        Text(text).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).lineLimit(1)
    }
}
