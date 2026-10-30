import AppKit

/// The text view a post-it's markdown is written in, laid over the card while the user writes.
/// What is typed reaches the core shortly after typing pauses, and when writing ends.
@MainActor
final class PostItEditor: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: NSTextView
    /// Sends the text.
    var onWrite: ((String) -> Void)?
    /// Escape: stop writing.
    var onEscape: (() -> Void)?
    /// Typed since the text was last sent.
    private(set) var isDirty = false
    private var pending: DispatchWorkItem?
    private var zoom: CGFloat = 0

    override init() {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init()
        let paper = NSColor(cgColor: BoardPalette.rgb(BoardPalette.postIt)) ?? .white
        scrollView.drawsBackground = true
        scrollView.backgroundColor = paper
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        textView.delegate = self
        textView.backgroundColor = paper
        textView.isRichText = false
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

    var text: String { textView.string }

    /// Shows `text` in place of what is there, keeping the cursor where it can.
    func show(_ text: String) {
        let selection = textView.selectedRange()
        textView.string = text
        applyStyle()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        isDirty = false
    }

    /// Sizes the text for the board's zoom, as the card draws it at that zoom.
    func setZoom(_ zoom: CGFloat) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        applyStyle()
    }

    /// How far the text is scrolled, in the card's own points.
    var scroll: CGFloat {
        get { scrollView.contentView.bounds.minY / max(zoom, 0.01) }
        set {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: max(0, newValue * zoom)))
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
        let index = textView.characterIndexForInsertion(at: CGPoint(x: point.x * zoom, y: point.y * zoom))
        textView.setSelectedRange(NSRange(location: index, length: 0))
    }

    /// Sends what was typed now, if anything was.
    func flush() {
        pending?.cancel()
        pending = nil
        guard isDirty else { return }
        isDirty = false
        onWrite?(textView.string)
    }

    private func applyStyle() {
        let font = NSFont.monospacedSystemFont(ofSize: MarkdownText.codeSize * max(zoom, 0.01), weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2 * zoom
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: style,
            .foregroundColor: NSColor(cgColor: BoardPalette.rgb(BoardPalette.ink, 0.85)) ?? .textColor,
        ]
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onEscape?()
        return true
    }
}
