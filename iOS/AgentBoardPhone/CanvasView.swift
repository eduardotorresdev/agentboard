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
/// the sky. Pan with one finger, pinch to zoom around the fingers, tap a card to open it. Hold a
/// card to lift it: it follows that finger while the other fingers keep panning and zooming.
struct CanvasView: View {
    let link: HostLink
    let worktree: Worktree
    @State private var offset: CGSize = .zero
    @State private var zoom: CGFloat = 0
    /// The zoom the cards' glyphs are drawn for: the last settled one.
    @State private var rasterZoom: CGFloat?
    @State private var dragging: (id: UUID, frame: CGRect)?
    /// The lifted card and where it was held, in board points from its corner.
    @State private var lifted: (id: UUID, grab: CGPoint)?
    @State private var opened: Card?
    @State private var watching: Element?
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
        let streamed = link.elements.filter { $0.worktree == worktree.path && $0.streams }
        let others = Dictionary(notes.map { ($0.id, $0.frame) } + media.map { ($0.id, $0.frame) } + streamed.map { ($0.id, $0.frame) },
                                uniquingKeysWith: { a, _ in a })
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
                    ForEach(streamed) { element in
                        let rect = place(element.frame)
                        ElementTile(element: element).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { watching = element }
                    }
                    ForEach(cards) { card in
                        let rect = place(frame(card))
                        CardView(link: link, card: card, live: visible.intersects(frame(card)), zoom: rasterZoom ?? scale,
                                 lifted: lifted?.id == card.id)
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
            .gesture(BoardTouches(
                lift: { point in
                    let at = CGPoint(x: (point.x + origin.x) / scale, y: (point.y + origin.y) / scale)
                    guard let card = cards.last(where: { $0.frame.contains(at) }) else { return false }
                    lifted = (card.id, CGPoint(x: at.x - card.frame.minX, y: at.y - card.frame.minY))
                    dragging = (card.id, card.frame)
                    return true
                },
                move: { previous, current, held in
                    // Read live: several touches arrive between renders, so the values captured
                    // by this body are already stale.
                    let scale = zoom == 0 ? fit : zoom
                    let origin = CGPoint(x: focus.midX * scale - geometry.size.width / 2 - offset.width,
                                         y: focus.midY * scale - geometry.size.height / 2 - offset.height)
                    // Zoom around the fingers' centroid and pan with it: the board point under the
                    // fingers stays under them.
                    var next = scale
                    if current.count >= 2 {
                        let spread = { (points: [CGPoint]) -> CGFloat in
                            let c = Self.centroid(points)
                            return points.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +)
                        }
                        let before = spread(previous)
                        if before > 1 { next = min(3, max(0.1, scale * spread(current) / before)) }
                    }
                    var newOrigin = origin
                    if !current.isEmpty {
                        let c0 = Self.centroid(previous), c1 = Self.centroid(current)
                        newOrigin = CGPoint(x: (c0.x + origin.x) / scale * next - c1.x, y: (c0.y + origin.y) / scale * next - c1.y)
                        zoom = next
                        offset = CGSize(width: focus.midX * next - geometry.size.width / 2 - newOrigin.x,
                                        height: focus.midY * next - geometry.size.height / 2 - newOrigin.y)
                    }
                    if let held, let lifted, var moved = cards.first(where: { $0.id == lifted.id })?.frame {
                        moved.origin = CGPoint(x: (held.x + newOrigin.x) / next - lifted.grab.x, y: (held.y + newOrigin.y) / next - lifted.grab.y)
                        dragging = (lifted.id, moved)
                    }
                },
                end: {
                    if let dragging { link.move(dragging.id, to: dragging.frame) }
                    dragging = nil
                    withAnimation(.spring) { lifted = nil }
                    // Glyphs are drawn again for the new size once the fingers lift, never during it.
                    if zoom != 0 { rasterZoom = zoom }
                }))
            .sensoryFeedback(.impact(weight: .medium), trigger: lifted?.id) { _, now in now != nil }
            .onAppear { if rasterZoom == nil { rasterZoom = scale } }
            .overlay {
                if cards.isEmpty, others.isEmpty {
                    SkyBlobEmptyState()
                }
            }
        }
        .navigationTitle(worktree.title)
        .onAppear { WaitingBanner.board = worktree }
        #if DEBUG
        // `-leaveAfterTyping YES`: the terminal closed after typing; leave the board too, so the
        // agent's decision finds the user on another screen.
        .onChange(of: opened) { before, now in
            if before != nil, now == nil, UserDefaults.standard.bool(forKey: "leaveAfterTyping"), !DebugOnce.left {
                DebugOnce.left = true
                // After the terminal's own pop has settled: a dismiss during it is dropped.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    DebugTerm.log("test: leaving the board")
                    NotificationCenter.default.post(name: DebugTerm.leaveBoard, object: nil)
                }
            }
        }
        #endif
        .onDisappear { if WaitingBanner.board == worktree { WaitingBanner.board = nil } }
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { card in TerminalPage(link: link, card: card) }
        .navigationDestination(item: $watching) { element in StreamPage(link: link, element: element) }
        #if DEBUG
        // `-perf YES` logs fps; `-zoom <scale>` sets the zoom; `-autoPan YES` pans back and forth
        // as a finger would, for measuring without touching the simulator.
        .task {
            DebugPerf.shared.start()
            // Once per launch: coming back from a card shows the board again, and must not
            // open it, or ask, a second time.
            guard !DebugOnce.canvas else { return }
            DebugOnce.canvas = true
            await debugTestBoard()
            // `-answerDecision <ok|letter>`: once an agent here opens a decision, answers it as its
            // balloon's button does (after `-answerDelay` seconds, 10 by default, for screenshots), then logs the agent's lines
            // that say ANSWER.
            if let answer = DebugLaunch.value("answerDecision") { Task { @MainActor [link, worktree] in
                var asked: Decision?
                for _ in 0..<600 where asked == nil {
                    asked = link.decisions.first { decision in link.cards(in: worktree.path).contains { $0.id == decision.agent } }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if let asked {
                    DebugTerm.log("decision: opened \"\(asked.ask.question)\"")
                    try? await Task.sleep(nanoseconds: UInt64(DebugLaunch.value("answerDelay").flatMap(Double.init) ?? 10) * 1_000_000_000)
                    link.send(BoardSay.answerDecision(asked.id, answer))
                    DebugTerm.log("decision: answered \(answer)")
                    for _ in 0..<120 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let lines = link.session(asked.agent).withTerminal { $0.screenText() }.filter { $0.contains("ANSWER") }
                        if lines.contains(where: { !$0.contains("<") }) { DebugTerm.log("decision: agent shows \(lines)"); break }
                    }
                } else {
                    DebugTerm.log("decision: none opened")
                }
            } }
            // `-openStream YES`: the first streamed card, full screen, once it is on the board.
            if UserDefaults.standard.bool(forKey: "openStream") {
                for _ in 0..<30 where watching == nil {
                    watching = link.elements.first { $0.worktree == worktree.path && $0.streams }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
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
/// What a DEBUG launch does only once, though its screen shows again.
@MainActor enum DebugOnce {
    static var left = false
    static var canvas = false
    static var typed = false
}

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
    let lifted: Bool

    var body: some View {
        #if DEBUG
        let _ = DebugPerf.count("card")
        #endif
        content
            .overlay {
                if lifted {
                    // Marching ants while the card is held. The phase stays within one dash period (8 + 6):
                    // Core Graphics walks the pattern up to it, and a clock-sized phase stalls every frame.
                    TimelineView(.animation) { timeline in
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6],
                                dashPhase: -CGFloat((timeline.date.timeIntervalSinceReferenceDate * 28).truncatingRemainder(dividingBy: 14))))
                    }
                }
            }
            .scaleEffect(lifted ? 1.2 : 1)
            .animation(.bouncy, value: lifted)
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
            } else if let asked = link.attention.first(where: { $0.id == card.id }), let questions = asked.questions, !questions.isEmpty {
                QuestionBalloon(link: link, agent: card.id, questions: questions).offset(y: -12).alignmentGuide(.top) { $0[.bottom] }
            }
        }
    }
}

/// The agent's question, with its quick answers; the rest waits on the Mac. Tapping it opens
/// the decision as a sheet at full size, for answering without zooming in.
struct DecisionBalloon: View {
    let link: HostLink
    let decision: Decision
    @State private var reading = false

    var body: some View {
        balloon
            .contentShape(Rectangle())
            .onTapGesture { reading = true }
            .sheet(isPresented: $reading) { DecisionSheet(link: link, decision: decision) }
            #if DEBUG
            // `-readDecision YES`: opens the sheet as a tap would, for screenshots.
            .task { if UserDefaults.standard.bool(forKey: "readDecision") { reading = true } }
            #endif
    }

    private var balloon: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(decision.ask.question).font(Theme.Font.heading).foregroundStyle(Theme.onAccent)
            if !decision.framing.isEmpty {
                Text(decision.framing).font(Theme.Font.caption).foregroundStyle(Theme.onAccent).lineLimit(3)
            }
            HStack(spacing: 6) {
                ForEach(decision.answers, id: \.value) { answer($0.value == "useRecommended" || $0.value == "ok" ? $0.title : $0.value, $0.value) }
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

/// An agent's questions, held by the core until they are answered: tapping opens them as a sheet.
struct QuestionBalloon: View {
    let link: HostLink
    let agent: UUID
    let questions: [AgentQuestion]
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(questions[0].question).font(Theme.Font.heading).foregroundStyle(Theme.onAccent)
            Text(questions.count == 1 ? "Tap to answer." : "And \(questions.count - 1) more. Tap to answer.")
                .font(Theme.Font.caption).foregroundStyle(Theme.onAccent)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { reading = true }
        .sheet(isPresented: $reading) { QuestionSheet(link: link, agent: agent, questions: questions) }
        #if DEBUG
        // `-readQuestions YES`: opens the sheet as a tap would; `-answerQuestions <label>` then
        // picks that option for every question and sends, after 8 s, for screenshots.
        .task { if UserDefaults.standard.bool(forKey: "readQuestions") || DebugLaunch.value("answerQuestions") != nil { reading = true } }
        #endif
    }
}

/// An agent's questions at reading size: each with its options as full-width buttons and a
/// field for an answer of one's own; Send answers them all, and the other button leaves them
/// to the agent's terminal.
struct QuestionSheet: View {
    let link: HostLink
    let agent: UUID
    let questions: [AgentQuestion]
    @State private var picked: [Int: Set<String>] = [:]
    @State private var written: [Int: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var answers: [String: String] {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            result[question.question] = question.answer(picked: picked[index] ?? [], written: written[index] ?? "")
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: 10) {
                        if let header = question.header {
                            Text(header.uppercased()).font(Theme.Font.eyebrow).foregroundStyle(Theme.inkMuted)
                        }
                        Text(question.question).font(Theme.Font.title).foregroundStyle(Theme.ink)
                        if question.multiSelect { Text("Pick any.").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted) }
                        ForEach(question.options, id: \.label) { option in
                            let on = picked[index, default: []].contains(option.label)
                            Button {
                                withAnimation(.snappy) {
                                    if question.multiSelect { picked[index, default: []].formSymmetricDifference([option.label]) } else { picked[index] = on ? [] : [option.label] }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    if let description = option.description { Text(description).font(Theme.Font.caption).opacity(0.85) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(SolidButton(fill: on ? Theme.accent : Theme.surfaceDeep, text: on ? Theme.onAccent : Theme.ink))
                            .accessibilityIdentifier("questionOption-\(option.label)")
                        }
                        TextField("Your own answer", text: Binding(get: { written[index] ?? "" }, set: { written[index] = $0 }))
                            .font(Theme.Font.body)
                            .padding(10)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).stroke(Theme.inkMuted.opacity(0.4)))
                    }
                }
                VStack(spacing: 10) {
                    Button { send(answers) } label: { Text("Send").frame(maxWidth: .infinity) }
                        .buttonStyle(SolidButton())
                        .disabled(answers.isEmpty)
                        .accessibilityIdentifier("questionsSend")
                    Button { send(nil) } label: { Text("Answer in its terminal").frame(maxWidth: .infinity) }
                        .buttonStyle(SolidButton(fill: Theme.surfaceDeep, text: Theme.ink))
                    Text("The agent asks again in its terminal, where you answer it.").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(20)
        }
        .background(Theme.surface)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(Theme.Radius.dialog)
        #if DEBUG
        .task {
            guard let label = DebugLaunch.value("answerQuestions") else { return }
            DebugTerm.log("questions: shown \(questions.map(\.question))")
            for (index, question) in questions.enumerated() where question.options.contains(where: { $0.label == label }) { picked[index] = [label] }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            DebugTerm.log("questions: answered \(answers)")
            send(answers)
        }
        #endif
    }

    private func send(_ answers: [String: String]?) {
        link.send(BoardSay.answerQuestions(agent, answers))
        withAnimation(.snappy) { dismiss() }
    }
}

/// A decision at reading size: what it is about, the question, and each answer as a full-width button.
struct DecisionSheet: View {
    let link: HostLink
    let decision: Decision
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            if !decision.framing.isEmpty {
                Text(decision.framing).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
            }
            ForEach(Array(decision.cards.enumerated()), id: \.offset) { index, card in
                DecisionCardView(link: link, number: index + 1, card: card)
            }
            Text(decision.ask.question).font(Theme.Font.title).foregroundStyle(Theme.ink)
            VStack(spacing: 10) {
                ForEach(decision.answers, id: \.value) { answer in
                    Button {
                        link.send(BoardSay.answerDecision(decision.id, answer.value))
                        withAnimation(.snappy) { dismiss() }
                    } label: {
                        Text(answer.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SolidButton(fill: answer.value == "useRecommended" ? Theme.surfaceDeep : Theme.accent,
                                             text: answer.value == "useRecommended" ? Theme.ink : Theme.onAccent))
                    .accessibilityIdentifier("decisionAnswer-\(answer.value)")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .presentationDetents(decision.cards.isEmpty ? [.medium] : [.large, .medium])
        .presentationCornerRadius(Theme.Radius.dialog)
    }
}

/// One card of a decision: its claim, its evidence at full width, and what it is compared against.
struct DecisionCardView: View {
    let link: HostLink
    let number: Int
    let card: Decision.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number). \(card.claim)").font(Theme.Font.heading).foregroundStyle(Theme.ink)
            Group {
                if let diagram = card.evidence.diagram {
                    if let before = diagram.before {
                        // A phone is narrow: before above after instead of a divider.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Before").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
                            DiagramPicture(svg: before)
                            Text("After").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
                            DiagramPicture(svg: diagram.svg)
                        }
                    } else {
                        DiagramPicture(svg: diagram.svg)
                    }
                } else if let picture = card.evidence.image, let item = link.media.first(where: { $0.id == picture.after }) {
                    ZStack {
                        Theme.surfaceDeep
                        if let data = link.files[item.file], let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .frame(height: 260)
                    .task { link.fetch(item.file) }
                } else {
                    Text("This evidence is shown on the Mac.").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .padding(12)
            .background(Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            if let reference = card.reference {
                Text(reference).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

/// A decision's diagram, drawn from its vector at the screen's pixel density.
struct DiagramPicture: View {
    let svg: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let diagram = try? SVGDiagram(svg) {
            GeometryReader { proxy in
                if let image = diagram.image(size: proxy.size, scale: displayScale) {
                    Image(uiImage: UIImage(cgImage: image, scale: displayScale, orientation: .up))
                }
            }
            .aspectRatio(diagram.viewBox.width / diagram.viewBox.height, contentMode: .fit)
            .accessibilityIdentifier("decisionDiagram")
        } else {
            Text("This diagram can't be drawn.").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
        }
    }
}

extension Decision {
    /// The answers it offers: OK for a validation; each variant, then Use Recommended, for a choice.
    var answers: [(title: String, value: String)] {
        ask.variants.isEmpty ? [("OK", "ok")]
            : ask.variants.map { ("\($0.letter). \($0.name)", $0.letter) } + [("Use Recommended", "useRecommended")]
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

extension CanvasView {
    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }
}

/// Every finger on the board, one by one: SwiftUI's drag and pinch can't tell a finger holding a
/// card from the ones navigating. `move` gets the navigating fingers before and after, and where
/// the holding finger is.
struct BoardTouches: UIGestureRecognizerRepresentable {
    let lift: (CGPoint) -> Bool
    let move: ([CGPoint], [CGPoint], CGPoint?) -> Void
    let end: () -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer { Recognizer() }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        recognizer.lift = lift; recognizer.move = move; recognizer.end = end
    }

    final class Recognizer: UIGestureRecognizer {
        var lift: (CGPoint) -> Bool = { _ in false }
        var move: ([CGPoint], [CGPoint], CGPoint?) -> Void = { _, _, _ in }
        var end: () -> Void = {}
        private var held: UITouch?
        private var start: CGPoint?
        private var timer: Timer?

        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = true
            delaysTouchesBegan = false
        }

        private var active: Set<UITouch> = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            active.formUnion(touches)
            if active.count == 1, held == nil, let touch = touches.first {
                start = touch.location(in: view)
                timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    guard let self, self.active.count == 1, self.active.first === touch, self.state == .possible,
                          self.lift(touch.location(in: self.view)) else { return }
                    self.held = touch
                    self.state = .began  // cancels the tap that would open the card
                }
            } else {
                timer?.invalidate()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible {
                guard let start, let touch = touches.first,
                      active.count > 1 || hypot(touch.location(in: view).x - start.x, touch.location(in: view).y - start.y) > 8 else { return }
                timer?.invalidate()
                state = .began
            } else {
                state = .changed
            }
            let navigating = active.filter { $0 !== held }
            move(navigating.map { $0.previousLocation(in: view) }, navigating.map { $0.location(in: view) }, held?.location(in: view))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lose(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lose(touches) }

        private func lose(_ touches: Set<UITouch>) {
            active.subtract(touches)
            // The holding finger let go: drop the card, the others keep navigating.
            if let held, touches.contains(held), !active.isEmpty { self.held = nil; end() }
            guard active.isEmpty else { return }
            timer?.invalidate()
            if state == .possible { state = .failed } else { end(); state = .ended }
        }

        override func reset() { active = []; held = nil; start = nil; timer?.invalidate() }
    }
}
