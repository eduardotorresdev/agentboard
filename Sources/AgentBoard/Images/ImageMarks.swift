import AgentRuntime
import AppKit
import Connections
import Orchestration
import SwiftUI

/// One annotation the user drew on a picture: an area and what should change there.
struct ImageMark: Identifiable, Equatable, Codable {
    var id = UUID()
    /// In the picture's own pixels, from its top left corner: what the agent gets.
    var area: CGRect
    var text = ""
    /// The marker's path, in the picture's pixels: only how it shows. Nil on marks from before the
    /// pen, which show as a back-and-forth over their area.
    var stroke: [CGPoint]?

    /// The path the marker paints with a nib `nib` pixels wide.
    func path(nib: CGFloat) -> [CGPoint] {
        if let stroke { return stroke }
        let inner = area.insetBy(dx: min(nib / 2, area.width / 2), dy: min(nib / 2, area.height / 2))
        let rows = max(1, Int((inner.height / (nib * 0.75)).rounded(.up)))
        return (0...rows).flatMap { row -> [CGPoint] in
            let y = inner.minY + inner.height * CGFloat(row) / CGFloat(rows)
            return row % 2 == 0 ? [CGPoint(x: inner.minX, y: y), CGPoint(x: inner.maxX, y: y)] : [CGPoint(x: inner.maxX, y: y), CGPoint(x: inner.minX, y: y)]
        }
    }
}

/// The annotations on one image card, until they are sent to an agent.
// shortcut: kept in this Mac's preferences, so they don't follow the board to another machine and an image
// removed while the app is closed leaves its entry behind; move them into the image record if that matters.
@MainActor
@Observable
final class ImageMarks {
    /// The picture they were drawn on; a replaced picture starts over.
    var file: String
    var marks: [ImageMark] = [] { didSet { if kept != oldValue.filter({ !$0.text.isEmpty }) { save() } } }
    /// Points from the picture's left edge to the window's right edge: where a balloon still fits.
    var room = CGFloat.infinity
    @ObservationIgnored private let key: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// The marker is on: dragging over the picture draws an area.
    var marking = false
    /// The mark whose balloon is open.
    var selected: UUID?
    /// The agent the user picked, over the recommended one.
    var agent: UUID?
    /// What the footer says for a moment after sending.
    var sent: String?
    var failure: String?
    var sending = false

    private struct Saved: Codable {
        var file: String
        var marks: [ImageMark]
    }

    /// With `image`, the annotations outlive the app: read back here, written as they change.
    init(file: String, image: UUID? = nil, defaults: UserDefaults = AppDefaults.shared) {
        self.file = file
        self.key = image.map(Self.key)
        self.defaults = defaults
        // A picture replaced since starts over.
        if let key, let saved = defaults.data(forKey: key).flatMap({ try? JSONDecoder().decode(Saved.self, from: $0) }), saved.file == file {
            marks = saved.marks
        }
    }

    private nonisolated static func key(_ image: UUID) -> String { "imageMarks." + image.uuidString }

    /// Only marks with a remark are worth keeping; none left (sent, deleted) clears the entry.
    private func save() {
        guard let key else { return }
        defaults.set(kept.isEmpty ? nil : try? JSONEncoder().encode(Saved(file: file, marks: kept)), forKey: key)
    }

    /// The image left the board.
    nonisolated static func forget(_ image: UUID, in defaults: UserDefaults = AppDefaults.shared) {
        defaults.removeObject(forKey: key(image))
    }

    /// Marks with a remark: the ones that count and get sent.
    var kept: [ImageMark] { marks.filter { !$0.text.isEmpty } }
    var footerOpen: Bool { !kept.isEmpty || sent != nil }

    /// Opens `id`'s balloon; a mark left without a remark goes.
    func select(_ id: UUID?) {
        marks.removeAll { $0.text.isEmpty && $0.id != id }
        selected = id
    }

    /// Esc: closes the open balloon, else puts the marker down. False when there was nothing to do.
    func escape() -> Bool {
        if selected != nil { select(nil) } else if marking { marking = false } else { return false }
        return true
    }

    // MARK: Who gets them

    /// The agent Send goes to unless the user picks another: one connected to the image (the one
    /// last sent to, when several), else the one last sent to, else the first on the board.
    nonisolated static func recommended(connected: [UUID], last: UUID?, all: [UUID]) -> UUID? {
        if let last, connected.contains(last) { return last }
        return connected.first ?? last.flatMap { all.contains($0) ? $0 : nil } ?? all.first
    }

    // MARK: What the agent gets

    nonisolated static func message(for marks: [ImageMark], on image: BoardMention, pixelSize: CGSize, marked file: String) -> String {
        let id = image.id.uuidString
        var text = "Annotations from the user on the image \(image.serialized): \(marks.count) \(marks.count == 1 ? "mark" : "marks") on a \(Int(pixelSize.width))×\(Int(pixelSize.height)) pixel picture.\n"
        text += "Each area is x, y, width, height in the picture's pixels, from the top left corner.\n"
        for (index, mark) in marks.enumerated() {
            let area = mark.area.integral
            let remark = mark.text.replacingOccurrences(of: "\n", with: "\n   ")
            text += "\n\(index + 1). Area \(Int(area.minX)), \(Int(area.minY)), \(Int(area.width)), \(Int(area.height))\n   \(remark)\n"
        }
        text += "\nSee the picture with the numbered marks drawn on it: image_read with image \"\(id)\" and marks \"\(file)\".\n"
        text += "See it without marks: image_read with image \"\(id)\"."
        return text
    }

    /// `image` (the picture, maybe decoded smaller than `pixelSize`) with the numbered areas drawn on it, as PNG.
    nonisolated static func render(_ image: CGImage, marks: [ImageMark], pixelSize: CGSize) -> Data? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / max(pixelSize.width, 1)
        // Numbers stay readable on a picture of any size.
        let unit = max(CGFloat(max(width, height)) / 90, 10)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, mark) in marks.enumerated() {
            let area = CGRect(x: mark.area.minX * scale, y: CGFloat(height) - mark.area.maxY * scale,
                              width: mark.area.width * scale, height: mark.area.height * scale)
            context.setFillColor(BoardPalette.rgb(BoardPalette.accent, 0.22))
            context.fill(area)
            context.setStrokeColor(BoardPalette.rgb(BoardPalette.accent))
            context.setLineWidth(max(2, unit / 5))
            context.stroke(area)
            let label = NSAttributedString(string: "\(index + 1)", attributes: [.font: NSFont.boldSystemFont(ofSize: unit * 1.5), .foregroundColor: NSColor.white])
            let size = label.size()
            // The tab hangs below the area, or sits inside it at the picture's bottom edge.
            let tab = CGRect(x: area.minX, y: max(0, area.minY - size.height - unit * 0.4), width: size.width + unit, height: size.height + unit * 0.4)
            context.setFillColor(BoardPalette.rgb(BoardPalette.accent))
            context.fill(tab)
            label.draw(at: CGPoint(x: tab.minX + unit / 2, y: tab.minY + unit * 0.2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }
}

/// Where the annotation chrome sits over an image card, in the overlay's own points: the
/// picture at the origin, the footer under it, room for a balloon to the right and below.
struct ImageMarksLayout {
    static let footerHeight: CGFloat = 66
    /// The footer with only the marker, before there is anything to send.
    static let barHeight: CGFloat = 38
    static let balloon = CGSize(width: 310, height: 146)
    static let gap: CGFloat = 10
    static let tab = CGSize(width: 24, height: 18)

    /// The picture's size on the card.
    let picture: CGSize
    let pixelSize: CGSize

    init(card: CGSize, pixelSize: CGSize) {
        picture = CGSize(width: card.width, height: max(0, card.height - ImageRecord.titleHeight))
        self.pixelSize = pixelSize
    }

    /// The overlay in the card's coordinates.
    var frame: CGRect {
        CGRect(x: 0, y: ImageRecord.titleHeight, width: picture.width + Self.gap + Self.balloon.width + 4,
               height: picture.height + Self.footerHeight + Self.balloon.height)
    }

    var scale: CGFloat { picture.width / max(pixelSize.width, 1) }
    /// The marker's nib, in overlay points: grows with the card, like the picture.
    var nib: CGFloat { max(8, picture.width * 0.025) }

    /// The area a marker path in overlay points covers, in picture pixels: the box around it and its nib.
    func area(ofStroke points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        let box = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        return area(of: box.insetBy(dx: -nib / 2, dy: -nib / 2))
    }
    /// Under the picture, in the card's frame: the marker alone, or with the marks and Send when `open`.
    func footer(open: Bool) -> CGRect {
        CGRect(x: 0, y: picture.height, width: picture.width, height: open ? Self.footerHeight : Self.barHeight)
    }

    func rect(of mark: ImageMark) -> CGRect {
        CGRect(x: mark.area.minX * scale, y: mark.area.minY * scale, width: mark.area.width * scale, height: mark.area.height * scale)
    }

    /// The area in picture pixels of a rectangle drawn in overlay points, kept inside the picture.
    func area(of rect: CGRect) -> CGRect {
        let inside = rect.standardized.intersection(CGRect(origin: .zero, size: picture))
        guard !inside.isNull else { return .zero }
        return CGRect(x: inside.minX / scale, y: inside.minY / scale, width: inside.width / scale, height: inside.height / scale)
    }

    func tab(of mark: ImageMark) -> CGRect {
        let rect = rect(of: mark)
        return CGRect(origin: CGPoint(x: rect.minX, y: rect.maxY), size: Self.tab)
    }

    /// Beside the mark: to its right, or to its left when the window ends before `room` points.
    func balloon(of mark: ImageMark, room: CGFloat = .infinity) -> CGRect {
        let rect = rect(of: mark)
        let right = rect.maxX + Self.gap
        let x = right + Self.balloon.width <= room ? right : max(0, rect.minX - Self.gap - Self.balloon.width)
        return CGRect(origin: CGPoint(x: x, y: min(max(0, rect.minY), frame.height - Self.balloon.height)), size: Self.balloon)
    }

    /// The mark a click at `point` lands on: the one drawn last, on top.
    func mark(at point: CGPoint, in marks: [ImageMark]) -> ImageMark? {
        marks.last { rect(of: $0).contains(point) }
    }

    /// Whether the annotation chrome takes a click at `point`; elsewhere it goes to the board.
    @MainActor func catches(_ point: CGPoint, _ state: ImageMarks) -> Bool {
        if footer(open: state.footerOpen).contains(point) { return true }
        if state.marking, CGRect(origin: .zero, size: picture).contains(point) { return true }
        for mark in state.marks {
            if rect(of: mark).contains(point) || tab(of: mark).contains(point) { return true }
            if mark.id == state.selected, balloon(of: mark, room: state.room).contains(point) { return true }
        }
        return false
    }
}

/// Hosts the annotation chrome over an image card and lets every click outside it through to the board.
final class ImageMarksHost: ZoomedView {
    let state: ImageMarks
    var layout: ImageMarksLayout

    init(state: ImageMarks, layout: ImageMarksLayout, content: some View) {
        self.state = state
        self.layout = layout
        super.init(content: content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard layout.catches(CGPoint(x: local.x / zoom, y: local.y / zoom), state) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: The chrome

private struct MarkButtonStyle: ButtonStyle {
    enum Kind { case plain, on, prominent }
    var kind = Kind.plain
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.label)
            .lineLimit(1)
            .foregroundStyle(kind == .prominent ? Theme.onAccent : kind == .on ? Theme.deep : Theme.ink)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(kind == .prominent ? Theme.accent : kind == .on ? Theme.accentTint : Theme.surface)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The marker, the marks, the balloon of the selected one and the footer that sends them.
struct ImageMarksView: View {
    let store: AgentStore
    let state: ImageMarks
    let id: UUID
    let addAgent: (any AgentProvider) -> Void
    /// The marker's path while it is being dragged, in overlay points.
    @State private var drawing: [CGPoint]?

    var body: some View {
        if let record = store.image(id) {
            let layout = ImageMarksLayout(card: record.frame.size, pixelSize: record.pixelSize)
            ZStack(alignment: .topLeading) {
                surface(layout)
                ForEach(Array(state.marks.enumerated()), id: \.element.id) { index, mark in
                    markView(mark, number: index + 1, layout)
                }
                if let drawing { drawn(drawing, layout) }
                footer(record, layout)
                if let index = state.marks.firstIndex(where: { $0.id == state.selected }) {
                    let mark = state.marks[index]
                    MarkBalloon(state: state, mark: mark, number: index + 1)
                        .frame(width: ImageMarksLayout.balloon.width, height: ImageMarksLayout.balloon.height)
                        .offset(x: layout.balloon(of: mark, room: state.room).minX, y: layout.balloon(of: mark, room: state.room).minY)
                        .id(mark.id)
                }
            }
            .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
            .coordinateSpace(name: "marks")
            .animation(.snappy, value: state.footerOpen)
            .animation(.snappy, value: state.selected)
        }
    }

    private func toggleMarker() {
        state.marking.toggle()
        if !state.marking { state.select(nil) }
    }

    /// The picture while the marker is on: a crosshair, and a drag draws an area.
    @ViewBuilder private func surface(_ layout: ImageMarksLayout) -> some View {
        if state.marking {
            Color.clear
                .contentShape(.rect)
                .frame(width: layout.picture.width, height: layout.picture.height)
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.crosshair.set() }
                }
                // From the first point, so a drag may start on a mark and a click without one selects it.
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("marks"))
                    .onChanged { drag in
                        guard drawing != nil || hypot(drag.translation.width, drag.translation.height) >= 3 else { return }
                        if drawing == nil { state.select(nil) }
                        let point = CGPoint(x: min(max(drag.location.x, 0), layout.picture.width), y: min(max(drag.location.y, 0), layout.picture.height))
                        drawing = (drawing ?? [drag.startLocation]) + [point]
                    }
                    .onEnded { drag in
                        defer { drawing = nil }
                        guard let drawing else { return state.select(layout.mark(at: drag.startLocation, in: state.marks)?.id) }
                        let area = layout.area(ofStroke: drawing)
                        // A slip of the hand is no area.
                        guard max(area.width, area.height) * layout.scale >= layout.nib + 8 else { return }
                        let mark = ImageMark(area: area, stroke: drawing.map { CGPoint(x: $0.x / layout.scale, y: $0.y / layout.scale) })
                        state.marks.append(mark)
                        state.select(mark.id)
                    })
        }
    }

    private func drawn(_ points: [CGPoint], _ layout: ImageMarksLayout) -> some View {
        let area = layout.area(ofStroke: points)
        let rect = layout.rect(of: ImageMark(area: area))
        return ZStack(alignment: .topLeading) {
            HighlighterStroke(points: points, nib: layout.nib, opacity: 0.45)
                .frame(width: layout.picture.width, height: layout.picture.height)
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: "\(Int(area.width)) x \(Int(area.height)) px")
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(Theme.onDeep)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                        .fixedSize()
                        .offset(y: 22)
                }
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func markView(_ mark: ImageMark, number: Int, _ layout: ImageMarksLayout) -> some View {
        let rect = layout.rect(of: mark)
        let selected = mark.id == state.selected
        HighlighterStroke(points: mark.path(nib: layout.nib / layout.scale).map { CGPoint(x: $0.x * layout.scale, y: $0.y * layout.scale) },
                          nib: layout.nib, opacity: selected ? 0.45 : 0.32)
            .frame(width: layout.picture.width, height: layout.picture.height)
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(.rect)
            .onTapGesture { state.select(mark.id) }
            // With the marker on the picture takes the click, so a new area can start here.
            .allowsHitTesting(!state.marking)
            .offset(x: rect.minX, y: rect.minY)
        Text(verbatim: "\(number)")
            .font(Theme.Font.label.monospacedDigit())
            .foregroundStyle(selected ? Theme.onDeep : Theme.onAccent)
            .frame(width: ImageMarksLayout.tab.width, height: ImageMarksLayout.tab.height)
            .background(selected ? Theme.deep : Theme.accent,
                        in: UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.thumb, bottomTrailingRadius: Theme.Radius.thumb))
            .onTapGesture { state.select(mark.id) }
            .offset(x: rect.minX, y: rect.maxY)
            .accessibilityLabel(L("Annotation \(number)"))
    }

    // MARK: Footer

    private func footer(_ record: ImageRecord, _ layout: ImageMarksLayout) -> some View {
        let agents = store.agents(in: record.worktree).filter { $0.runner == nil }
        let connected = store.connections.compactMap { $0.other(than: id) }.filter { peer in agents.contains { $0.id == peer } }
        let recommended = ImageMarks.recommended(connected: connected, last: store.lastMarkedAgent, all: agents.map(\.id))
        let target = agents.first { $0.id == state.agent } ?? agents.first { $0.id == recommended }
        let count = state.kept.count
        return VStack(alignment: .leading, spacing: 5) {
            if let sent = state.sent {
                Text(sent).font(Theme.Font.label).foregroundStyle(Theme.deep)
                Text(L("The annotations are gone from the picture. The agent has them.")).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            } else {
                HStack(spacing: 6) {
                    Button { toggleMarker() } label: { Label(L("Mark"), systemImage: "highlighter") }
                        .buttonStyle(MarkButtonStyle(kind: state.marking ? .on : .plain))
                        .help(L("Drag over the picture to mark an area and say what should change there."))
                    if !state.footerOpen {
                        Text(state.marking ? L("Drag over the picture to mark an area.") : L("Marks areas of the picture for an agent to change."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                            .truncationMode(.tail)
                    }
                    ForEach(Array(state.marks.enumerated()), id: \.element.id) { index, mark in
                        if !mark.text.isEmpty {
                            Button { state.select(mark.id) } label: { Text(verbatim: "\(index + 1)").monospacedDigit() }
                                .buttonStyle(MarkButtonStyle(kind: mark.id == state.selected ? .on : .plain))
                                .help(mark.text)
                        }
                    }
                    Spacer(minLength: 6)
                    if state.footerOpen, let target {
                        Menu {
                            ForEach(agents, id: \.id) { agent in
                                Button { state.agent = agent.id } label: {
                                    Text(agent.id == recommended ? L("\(agent.name) - Recommended") : agent.name)
                                    Text(connected.contains(agent.id) ? L("Connected to this image")
                                        : agent.id == agents.first?.id ? L("First agent on the board - sending connects it to this image")
                                        : L("Not connected - sending connects it to this image"))
                                }
                            }
                        } label: { Text(target.name) }
                        .menuStyle(.button)
                        .buttonStyle(MarkButtonStyle())
                        .fixedSize()
                    } else if state.footerOpen {
                        addAgentButton
                    }
                    if state.footerOpen {
                        Button(L("Send")) {
                            if let target { Task { await store.sendMarks(of: id, to: target.id) } }
                        }
                        .buttonStyle(MarkButtonStyle(kind: .prominent))
                        .disabled(target == nil || state.sending)
                    }
                }
                if state.footerOpen {
                    if let failure = state.failure {
                        Text(failure).font(Theme.Font.caption).foregroundStyle(Theme.danger)
                    } else if let target {
                        Text(count == 1 ? L("Send delivers it with the picture to \(target.name), then clears it.")
                            : L("Send delivers all \(count) with the picture to \(target.name), then clears them."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    } else {
                        Text(L("No agent on this board. Add agent creates one, then Send works.")).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(width: layout.picture.width, height: layout.footer(open: state.footerOpen).height, alignment: .leading)
        .background(Theme.surfaceDeep, in: UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.card, bottomTrailingRadius: Theme.Radius.card))
        .clipped()
        .offset(y: layout.picture.height)
    }

    @ViewBuilder private var addAgentButton: some View {
        if AgentCatalog.all.count == 1, let provider = AgentCatalog.all.first {
            Button(L("Add agent")) { addAgent(provider) }.buttonStyle(MarkButtonStyle())
        } else {
            Menu {
                ForEach(AgentCatalog.all, id: \.id) { provider in
                    Button { addAgent(provider) } label: {
                        Text(provider.title)
                        Text(provider.subtitle)
                    }
                }
            } label: { Text(L("Add agent")) }
            .menuStyle(.button)
            .buttonStyle(MarkButtonStyle())
            .fixedSize()
        }
    }
}

/// A marker's path painted like a text highlighter: a flat nib, translucent, one layer of ink
/// so where it crosses itself doesn't go darker.
struct HighlighterStroke: View {
    /// In the view's points.
    let points: [CGPoint]
    let nib: CGFloat
    var opacity: Double

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            path.addLines(points)
            context.opacity = opacity
            context.drawLayer { layer in
                layer.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: nib, lineCap: .butt, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The balloon beside a mark: its number and what should change there.
private struct MarkBalloon: View {
    let state: ImageMarks
    let mark: ImageMark
    let number: Int
    @State private var text = ""
    @FocusState private var typing: Bool

    private var kept: Bool { !mark.text.isEmpty }
    private var remark: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Annotation \(number)"))
                .font(Theme.Font.eyebrow)
                .foregroundStyle(Theme.onDeep)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(Theme.deep)
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("What should change here?"), text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(typing ? Theme.accent : Theme.line.opacity(0.18)))
                    .focused($typing)
                    .onSubmit(done)
                    .onExitCommand { state.select(nil) }
                HStack(spacing: 6) {
                    Button(L("Done"), action: done)
                        .buttonStyle(MarkButtonStyle(kind: .prominent))
                        .disabled(remark.isEmpty)
                    Button(kept ? L("Delete") : L("Cancel")) {
                        state.marks.removeAll { $0.id == mark.id }
                        state.select(nil)
                    }
                    .buttonStyle(MarkButtonStyle(kind: .on))
                }
                Text(kept ? L("Done keeps the remark. Delete removes this mark.") : L("Done keeps the remark. Cancel drops this mark."))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .shadow(color: Theme.window.opacity(Double(Theme.Shadow.opacity)), radius: Theme.Shadow.radius, y: Theme.Shadow.y)
        .onAppear {
            text = mark.text
            typing = true
        }
    }

    private func done() {
        guard !remark.isEmpty, let index = state.marks.firstIndex(where: { $0.id == mark.id }) else { return }
        state.marks[index].text = remark
        state.select(nil)
    }
}
