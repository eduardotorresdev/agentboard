import AppKit

/// A post-it's text laid out for drawing and hit-testing, at the card's own size: its markdown, rendered.
final class PostItText {
    let storage: NSTextStorage
    let layoutManager = NSLayoutManager()
    let container: NSTextContainer

    init(_ text: String, width: CGFloat) {
        storage = NSTextStorage(attributedString: MarkdownText.render(text))
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
    /// What a rendered paragraph is in markdown, a `PostItBlock`, when it is not plain text.
    static let postItBlock = NSAttributedString.Key("PostItBlock")
    /// On text the rendering put there (a bullet, a rule): the markdown it stands for.
    static let postItMarker = NSAttributedString.Key("PostItMarker")
}

/// The markdown block a rendered paragraph came from, so the text can be written back.
enum PostItBlock: Hashable {
    case heading(Int)
    case quote
    case code(String?)
    case row(header: Bool)
}

/// Styled text for a post-it: markdown (headings, lists, task lists, quotes, code, tables,
/// emphasis, links) rendered in handwriting at the card's base size. Rendered text the user
/// edited goes back to markdown with `markdown(from:)`.
enum MarkdownText {
    static let baseSize: CGFloat = 15
    static let codeSize: CGFloat = 12

    private static let indent: CGFloat = 18

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(cgColor: BoardPalette.rgb(hex, alpha)) ?? .black
    }

    /// The type size of a heading, or of plain text.
    static func size(heading level: Int?) -> CGFloat {
        level.map { [24, 20, 17][min(max($0, 1), 3) - 1] } ?? baseSize
    }

    static func font(size: CGFloat, bold: Bool, monospaced: Bool = false) -> NSFont {
        monospaced ? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : Theme.Font.hand(size: size, bold: bold)
    }

    static func paragraphStyle(heading level: Int?) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 6
        if let level {
            style.paragraphSpacingBefore = level <= 2 ? 6 : 2
            style.paragraphSpacing = 4
        }
        return style
    }

    /// What a plain paragraph or a heading is typed in.
    static func attributes(heading level: Int?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: size(heading: level), bold: level != nil), .paragraphStyle: paragraphStyle(heading: level),
            .foregroundColor: color(BoardPalette.ink, level == nil ? 0.85 : 1),
        ]
        if let level { attributes[.postItBlock] = PostItBlock.heading(level) }
        return attributes
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            // Markdown that can't be parsed shows as written.
            return NSAttributedString(string: markdown, attributes: attributes(heading: nil))
        }
        let output = NSMutableAttributedString()
        var block: Int?
        var cell: Int?
        var listItems = Set<Int>()
        var codeBlock: NSTextBlock?
        var quote: NSTextBlock?
        var underlined = false
        for run in parsed.runs {
            // Innermost first: the paragraph, then the list item and list it sits in, and so on.
            let components = run.presentationIntent?.components ?? []
            var text = String(parsed[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            // Markdown has no underline: `<u>` carries it.
            if inline.contains(.inlineHTML), ["<u>", "</u>"].contains(text) {
                underlined = text == "<u>"
                continue
            }
            // A break inside a paragraph must not start a new one.
            if inline.contains(.lineBreak) { text = "\u{2028}" }
            let row = components.first { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }
            let key = row?.identity ?? components.first?.identity ?? -1
            let paragraph = paragraphStyle(for: components)
            var attributes = inlineAttributes(for: run, components: components)
            attributes[.paragraphStyle] = paragraph
            if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if case .header(let level) = components.first?.kind { attributes[.postItBlock] = PostItBlock.heading(level) }
            if row != nil { attributes[.postItBlock] = PostItBlock.row(header: components.contains { if case .tableHeaderRow = $0.kind { true } else { false } }) }

            // Code blocks and quotes sit on a fill; consecutive paragraphs share one.
            if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
                if block != key || codeBlock == nil { codeBlock = filledBlock(alpha: 0.06) }
                for case .codeBlock(let language) in components.map(\.kind) { attributes[.postItBlock] = PostItBlock.code(language) }
                paragraph.textBlocks = [codeBlock!]
                text = text.hasSuffix("\n") ? String(text.dropLast()) : text
            } else {
                codeBlock = nil
            }
            if components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) {
                if quote == nil { quote = filledBlock(alpha: 0.04) }
                paragraph.textBlocks = paragraph.textBlocks + [quote!]
                attributes[.foregroundColor] = color(BoardPalette.ink, 0.65)
                if attributes[.postItBlock] == nil { attributes[.postItBlock] = PostItBlock.quote }
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
                underlined = false
                if let marker = listMarker(for: components, seen: &listItems) {
                    var marker = marker
                    var source = marker.hasSuffix(".") ? marker + " " : "- "
                    // Task lists: `- [ ]` and `- [x]` show as boxes.
                    for (prefix, box) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where text.hasPrefix(prefix) {
                        marker = box
                        source = "- " + prefix
                        text.removeFirst(prefix.count)
                    }
                    var markerAttributes = attributes
                    markerAttributes[.foregroundColor] = color(Theme.Hex.accentText)
                    markerAttributes[.font] = font(size: baseSize, bold: false)
                    markerAttributes.removeValue(forKey: .postItLink)
                    markerAttributes[.postItMarker] = String(repeating: "    ", count: listDepth(components) - 1) + source
                    output.append(NSAttributedString(string: marker + "\t", attributes: markerAttributes))
                }
                if components.contains(where: { if case .thematicBreak = $0.kind { true } else { false } }) {
                    var rule = attributes
                    rule[.foregroundColor] = color(BoardPalette.ink, 0.2)
                    rule[.postItMarker] = "---"
                    // The parser's own dash for the rule is not shown beside it.
                    text = ""
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
        let style = paragraphStyle(heading: components.first.flatMap { if case .header(let level) = $0.kind { level } else { nil } })
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
        if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
            style.paragraphSpacing = 0
            style.lineSpacing = 1
        }
        return style
    }

    private static func inlineAttributes(for run: AttributedString.Runs.Run, components: [PresentationIntent.IntentType])
        -> [NSAttributedString.Key: Any] {
        var size = baseSize
        var bold = false
        var monospaced = false
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(BoardPalette.ink, 0.85)]
        if case .header(let level) = components.first?.kind {
            size = Self.size(heading: level)
            bold = true
            attributes[.foregroundColor] = color(BoardPalette.ink)
        }
        if components.contains(where: { if case .tableHeaderRow = $0.kind { true } else { false } }) { bold = true }
        if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
            monospaced = true
            size = codeSize
        }
        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.stronglyEmphasized) { bold = true }
        if inline.contains(.code) {
            monospaced = true
            size = codeSize
            attributes[.backgroundColor] = color(BoardPalette.ink, 0.07)
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = color(BoardPalette.ink, 0.5)
        }
        // The handwriting has no italic face: emphasis slants it.
        if inline.contains(.emphasized) { attributes[.obliqueness] = 0.2 }
        attributes[.font] = font(size: size, bold: bold, monospaced: monospaced)
        if let link = run.link {
            attributes[.postItLink] = link
            attributes[.foregroundColor] = color(Theme.Hex.accentText)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    // MARK: Back to markdown

    private enum Group: Equatable {
        case plain, quote, row
        case item(ordered: Bool)
        case code(String?)
    }

    /// The markdown for text styled as `render` styles it, after the user edited it.
    /// shortcut: a paragraph typed inside a list item or quote, without its own marker, leaves the
    /// list; write the marker back on Return if lists are to be written as rich text.
    static func markdown(from rich: NSAttributedString) -> String {
        let string = rich.string as NSString
        var result = ""
        var last: Group?
        var gap = false
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = range.upperBound
            var content = range
            if [0x0A, 0x0D, 0x2029].contains(string.character(at: range.upperBound - 1)) { content.length -= 1 }
            let line = rich.attributedSubstring(from: content)
            let block = rich.attribute(.postItBlock, at: range.location, effectiveRange: nil) as? PostItBlock
            var group = Group.plain
            let text: String
            if case .code(let language) = block {
                group = .code(language)
                text = line.string
            } else if line.string.trimmingCharacters(in: .whitespaces).isEmpty {
                gap = true
                continue
            } else {
                switch block {
                case .heading(let level):
                    text = inline(line, prefix: String(repeating: "#", count: min(max(level, 1), 6)) + " ", plainBold: true)
                case .quote:
                    group = .quote
                    text = inline(line, prefix: "> ")
                case .row(let header):
                    group = .row
                    let cells = inline(line, plainBold: header).components(separatedBy: "\t")
                    text = "| " + cells.joined(separator: " | ") + " |" + (header ? "\n|" + String(repeating: " --- |", count: cells.count) : "")
                default:
                    if let marker = line.attribute(.postItMarker, at: 0, effectiveRange: nil) as? String, marker != "---" {
                        // A nested item belongs to the list around it; another kind of marker starts a new list.
                        if marker.hasPrefix(" "), case .item = last, !gap { group = last! } else { group = .item(ordered: !marker.hasPrefix("-")) }
                    }
                    text = inline(line)
                }
            }
            if !gap, last == group, group != .plain {
                // Paragraphs of one quote stay apart; rows, items and code lines follow each other.
                result += group == .quote ? "\n>\n" : "\n"
            } else {
                if case .code = last { result += "\n```" }
                if last != nil { result += "\n\n" }
                if case .code(let language) = group { result += "```\(language ?? "")\n" }
            }
            result += text
            last = group
            gap = false
        }
        if case .code = last { result += "\n```" }
        return result
    }

    /// One paragraph's text with its emphasis, links and markers as markdown; `prefix` goes after
    /// the list marker. `plainBold`: the paragraph is bold as a whole (a heading), not marked so.
    private static func inline(_ line: NSAttributedString, prefix: String = "", plainBold: Bool = false) -> String {
        var out = ""
        var open: [(open: String, close: String)] = []
        var started = false
        // Closing marks hug the text: trailing spaces move outside them, or they would not parse.
        func close(to count: Int) {
            guard open.count > count else { return }
            let trailing = String(out.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            out.removeLast(trailing.count)
            while open.count > count { out += open.removeLast().close }
            out += trailing
        }
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attributes, range, _ in
            var text = (line.string as NSString).substring(with: range)
            if let marker = attributes[.postItMarker] as? String {
                close(to: 0)
                out += marker
                return
            }
            if !started {
                text = String(text.drop { $0 == " " })
                guard !text.isEmpty else { return }
                out += prefix
            }
            defer { started = true }
            guard !text.allSatisfy({ $0 == " " || $0 == "\t" }) else {
                out += text
                return
            }
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let link = attributes[.postItLink] as? URL
            var wanted: [(open: String, close: String)] = []
            if let link { wanted.append(("[", "](\(link.absoluteString))")) }
            if traits.contains(.bold), !plainBold { wanted.append(("**", "**")) }
            if traits.contains(.italic) || attributes[.obliqueness] != nil { wanted.append(("*", "*")) }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { wanted.append(("~~", "~~")) }
            if link == nil, (attributes[.underlineStyle] as? Int ?? 0) != 0 { wanted.append(("<u>", "</u>")) }
            // Close what this run does not have, innermost first, then open what is new.
            close(to: zip(open, wanted).prefix { $0.close == $1.close }.count)
            let leading = String(text.prefix { $0 == " " || $0 == "\t" })
            out += leading
            text.removeFirst(leading.count)
            for mark in wanted[open.count...] {
                out += mark.open
                open.append(mark)
            }
            out += traits.contains(.monoSpace) ? "`\(text)`" : escape(text, lineStart: !started)
        }
        close(to: 0)
        return started ? out : out + prefix
    }

    /// Typed text that would read as markdown is escaped, so it comes back as typed.
    /// shortcut: `|` is not escaped, a table cell with one splits in two; escape it per row if cells need it.
    private static func escape(_ text: String, lineStart: Bool) -> String {
        var text = text.replacingOccurrences(of: #"([\\*`\[<~])"#, with: #"\\$1"#, options: .regularExpression)
            .replacingOccurrences(of: #"(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])"#, with: #"\\_"#, options: .regularExpression)
            .replacingOccurrences(of: "\u{2028}", with: "\\\n")
        if lineStart {
            text = text.replacingOccurrences(of: #"^([#>+-])"#, with: #"\\$1"#, options: .regularExpression)
                .replacingOccurrences(of: #"^(\d+)([.)])"#, with: #"$1\\$2"#, options: .regularExpression)
        }
        return text
    }
}
