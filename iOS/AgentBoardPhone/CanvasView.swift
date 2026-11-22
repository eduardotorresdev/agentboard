import AgentRuntime
import AVKit
import Connections
import SwiftUI

/// A video card: plays from a copy in the app's temporary folder.
struct VideoCard: View {
    let data: Data
    let name: String
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                if (try? data.write(to: url, options: .atomic)) != nil { player = AVPlayer(url: url) }
            }
    }
}

/// A worktree's board, as the Mac lays it out: cards at their frames, lines between them, on
/// the sky. Pan with one finger, pinch to zoom, drag a card by its header, tap it to open.
struct CanvasView: View {
    let link: HostLink
    let worktree: Worktree
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var zoom: CGFloat = 0
    @State private var zoomStart: CGFloat?
    /// The zoom the cards' glyphs are drawn for: the last settled one.
    @State private var rasterZoom: CGFloat?
    @State private var dragging: (id: UUID, frame: CGRect)?
    @State private var opened: Card?
    @State private var adding: Adding?
    @State private var draft = ""
    @State private var editing: PostIt?
    @State private var text = ""

    enum Adding: Identifiable { case postIt, runner; var id: Self { self } }

    var body: some View {
        #if DEBUG
        let _ = DebugPerf.count("canvas")
        #endif
        let cards = link.cards(in: worktree.path)
        let notes = link.postIts.filter { $0.worktree == worktree.path }
        let media = link.media.filter { $0.worktree == worktree.path }
        let others = Dictionary(notes.map { ($0.id, $0.frame) } + media.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        GeometryReader { geometry in
            let bounds = (cards.map(\.frame) + Array(others.values)).reduce(CGRect.null) { $0.union($1) }
            let board = bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds.insetBy(dx: -40, dy: -40)
            // Starts with every element in view, as the Mac frames a board.
            let focus = board
            let fit = min(1, geometry.size.width / focus.width, geometry.size.height / focus.height)
            let scale = zoom == 0 ? fit : zoom
            let origin = CGPoint(x: focus.midX * scale - geometry.size.width / 2 - offset.width,
                                 y: focus.midY * scale - geometry.size.height / 2 - offset.height)
            #if DEBUG
            // Each element's board frame and where it lands on screen, once per layout change.
            let _ = DebugLayout.log(scale: scale, origin: origin, [("card", cards.map { ($0.name, $0.frame) }), ("postit", notes.map { ($0.name, $0.frame) }), ("image", media.map { ($0.name, $0.frame) })])
            #endif
            // What the screen shows, in board points: only cards there draw live.
            let visible = CGRect(x: origin.x / scale, y: origin.y / scale, width: geometry.size.width / scale, height: geometry.size.height / scale)
            let frame = { (card: Card) in dragging?.id == card.id ? dragging!.frame : card.frame }
            let frameOf = { (id: UUID) -> CGRect? in cards.first { $0.id == id }.map(frame) ?? others[id] }
            let place = { (rect: CGRect) in rect.offsetBy(dx: -board.minX, dy: -board.minY) }

            ZStack(alignment: .topLeading) {
                Theme.sky
                // The board, laid out once in its own points; panning and zooming only move and
                // scale it as a whole.
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for line in link.lines {
                            guard let a = frameOf(line.a), let b = frameOf(line.b) else { continue }
                            let points = Ropes.points(line, place(a), place(b))
                            guard let first = points.first else { continue }
                            path.move(to: first)
                            points.dropFirst().forEach { path.addLine(to: $0) }
                        }
                    }
                    .stroke(Theme.accent, lineWidth: 2)  // board points: thickens with zoom, as on the Mac
                    ForEach(notes) { note in
                        let rect = place(note.frame)
                        PostItView(note: note).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { text = note.text; editing = note }
                    }
                    ForEach(media) { item in
                        let rect = place(item.frame)
                        MediaView(link: link, item: item).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    }
                    ForEach(cards) { card in
                        let rect = place(frame(card))
                        CardView(link: link, card: card, live: visible.intersects(frame(card)), zoom: rasterZoom ?? scale,
                                 onDrag: { translation, ended in
                            var moved = card.frame
                            moved.origin.x += translation.width / scale
                            moved.origin.y += translation.height / scale
                            if ended { link.move(card.id, to: moved); dragging = nil } else { dragging = (card.id, moved) }
                        })
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture { opened = card }
                    }
                }
                .frame(width: board.width, height: board.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: board.minX * scale - origin.x, y: board.minY * scale - origin.y)
            }
            .clipped()  // nothing of the board under the top bar
            .background(Theme.sky.ignoresSafeArea())
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { value in
                    let start = panStart ?? offset
                    panStart = start
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in panStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = zoomStart ?? scale
                    zoomStart = start
                    zoom = min(3, max(0.1, start * value.magnification))
                }
                // Glyphs are drawn again for the new size once the pinch ends, never during it.
                .onEnded { _ in zoomStart = nil; rasterZoom = zoom })
            .onAppear { if rasterZoom == nil { rasterZoom = scale } }
            .overlay {
                if cards.isEmpty, others.isEmpty {
                    SkyBlobEmptyState()
                }
            }
        }
        .navigationTitle(worktree.title)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { card in TerminalPage(link: link, card: card) }
        #if DEBUG
        // `-perf YES` logs fps; `-zoom <scale>` sets the zoom; `-autoPan YES` pans back and forth
        // as a finger would, for measuring without touching the simulator.
        .task {
            DebugPerf.shared.start()
            await debugTestBoard()
            if let value = DebugLaunch.value("zoom"), let scale = Double(value) { zoom = scale; rasterZoom = scale }
            guard UserDefaults.standard.bool(forKey: "autoPan") else { return }
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                offset = CGSize(width: sin(t * 1.5) * 220, height: cos(t * 1.1) * 160)
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        #endif
        .sheet(item: $editing) { note in
            NavigationStack {
                TextEditor(text: $text)
                    .font(Theme.Font.body).foregroundStyle(Theme.ink)
                    .padding(12)
                    .background(Theme.surface)
                    .navigationTitle(note.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                link.writePostIt(note.id, text)
                                editing = nil
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Agent") {
                        ForEach(AgentCatalog.all, id: \.id) { provider in
                            Button { link.addAgent(provider, to: worktree.path) } label: {
                                Text(provider.title)
                                Text(provider.subtitle.isEmpty ? "Starts a new conversation in this worktree." : provider.subtitle)
                            }
                        }
                    }
                    Button { draft = ""; adding = .runner } label: {
                        Text("Runner")
                        Text("Keeps a command running, like a dev server.")
                    }
                    Button { draft = ""; adding = .postIt } label: {
                        Text("Post-it")
                        Text("A note every connected agent can read.")
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add")
            }
        }
        .alert(adding == .runner ? "New runner" : "New post-it", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField(adding == .runner ? "Command, e.g. npm run dev" : "Text", text: $draft)
            Button("Add") {
                if adding == .runner { link.addRunner(draft, to: worktree.path) } else { link.addPostIt(draft, to: worktree.path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(adding == .runner ? "Runs in the worktree's folder. Leave empty for a shell." : "Shows on this worktree's board.")
        }
    }
}

#if DEBUG
extension CanvasView {
    /// A throwaway board on the host, only for worktrees named `phone-test-…`:
    /// `-testAgent YES` makes the folder a git repository if it isn't one, adds an agent card
    /// when there is none and opens it; `-removeTest YES` takes its cards off and deletes the folder.
    func debugTestBoard() async {
        let path = worktree.path
        guard (path as NSString).lastPathComponent.hasPrefix("phone-test-") else { return }
        let defaults = UserDefaults.standard
        guard ["testAgent", "testRunner", "testBoard", "prepareTest", "removeTest"].contains(where: defaults.bool(forKey:)) else { return }
        while link.phase != .connected { try? await Task.sleep(nanoseconds: 300_000_000) }
        // Read-only: which phone-test folders the host still has.
        let left = await link.run("sh", ["-c", "ls -d \"$HOME\"/agentboard/projects/phone-test-* 2>/dev/null; true"])
        DebugTerm.log("test: folders left: \(String(decoding: left?.output ?? Data(), as: UTF8.self).split(separator: "\n"))")
        if defaults.bool(forKey: "removeTest") {
            for card in link.cards(in: path) { link.send(BoardSay.removeCard(card.id)) }
            for note in link.postIts where note.worktree == path { link.send(BoardSay.json(["removePostIt": ["_0": note.id.uuidString]])) }
            for item in link.media where item.worktree == path { link.send(BoardSay.json(["removeImage": ["_0": item.id.uuidString]])) }
            _ = await link.run("rm", ["-rf", path])
            return
        }
        let setup = "[ -d \"$1/.git\" ] || { mkdir -p \"$1\" && cd \"$1\" && git init -q && git -c user.name=phone-test -c user.email=phone-test@localhost commit -q --allow-empty -m init; }"
        DebugTerm.log("test: setting up \(path)")
        let ran = await link.run("sh", ["-c", setup, "sh", path])
        DebugTerm.log("test: setup status \(ran?.status ?? -1), agents \(link.cards(in: path).count), provider \(AgentCatalog.all.first?.id ?? "none")")
        // `-prepareTest YES`: only the folder, for a UI test that adds the cards itself.
        if defaults.bool(forKey: "prepareTest") { return }
        // `-testBoard YES`: an agent, a post-it and a picture, left closed, to compare with the Mac.
        if defaults.bool(forKey: "testBoard") {
            if !link.cards(in: path).contains(where: { $0.runner == nil }), let provider = AgentCatalog.all.first { link.addAgent(provider, to: path) }
            if !link.postIts.contains(where: { $0.worktree == path }) { link.addPostIt("# Plan\n- one\n- two", to: path) }
            if !link.media.contains(where: { $0.worktree == path }) { await link.debugAddImage(to: path) }
            return
        }
        // `-testRunner YES`: a shell runner instead, for typing into a plain prompt.
        let runner = defaults.bool(forKey: "testRunner")
        let wanted = { (card: Card) in (card.runner != nil) == runner }
        if !link.cards(in: path).contains(where: wanted) {
            if runner { link.addRunner("", to: path) } else if let provider = AgentCatalog.all.first { link.addAgent(provider, to: path) }
        }
        for _ in 0..<100 {
            if let card = link.cards(in: path).first(where: wanted) { DebugTerm.log("test: opening \(card.id)"); opened = card; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
#endif

/// A post-it; tapping it edits its text.
struct PostItView: View {
    let note: PostIt

    /// As the Mac's post-it card: a translucent title bar, the text at board size on the card,
    /// cut off at its edges.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "note.text").foregroundStyle(Theme.inkMuted)
                Text(note.name).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.label)
            .padding(.horizontal, 12).frame(height: 34)
            .background(.ultraThinMaterial)
            Text(LocalizedStringKey(note.text)).font(Theme.Font.body).foregroundStyle(Theme.ink)
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A picture or a video, brought from the host when it first shows.
struct MediaView: View {
    let link: HostLink
    let item: Media

    /// As the Mac's image card: a translucent title bar over the sky, the picture filling the rest.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: item.isVideo ? "film" : "photo").foregroundStyle(Theme.inkMuted)
                Text(item.name).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.label)
            .padding(.horizontal, 12).frame(height: 32)
            .background(.ultraThinMaterial)
            ZStack {
                Theme.surfaceDeep
                if let data = link.files[item.file] {
                    if item.isVideo {
                        VideoCard(data: data, name: item.file)
                    } else if let image = Thumbnails.image(item.file, data: data, width: item.frame.width) {
                        // The card keeps the picture's proportions, so filling it doesn't crop.
                        Image(uiImage: image).resizable()
                    }
                }
                // Until it arrives the card stays a plain fill: a spinner per card would keep a
                // still board busy.
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .task { link.fetch(item.file) }
    }
}

extension Card: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A terminal card: a translucent header over the sky, the live screen under it, and the
/// agent's open decision in a balloon above.
struct CardView: View {
    let link: HostLink
    let card: Card
    let live: Bool
    let zoom: CGFloat
    let onDrag: (CGSize, Bool) -> Void

    var body: some View {
        #if DEBUG
        let _ = DebugPerf.count("card")
        #endif
        content
    }

    private var content: some View {
        let waiting = link.attention.contains { $0.id == card.id }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(card.name).font(Theme.Font.label).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
                if waiting {
                    Text("Needs you").font(Theme.Font.eyebrow).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { onDrag($0.translation, false) }
                .onEnded { onDrag($0.translation, true) })
            // As the Mac's card: the terminal inset 12 points on the card's surface.
            MetalTerminal(session: link.session(card.id), live: live, zoom: zoom)
                .allowsHitTesting(false)
                .padding([.horizontal, .bottom], 12)
                .background(Theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .top) {
            if let decision = link.decisions.first(where: { $0.agent == card.id }) {
                DecisionBalloon(link: link, decision: decision).offset(y: -12).alignmentGuide(.top) { $0[.bottom] }
            }
        }
    }
}

/// The agent's question, with its quick answers; the rest waits on the Mac.
struct DecisionBalloon: View {
    let link: HostLink
    let decision: Decision

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(decision.ask.question).font(Theme.Font.heading).foregroundStyle(Theme.onAccent)
            if !decision.framing.isEmpty {
                Text(decision.framing).font(Theme.Font.caption).foregroundStyle(Theme.onAccent).lineLimit(3)
            }
            HStack(spacing: 6) {
                if decision.ask.variants.isEmpty {
                    answer("OK", "ok")
                } else {
                    ForEach(decision.ask.variants, id: \.letter) { answer($0.letter, $0.letter) }
                    answer("Use Recommended", "useRecommended")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func answer(_ title: String, _ value: String) -> some View {
        Button(title) { link.send(BoardSay.answerDecision(decision.id, value)) }
            .buttonStyle(SolidButton(fill: Theme.surface, text: Theme.deep))
    }
}

/// Pictures decoded once, at the size their card shows them (2x its board width), not at
/// their full resolution on every redraw.
@MainActor enum Thumbnails {
    private static var cache: [String: UIImage] = [:]

    static func image(_ file: String, data: Data, width: CGFloat) -> UIImage? {
        if let image = cache[file] { return image }
        guard let full = UIImage(data: data) else { return nil }
        let target = min(1, width * 2 / max(full.size.width, 1))
        let image = full.preparingThumbnail(of: CGSize(width: full.size.width * target, height: full.size.height * target)) ?? full
        cache[file] = image
        return image
    }
}

/// Lines hang as the Mac's ropes between card handles, settled once per pair of frames.
@MainActor enum Ropes {
    private static var cache: [UUID: (CGRect, CGRect, [CGPoint])] = [:]

    static func points(_ line: Line, _ a: CGRect, _ b: CGRect) -> [CGPoint] {
        if let hit = cache[line.id], hit.0 == a, hit.1 == b { return hit.2 }
        let sides: (Side, Side) = if let x = line.aSide, let y = line.bSide { (x, y) } else {
            // The closest pair of handles, as the Mac picks for a line drawn without them.
            Side.allCases.flatMap { x in Side.allCases.map { (x, $0) } }
                .min { distance(handle(a, $0.0), handle(b, $0.1)) < distance(handle(a, $1.0), handle(b, $1.1)) }!
        }
        let points = Rope.resting(from: RopeAnchor(point: handle(a, sides.0), side: sides.0),
                                  to: RopeAnchor(point: handle(b, sides.1), side: sides.1)).points
        cache[line.id] = (a, b, points)
        return points
    }

    /// Mirrors the Mac's `CardMetrics.handles`: the middle of each side.
    static func handle(_ frame: CGRect, _ side: Side) -> CGPoint {
        switch side {
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        }
    }

    private static func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }
}

#if DEBUG
@MainActor enum DebugLayout {
    private static var last = ""

    static func log(scale: CGFloat, origin: CGPoint, _ groups: [(String, [(String, CGRect)])]) {
        // Off while measuring: building these strings every frame would be the cost measured.
        guard !UserDefaults.standard.bool(forKey: "perf") else { return }
        let lines = groups.flatMap { kind, items in items.map { name, f in
            let screen = CGRect(x: f.minX * scale - origin.x, y: f.minY * scale - origin.y, width: f.width * scale, height: f.height * scale)
            return "\(kind) \(name) board=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)) screen=\(Int(screen.minX)),\(Int(screen.minY)),\(Int(screen.width)),\(Int(screen.height))"
        } }
        let text = "layout scale=\(String(format: "%.3f", scale))\n" + lines.joined(separator: "\n")
        guard text != last else { return }
        last = text
        DebugTerm.log(text)
    }
}
#endif
