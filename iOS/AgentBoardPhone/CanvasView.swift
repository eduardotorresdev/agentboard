import SwiftUI

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

    var body: some View {
        let cards = link.cards(in: worktree.path)
        GeometryReader { geometry in
            let bounds = cards.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            // Starts with the whole board in view.
            let fit = bounds.isNull ? 1 : min(1, geometry.size.width / (bounds.width + 80), geometry.size.height / (bounds.height + 80))
            let scale = zoom == 0 ? fit : zoom
            let origin = CGPoint(x: (bounds.isNull ? 0 : bounds.midX) * scale - geometry.size.width / 2 - offset.width,
                                 y: (bounds.isNull ? 0 : bounds.midY) * scale - geometry.size.height / 2 - offset.height)
            let place = { (rect: CGRect) in CGRect(x: rect.minX * scale - origin.x, y: rect.minY * scale - origin.y, width: rect.width * scale, height: rect.height * scale) }
            let frame = { (card: Card) in dragging?.id == card.id ? dragging!.frame : card.frame }

            ZStack(alignment: .topLeading) {
                Theme.sky.ignoresSafeArea()
                Path { path in
                    for line in link.lines {
                        guard let a = cards.first(where: { $0.id == line.a }), let b = cards.first(where: { $0.id == line.b }) else { continue }
                        let (from, to) = (place(frame(a)), place(frame(b)))
                        path.move(to: CGPoint(x: from.midX, y: from.midY))
                        path.addLine(to: CGPoint(x: to.midX, y: to.midY))
                    }
                }
                .stroke(Theme.accent, lineWidth: 2)
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
                if cards.isEmpty {
                    Text("No cards in this worktree yet.").font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .navigationTitle(worktree.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { card in TerminalPage(link: link, card: card) }
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
