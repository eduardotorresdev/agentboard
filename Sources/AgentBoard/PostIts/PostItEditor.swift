import AppKit

/// What the format toolbar shows as on, for the text at the cursor.
struct PostItFormat: Equatable {
    var heading: Int?
    var bold = false
    var underline = false
}

/// Pasted text takes the post-it's own style, not the one it was copied with.
private final class PostItTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// The text view a post-it is written in, laid over the card while the user writes: rich text
/// kept as markdown. What is typed reaches the core shortly after typing
/// pauses, and when writing ends.
@MainActor
final class PostItEditor: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: NSTextView
    /// Sends the text.
    var onWrite: ((String) -> Void)?
    /// Escape: stop writing.
    var onEscape: (() -> Void)?
    /// The style at the cursor changed.
    var onFormat: ((PostItFormat?) -> Void)?
    /// Typed since the text was last sent.
    private(set) var isDirty = false
    /// The markdown last shown or sent.
    private(set) var text = ""
    private var pending: DispatchWorkItem?

    override init() {
        scrollView = PostItTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init()
        let paper = NSColor(cgColor: BoardPalette.rgb(BoardPalette.postIt)) ?? .white
        scrollView.drawsBackground = true
        scrollView.backgroundColor = paper
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // The text is laid out at the card's own size and magnified to the board's zoom.
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 100
        // Fills behind code and quotes are drawn by the older text system only.
        _ = textView.layoutManager
        textView.delegate = self
        textView.backgroundColor = paper
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.insertionPointColor = NSColor(cgColor: BoardPalette.rgb(BoardPalette.accent)) ?? .controlAccentColor
        textView.selectedTextAttributes = [.backgroundColor: NSColor(cgColor: BoardPalette.rgb(BoardPalette.accent, 0.2)) ?? .selectedTextBackgroundColor]
        // Markdown is written as typed: no smart quotes, dashes or corrections.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
    }

    /// Shows `text` in place of what is there, keeping the cursor where it can.
    func show(_ text: String) {
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(MarkdownText.render(text))
        textView.setSelectedRange(NSRange(location: min(selection.location, textView.textStorage?.length ?? 0), length: 0))
        if textView.textStorage?.length == 0 {
            textView.typingAttributes = MarkdownText.attributes(heading: nil)
        }
        self.text = text
        isDirty = false
        reportFormat()
    }

    /// Lays the editor over `frame`, its text magnified to the board's zoom.
    func place(_ frame: CGRect, zoom: CGFloat) {
        scrollView.frame = frame
        if scrollView.magnification != zoom { scrollView.magnification = zoom }
        // Magnifying does not resize the text view, only a new frame does.
        let width = frame.width / max(zoom, 0.01)
        if abs(textView.frame.width - width) > 0.01 { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
    }

    /// How far the text is scrolled, in the card's own points.
    var scroll: CGFloat {
        get { scrollView.contentView.bounds.minY }
        set {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: max(0, newValue)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Puts the cursor at a point in the card's text coordinates (unscrolled).
    func placeCursor(at point: CGPoint?) {
        guard let point else {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            return
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.setSelectedRange(NSRange(location: textView.characterIndexForInsertion(at: point), length: 0))
    }

    /// Sends what was typed now, if anything was.
    func flush() {
        pending?.cancel()
        pending = nil
        guard isDirty, let storage = textView.textStorage else { return }
        isDirty = false
        text = MarkdownText.markdown(from: storage)
        onWrite?(text)
    }

    // MARK: Format

    /// Makes the paragraphs under the selection a heading of `level`, or plain text.
    func setHeading(_ level: Int?) {
        guard let storage = textView.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        restyle(range) {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                guard let font = attributes[.font] as? NSFont else { return }
                let traits = font.fontDescriptor.symbolicTraits
                guard !traits.contains(.monoSpace) else { return }
                var wasHeading = false
                if case .heading = attributes[.postItBlock] as? PostItBlock { wasHeading = true }
                // A heading is bold as a whole; back to plain text, what was bold before stays so.
                let bold = level != nil || (!wasHeading && traits.contains(.bold))
                storage.addAttribute(.font, value: MarkdownText.font(size: MarkdownText.size(heading: level), bold: bold), range: run)
            }
            storage.removeAttribute(.postItBlock, range: range)
            if let level { storage.addAttribute(.postItBlock, value: PostItBlock.heading(level), range: range) }
            storage.addAttribute(.paragraphStyle, value: MarkdownText.paragraphStyle(heading: level), range: range)
        }
        var typing = textView.typingAttributes.filter { $0.key != .postItBlock }
        typing.merge(MarkdownText.attributes(heading: level)) { $1 }
        textView.typingAttributes = typing
        reportFormat()
    }

    func toggleBold() {
        guard let format, format.heading == nil else { return }
        let bold = !format.bold
        func restyled(_ font: NSFont) -> NSFont {
            MarkdownText.font(size: font.pointSize, bold: bold, monospaced: font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
        let range = textView.selectedRange()
        if range.length > 0, let storage = textView.textStorage {
            restyle(range) {
                storage.enumerateAttribute(.font, in: range) { font, run, _ in
                    if let font = font as? NSFont { storage.addAttribute(.font, value: restyled(font), range: run) }
                }
            }
        }
        if let font = textView.typingAttributes[.font] as? NSFont { textView.typingAttributes[.font] = restyled(font) }
        reportFormat()
    }

    func toggleUnderline() {
        guard let format else { return }
        let range = textView.selectedRange()
        if range.length > 0, let storage = textView.textStorage {
            restyle(range) {
                storage.removeAttribute(.underlineStyle, range: range)
                if !format.underline { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            }
        }
        textView.typingAttributes[.underlineStyle] = format.underline ? nil : NSUnderlineStyle.single.rawValue
        reportFormat()
    }

    /// Changes attributes as an edit of the user's: undoable, and sent like typing.
    private func restyle(_ range: NSRange, _ change: () -> Void) {
        guard range.length > 0, let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change()
        storage.endEditing()
        textView.didChangeText()
    }

    /// The style of the selection's start, or of what would be typed at the cursor.
    private var format: PostItFormat? {
        guard let storage = textView.textStorage else { return nil }
        let range = textView.selectedRange()
        let attributes = range.length > 0 && range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil) : textView.typingAttributes
        var format = PostItFormat()
        if case .heading(let level) = attributes[.postItBlock] as? PostItBlock { format.heading = min(level, 3) }
        format.bold = format.heading == nil && (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
        format.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        return format
    }

    private func reportFormat() { onFormat?(format) }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) { reportFormat() }

    /// Text typed after a bullet is the item's text, not more of the bullet.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        guard newTypingAttributes[.postItMarker] != nil else { return newTypingAttributes }
        var attributes = newTypingAttributes.filter { $0.key != .postItMarker }
        attributes[.foregroundColor] = MarkdownText.attributes(heading: nil)[.foregroundColor]
        return attributes
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onEscape?()
        return true
    }
}
