import AppKit
import Orchestration
import QuartzCore

/// What the pointer can act on in a notes card.
enum NotesControl: Equatable {
    case close
    case add
    /// An entry's ✕, which removes it.
    case delete(UUID)
    /// A note's text, which edits it.
    case entry(UUID)
}

/// Where everything in a notes card sits, in the card's own coordinates: shared by the layer that
/// draws it and the board that hit-tests it. Rows are laid out in the list's own coordinates
/// (`list`), which scroll under `content`.
struct NotesCardLayout {
    struct Row {
        let entry: NoteEntry
        let frame: CGRect
        let header: CGRect
        let text: CGRect
        let place: CGRect?
        let delete: CGRect
    }

    let dot: CGRect
    let title: CGRect
    let close: CGRect
    /// The button that adds a note, or the field a new note is written in.
    let add: CGRect
    /// Where the list shows.
    let content: CGRect
    let rows: [Row]
    /// Section titles, in list coordinates.
    let sections: [(title: String, frame: CGRect)]
    /// The list's whole height.
    let height: CGFloat

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let sectionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let authorFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let timeFont = NSFont.systemFont(ofSize: 11)
    static let textFont = NSFont.systemFont(ofSize: 12)
    static let placeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let rowPadding: CGFloat = 10
    static let deleteSize: CGFloat = 18
    static let addHeight: CGFloat = 30
    /// The add field while a note is written: room for a few lines.
    static let addEditingHeight: CGFloat = 76

    /// `adding`: a new note is being written, so the add button is a taller field.
    init(size: CGSize, record: NotesRecord, adding: Bool) {
        let bounds = CGRect(origin: .zero, size: size)
        let mid = CardMetrics.titleHeight / 2
        dot = CGRect(x: CardMetrics.inset + 2, y: mid - 3.5, width: 7, height: 7)
        close = CardMetrics.close(of: bounds)
        title = CGRect(x: dot.maxX + 8, y: mid - 9, width: max(0, close.minX - dot.maxX - 16), height: 18)
        let addHeight = adding ? Self.addEditingHeight : Self.addHeight
        add = CGRect(x: CardMetrics.inset, y: size.height - CardMetrics.inset - addHeight,
                     width: size.width - CardMetrics.inset * 2, height: addHeight)
        content = CGRect(x: CardMetrics.inset, y: CardMetrics.titleHeight,
                         width: size.width - CardMetrics.inset * 2, height: max(0, add.minY - 8 - CardMetrics.titleHeight))

        var rows: [Row] = []
        var sections: [(String, CGRect)] = []
        var y: CGFloat = 0
        let width = content.width
        let textWidth = max(40, width - Self.rowPadding * 2)
        let sectionLine = Self.lineHeight(Self.sectionFont)
        for (title, entries) in [(L("Working on"), record.statuses), (L("Notes"), record.notes)] where !entries.isEmpty {
            if !sections.isEmpty { y += 10 }
            sections.append((title, CGRect(x: 4, y: y, width: width - 8, height: sectionLine)))
            y += sectionLine + 6
            for entry in entries {
                let top = y
                y += Self.rowPadding
                let header = CGRect(x: Self.rowPadding, y: y, width: textWidth - Self.deleteSize, height: Self.lineHeight(Self.authorFont))
                y = header.maxY + 3
                let textHeight = Self.height(of: entry.text.isEmpty ? " " : entry.text, font: Self.textFont, width: textWidth)
                let text = CGRect(x: Self.rowPadding, y: y, width: textWidth, height: textHeight)
                y = text.maxY
                var place: CGRect?
                if let where_ = entry.place, !where_.isEmpty {
                    let rect = CGRect(x: Self.rowPadding, y: y + 3, width: textWidth,
                                      height: Self.height(of: where_, font: Self.placeFont, width: textWidth))
                    place = rect
                    y = rect.maxY
                }
                y += Self.rowPadding
                let frame = CGRect(x: 0, y: top, width: width, height: y - top)
                let delete = CGRect(x: frame.maxX - Self.rowPadding / 2 - Self.deleteSize, y: top + 6, width: Self.deleteSize, height: Self.deleteSize)
                rows.append(Row(entry: entry, frame: frame, header: header, text: text, place: place, delete: delete))
                y += 6
            }
        }
        self.rows = rows
        self.sections = sections
        height = y
    }

    /// How far the list scrolls at most.
    var maxScroll: CGFloat { max(0, height - content.height) }

    /// The control under `point` (card coordinates), with the list scrolled by `scroll`.
    func control(at point: CGPoint, scroll: CGFloat) -> NotesControl? {
        if close.contains(point) { return .close }
        if add.contains(point) { return .add }
        guard content.contains(point) else { return nil }
        let local = CGPoint(x: point.x - content.minX, y: point.y - content.minY + scroll)
        guard let row = rows.first(where: { $0.frame.contains(local) }) else { return nil }
        if row.delete.insetBy(dx: -4, dy: -4).contains(local) { return .delete(row.entry.id) }
        return row.entry.kind == .note ? .entry(row.entry.id) : nil
    }

    /// A row's text area in card coordinates, scrolled by `scroll`.
    func textFrame(of entry: UUID, scroll: CGFloat) -> CGRect? {
        rows.first { $0.entry.id == entry }.map { $0.text.offsetBy(dx: content.minX, dy: content.minY - scroll) }
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
    }

    /// When an entry was written: the time today, the date before.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jm" : "dMMM")
        return formatter.string(from: date)
    }
}

/// One notes card: chrome as Core Animation layers like the other cards, and the list drawn into
/// one layer that is redrawn only when what it shows changes.
final class NotesCardLayer: CALayer {
    private let dot = CALayer()
    private let title = CATextLayer()
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let list = NotesListLayer()
    private let addButton = CALayer()
    private let addLabel = CATextLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?

    override init() {
        super.init()
        backgroundColor = BoardPalette.card
        cornerRadius = CardMetrics.radius
        shadowColor = BoardPalette.rgb(BoardPalette.ink)
        dot.cornerRadius = 3.5
        dot.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
        closeHover.cornerRadius = CardMetrics.closeSize / 2
        closeHover.backgroundColor = BoardPalette.rgb(BoardPalette.accent, 0.12)
        for text in [title, closeGlyph, addLabel] {
            text.fontSize = 12
            text.truncationMode = .end
        }
        title.font = NotesCardLayout.titleFont
        closeGlyph.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeGlyph.string = "✕"
        closeGlyph.alignmentMode = .center
        addLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        addLabel.string = "+ " + L("Add note")
        addLabel.alignmentMode = .center
        addButton.addSublayer(addLabel)
        list.masksToBounds = true
        list.needsDisplayOnBoundsChange = true
        [dot, title, closeHover, closeGlyph, list, addButton].forEach(addSublayer)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: CardMetrics.handleSize, height: CardMetrics.handleSize)
            handle.cornerRadius = CardMetrics.handleSize / 2
            handle.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
            handle.borderColor = BoardPalette.card
            handle.borderWidth = 2
            handle.shadowColor = BoardPalette.rgb(BoardPalette.ink)
            handle.shadowOpacity = 0.18
            handle.shadowRadius = 3
            handle.shadowOffset = CGSize(width: 0, height: 1)
            handle.isHidden = true
            handle.zPosition = 10
            addSublayer(handle)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `editing`: the entry whose text a field covers, or nil; `adding`: the add field is open.
    func update(frame: CGRect, record: NotesRecord, layout: NotesCardLayout, scroll: CGFloat, focused: Bool,
                hovered: NotesControl?, hoveredRow: UUID?, editing: UUID?, adding: Bool, scale: CGFloat) {
        self.frame = frame
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: CardMetrics.radius, cornerHeight: CardMetrics.radius, transform: nil)
        shadowOpacity = focused ? 0.16 : 0.08
        shadowRadius = focused ? 14 : 8
        shadowOffset = CGSize(width: 0, height: focused ? 12 : 5)
        for layer in [title, closeGlyph, addLabel] { layer.contentsScale = scale }

        let ink = BoardPalette.ink
        let line = NotesCardLayout.lineHeight(NotesCardLayout.titleFont) + 2
        dot.frame = layout.dot
        title.string = record.name
        title.foregroundColor = BoardPalette.rgb(ink, focused ? 0.9 : 0.6)
        title.frame = CGRect(x: layout.title.minX, y: layout.title.midY - line / 2, width: layout.title.width, height: line)
        closeHover.frame = layout.close
        closeHover.isHidden = hovered != .close
        closeGlyph.foregroundColor = BoardPalette.rgb(ink, hovered == .close ? 0.8 : 0.4)
        closeGlyph.frame = CGRect(x: layout.close.minX, y: layout.close.midY - line / 2, width: layout.close.width, height: line)

        addButton.frame = layout.add
        addButton.cornerRadius = 10
        addButton.backgroundColor = BoardPalette.rgb(BoardPalette.accent, hovered == .add ? 0.14 : 0.08)
        addButton.isHidden = adding
        addLabel.foregroundColor = BoardPalette.rgb(BoardPalette.accent)
        addLabel.frame = CGRect(x: 8, y: (layout.add.height - line) / 2, width: max(0, layout.add.width - 16), height: line)

        list.frame = layout.content
        list.contentsScale = scale
        list.show(NotesListLayer.Model(layout: layout, scroll: scroll, hoveredRow: hoveredRow,
                                       hoveredDelete: { if case .delete(let id) = hovered { id } else { nil } }(),
                                       editing: editing))
    }

    func updateHandles(visible: Bool, hovered: Int?, linkTarget: Bool) {
        for (handle, point) in zip(handles, CardMetrics.handles(of: bounds)) { handle.position = point }
        if visible != handlesVisible {
            handlesVisible = visible
            for handle in handles {
                handle.isHidden = !visible
                if visible { handle.add(Self.spring("opacity", from: 0, to: 1, stiffness: 300, damping: 26), forKey: "appear") }
            }
        }
        if hovered != hoveredHandle {
            for (index, handle) in handles.enumerated() where index == hovered || index == hoveredHandle {
                let grow = index == hovered
                let scale: CGFloat = grow ? 1.4 : 1
                handle.add(Self.spring("transform.scale", from: handle.presentation()?.value(forKeyPath: "transform.scale") ?? (grow ? 1 : 1.4),
                                       to: scale, stiffness: 400, damping: 22), forKey: "scale")
                handle.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            hoveredHandle = hovered
        }
        if linkTarget {
            shadowColor = BoardPalette.rgb(BoardPalette.accent)
            shadowOpacity = 0.45
            shadowRadius = 18
            shadowOffset = .zero
        } else {
            shadowColor = BoardPalette.rgb(BoardPalette.ink)
        }
    }

    func animateAppearance() {
        add(Self.spring("opacity", from: 0, to: 1, stiffness: 240, damping: 24), forKey: "appear-fade")
        add(Self.spring("transform.translation.y", from: 14, to: 0, stiffness: 240, damping: 24), forKey: "appear-rise")
    }

    private static func spring(_ keyPath: String, from: Any?, to: Any, stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        return spring
    }
}

/// The statuses and notes, drawn as text into the layer's contents.
private final class NotesListLayer: CALayer {
    struct Model: Equatable {
        let rows: [NoteEntry]
        let frames: [CGRect]
        let scroll: CGFloat
        let hoveredRow: UUID?
        let hoveredDelete: UUID?
        let editing: UUID?
        fileprivate let layout: NotesCardLayout

        init(layout: NotesCardLayout, scroll: CGFloat, hoveredRow: UUID?, hoveredDelete: UUID?, editing: UUID?) {
            self.layout = layout
            rows = layout.rows.map(\.entry)
            frames = layout.rows.map(\.frame)
            self.scroll = scroll
            self.hoveredRow = hoveredRow
            self.hoveredDelete = hoveredDelete
            self.editing = editing
        }

        static func == (a: Model, b: Model) -> Bool {
            a.rows == b.rows && a.frames == b.frames && a.scroll == b.scroll && a.hoveredRow == b.hoveredRow
                && a.hoveredDelete == b.hoveredDelete && a.editing == b.editing
                && a.layout.sections.map(\.frame) == b.layout.sections.map(\.frame)
        }
    }

    private var model: Model?
    private var drawnScale: CGFloat = 0

    func show(_ model: Model) {
        guard model != self.model || drawnScale != contentsScale else { return }
        self.model = model
        drawnScale = contentsScale
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let model else { return }
        let layout = model.layout
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ink = BoardPalette.ink
        func color(_ hex: UInt32, _ alpha: CGFloat) -> NSColor { NSColor(cgColor: BoardPalette.rgb(hex, alpha)) ?? .black }

        guard !layout.rows.isEmpty else {
            let empty = L("Nothing here yet.") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NotesCardLayout.textFont, .foregroundColor: color(ink, 0.4)]
            let size = empty.size(withAttributes: attributes)
            empty.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }
        ctx.translateBy(x: 0, y: -model.scroll)
        let visible = bounds.offsetBy(dx: 0, dy: model.scroll)
        for section in layout.sections where section.frame.intersects(visible) {
            (section.title.uppercased() as NSString).draw(in: section.frame, withAttributes: [
                .font: NotesCardLayout.sectionFont, .foregroundColor: color(ink, 0.45), .kern: 0.4,
            ])
        }
        for row in layout.rows where row.frame.intersects(visible) {
            let entry = row.entry
            let hovered = model.hoveredRow == entry.id
            ctx.setFillColor(BoardPalette.rgb(ink, hovered ? 0.06 : 0.035))
            ctx.addPath(CGPath(roundedRect: row.frame, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()

            // Agents in violet, the user in orange.
            let author = entry.author == nil ? L("You") : entry.authorName
            let authorColor = entry.author == nil ? color(BoardPalette.secondary, 1) : color(BoardPalette.accent, 1)
            let header = NSMutableAttributedString(string: author, attributes: [.font: NotesCardLayout.authorFont, .foregroundColor: authorColor])
            header.append(NSAttributedString(string: "  " + NotesCardLayout.time(entry.updated),
                                             attributes: [.font: NotesCardLayout.timeFont, .foregroundColor: color(ink, 0.4)]))
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            header.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: header.length))
            header.draw(with: row.header, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            if model.editing != entry.id {
                (entry.text as NSString).draw(with: row.text, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                              attributes: [.font: NotesCardLayout.textFont, .foregroundColor: color(ink, 0.85)])
            }
            if let place = row.place, let text = entry.place {
                (text as NSString).draw(with: place, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: [.font: NotesCardLayout.placeFont, .foregroundColor: color(ink, 0.5)])
            }
            if hovered {
                let deleteHovered = model.hoveredDelete == entry.id
                if deleteHovered {
                    ctx.setFillColor(BoardPalette.rgb(BoardPalette.accent, 0.12))
                    ctx.fillEllipse(in: row.delete)
                }
                let glyph = "✕" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                 .foregroundColor: color(ink, deleteHovered ? 0.8 : 0.4)]
                let size = glyph.size(withAttributes: attributes)
                glyph.draw(at: CGPoint(x: row.delete.midX - size.width / 2, y: row.delete.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}
