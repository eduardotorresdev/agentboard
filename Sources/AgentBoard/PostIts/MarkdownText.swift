import AppKit

/// A post-it's text laid out for drawing and hit-testing, at the card's own size: rendered
/// markdown, or the source itself in monospace.
final class PostItText {
    enum Form: Equatable {
        case rendered
        case source
    }

    let storage: NSTextStorage
    let layoutManager = NSLayoutManager()
    let container: NSTextContainer

    init(_ text: String, form: Form, width: CGFloat) {
        storage = NSTextStorage(attributedString: form == .rendered ? MarkdownText.render(text) : MarkdownText.source(text))
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
    }

    var height: CGFloat { ceil(layoutManager.usedRect(for: container).height) }

    /// Draws the text with its top-left at `origin`, in a flipped context.
    func draw(at origin: CGPoint, visible: CGRect) {
        let range = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        layoutManager.drawBackground(forGlyphRange: range, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
    }

    /// The link under `point`, in the text's own coordinates.
    func link(at point: CGPoint) -> URL? {
        guard storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.postItLink, at: index, effectiveRange: nil) as? URL
    }
}

extension NSAttributedString.Key {
    /// A link's address. Not `.link`, which text drawing paints in the system's link color.
    static let postItLink = NSAttributedString.Key("PostItLink")
}

/// Styled text for a post-it: markdown (headings, lists, task lists, quotes, code, tables,
/// emphasis, links) rendered at the card's base size, or the source shown as written.
enum MarkdownText {
    static let baseSize: CGFloat = 13
    static let codeSize: CGFloat = 12
    static let sourceFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)

    private static let indent: CGFloat = 18

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(cgColor: BoardPalette.rgb(hex, alpha)) ?? .black
    }

    static func source(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [.font: sourceFont, .foregroundColor: color(BoardPalette.ink, 0.85),
                                                             .paragraphStyle: style])
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return source(markdown) }
        let output = NSMutableAttributedString()
        var block: Int?
        var cell: Int?
        var listItems = Set<Int>()
        var codeBlock: NSTextBlock?
        var quote: NSTextBlock?
        for run in parsed.runs {
            // Innermost first: the paragraph, then the list item and list it sits in, and so on.
            let components = run.presentationIntent?.components ?? []
            var text = String(parsed[run.range].characters)
            let row = components.first { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }
            let key = row?.identity ?? components.first?.identity ?? -1
            let paragraph = paragraphStyle(for: components)
            var attributes = inlineAttributes(for: run, components: components)
            attributes[.paragraphStyle] = paragraph

            // Code blocks and quotes sit on a fill; consecutive paragraphs share one.
            if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
                if block != key || codeBlock == nil { codeBlock = filledBlock(alpha: 0.06) }
                paragraph.textBlocks = [codeBlock!]
                text = text.hasSuffix("\n") ? String(text.dropLast()) : text
            } else {
                codeBlock = nil
            }
            if components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) {
                if quote == nil { quote = filledBlock(alpha: 0.04) }
                paragraph.textBlocks = paragraph.textBlocks + [quote!]
                attributes[.foregroundColor] = color(BoardPalette.ink, 0.65)
            } else {
                quote = nil
            }

            if key != block {
                if output.length > 0 {
                    // The line break ends the paragraph before: its style, none of its last run's fills.
                    let last = output.attributes(at: output.length - 1, effectiveRange: nil)
                    output.append(NSAttributedString(string: "\n", attributes: last.filter { $0.key == .paragraphStyle || $0.key == .font }))
                    // A gap below a fill, unless the next paragraph sits on the same one.
                    let fills = (last[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
                    if let fill = fills.last, paragraph.textBlocks.last !== fill {
                        output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                    }
                }
                block = key
                cell = nil
                if let marker = listMarker(for: components, seen: &listItems) {
                    var marker = marker
                    // Task lists: `- [ ]` and `- [x]` show as boxes.
                    for (prefix, box) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where text.hasPrefix(prefix) {
                        marker = box
                        text.removeFirst(prefix.count)
                    }
                    var markerAttributes = attributes
                    markerAttributes[.foregroundColor] = color(BoardPalette.accent)
                    markerAttributes[.font] = NSFont.systemFont(ofSize: baseSize)
                    markerAttributes.removeValue(forKey: .postItLink)
                    output.append(NSAttributedString(string: marker + "\t", attributes: markerAttributes))
                }
                if components.contains(where: { if case .thematicBreak = $0.kind { true } else { false } }) {
                    var rule = attributes
                    rule[.foregroundColor] = color(BoardPalette.ink, 0.2)
                    output.append(NSAttributedString(string: "· · ·", attributes: rule))
                }
            }
            // Table cells of a row are laid out on tab stops.
            if let cellComponent = components.first(where: { if case .tableCell = $0.kind { true } else { false } }) {
                if let cell, cell != cellComponent.identity { output.append(NSAttributedString(string: "\t", attributes: attributes)) }
                cell = cellComponent.identity
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }

    private static func filledBlock(alpha: CGFloat) -> NSTextBlock {
        let block = NSTextBlock()
        block.backgroundColor = color(BoardPalette.ink, alpha)
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    /// The bullet, number or nothing before a paragraph: only the first paragraph of a list item
    /// gets one.
    private static func listMarker(for components: [PresentationIntent.IntentType], seen: inout Set<Int>) -> String? {
        guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case .listItem(let ordinal) = components[itemIndex].kind,
              seen.insert(components[itemIndex].identity).inserted else { return nil }
        let ordered = components[(itemIndex + 1)...].first { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }
        if case .orderedList = ordered?.kind { return "\(ordinal)." }
        return listDepth(components) > 1 ? "◦" : "•"
    }

    private static func listDepth(_ components: [PresentationIntent.IntentType]) -> Int {
        components.filter { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }.count
    }

    private static func paragraphStyle(for components: [PresentationIntent.IntentType]) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 6
        let depth = CGFloat(listDepth(components))
        if depth > 0 {
            style.headIndent = depth * indent
            style.firstLineHeadIndent = (depth - 1) * indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: depth * indent)]
            style.paragraphSpacing = 3
        }
        if components.contains(where: { if case .tableCell = $0.kind { true } else { false } }) {
            style.tabStops = (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 96) }
            style.paragraphSpacing = 3
        }
        if case .header(let level) = components.first?.kind {
            style.paragraphSpacingBefore = level <= 2 ? 6 : 2
            style.paragraphSpacing = 4
        }
        if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
            style.paragraphSpacing = 0
            style.lineSpacing = 1
        }
        return style
    }

    private static func inlineAttributes(for run: AttributedString.Runs.Run, components: [PresentationIntent.IntentType])
        -> [NSAttributedString.Key: Any] {
        var size = baseSize
        var weight = NSFont.Weight.regular
        var monospaced = false
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(BoardPalette.ink, 0.85)]
        if case .header(let level) = components.first?.kind {
            size = [18, 16, 14][min(level, 3) - 1]
            weight = level <= 2 ? .bold : .semibold
            attributes[.foregroundColor] = color(BoardPalette.ink)
        }
        if components.contains(where: { if case .tableHeaderRow = $0.kind { true } else { false } }) { weight = .semibold }
        if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
            monospaced = true
            size = codeSize
        }
        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.stronglyEmphasized) { weight = .bold }
        if inline.contains(.code) {
            monospaced = true
            size = codeSize
            attributes[.backgroundColor] = color(BoardPalette.ink, 0.07)
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = color(BoardPalette.ink, 0.5)
        }
        var font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if inline.contains(.emphasized) {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: size) ?? font
        }
        attributes[.font] = font
        if let link = run.link {
            attributes[.postItLink] = link
            attributes[.foregroundColor] = color(BoardPalette.accent)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }
}
