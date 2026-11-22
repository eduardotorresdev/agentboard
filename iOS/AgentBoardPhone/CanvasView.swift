import AVKit
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
    @State private var dragging: (id: UUID, frame: CGRect)?
    @State private var opened: Card?
    @State private var adding: Adding?
    @State private var draft = ""

    enum Adding: Identifiable { case postIt, runner; var id: Self { self } }

    var body: some View {
        let cards = link.cards(in: worktree.path)
        let notes = link.postIts.filter { $0.worktree == worktree.path }
        let media = link.media.filter { $0.worktree == worktree.path }
        let others = Dictionary(notes.map { ($0.id, $0.frame) } + media.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        GeometryReader { geometry in
            let bounds = (cards.map(\.frame) + Array(others.values)).reduce(CGRect.null) { $0.union($1) }
            // Starts with the whole board in view.
            let fit = bounds.isNull ? 1 : min(1, geometry.size.width / (bounds.width + 80), geometry.size.height / (bounds.height + 80))
            let scale = zoom == 0 ? fit : zoom
            let origin = CGPoint(x: (bounds.isNull ? 0 : bounds.midX) * scale - geometry.size.width / 2 - offset.width,
                                 y: (bounds.isNull ? 0 : bounds.midY) * scale - geometry.size.height / 2 - offset.height)
            let place = { (rect: CGRect) in CGRect(x: rect.minX * scale - origin.x, y: rect.minY * scale - origin.y, width: rect.width * scale, height: rect.height * scale) }
            let frame = { (card: Card) in dragging?.id == card.id ? dragging!.frame : card.frame }
            let frameOf = { (id: UUID) -> CGRect? in cards.first { $0.id == id }.map(frame) ?? others[id] }

            ZStack(alignment: .topLeading) {
                Theme.sky.ignoresSafeArea()
                Path { path in
                    for line in link.lines {
                        guard let a = frameOf(line.a), let b = frameOf(line.b) else { continue }
                        let (from, to) = (place(a), place(b))
                        path.move(to: CGPoint(x: from.midX, y: from.midY))
                        path.addLine(to: CGPoint(x: to.midX, y: to.midY))
                    }
                }
                .stroke(Theme.accent, lineWidth: 2)
                ForEach(notes) { note in
                    let rect = place(note.frame)
                    PostItView(note: note, scale: scale).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }
                ForEach(media) { item in
                    let rect = place(item.frame)
                    MediaView(link: link, item: item).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }
                ForEach(cards) { card in
                    let rect = place(frame(card))
                    CardView(link: link, card: card, scale: scale, onDrag: { translation, ended in
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
                .onEnded { _ in zoomStart = nil })
            .overlay {
                if cards.isEmpty, others.isEmpty {
                    SkyBlobEmptyState()
                }
            }
        }
        .navigationTitle(worktree.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { card in TerminalPage(link: link, card: card) }
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

/// A post-it: its text on light paper. Read-only here.
struct PostItView: View {
    let note: PostIt
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.name).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
            Text(LocalizedStringKey(note.text)).font(Theme.Font.body).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 340, height: note.frame.height * 340 / max(1, note.frame.width), alignment: .topLeading)
        .scaleEffect(scale * note.frame.width / 340, anchor: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .clipped()
    }
}

/// A picture or a video, brought from the host when it first shows.
struct MediaView: View {
    let link: HostLink
    let item: Media

    var body: some View {
        ZStack {
            Theme.surfaceDeep
            if let data = link.files[item.file] {
                if item.isVideo {
                    VideoCard(data: data, name: item.file)
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                ProgressView()
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
    let scale: CGFloat
    let onDrag: (CGSize, Bool) -> Void

    var body: some View { content }

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
            .padding(.horizontal, 10).frame(height: 32)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { onDrag($0.translation, false) }
                .onEnded { onDrag($0.translation, true) })
            TerminalScreen(terminal: link.terminal(card.id), version: link.screens)
                .allowsHitTesting(false)
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
