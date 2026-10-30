import AgentRuntime
import Orchestration
import SwiftUI

/// The count of agents waiting on the developer, centered in the toolbar. Opens the deck.
struct NeedsYouButton: View {
    let agents: AgentStore
    @Binding var isOpen: Bool
    @State private var isHovered = false

    private var count: Int { agents.attention.count { agents.record($0.id) != nil } }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) { isOpen.toggle() }
        } label: {
            if count == 0 && !isOpen {
                // Quiet while nothing waits.
                Text(L("All clear"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.line.opacity(0.4))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            } else {
            HStack(spacing: 8) {
                Text(L("Needs you"))
                    .font(.system(size: 13, weight: .semibold))
                Text(count, format: .number)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(count > 0 ? .white : Theme.line.opacity(0.08), in: .capsule)
                    .foregroundStyle(count > 0 ? Theme.accent : Theme.line.opacity(0.5))
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(height: 30)
            .foregroundStyle(count > 0 ? .white : Theme.line.opacity(0.55))
            .background(count > 0 ? Theme.accent.opacity(isHovered ? 0.88 : 1) : Theme.line.opacity(isHovered ? 0.07 : 0.04),
                        in: .capsule)
            .contentShape(.capsule)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(count == 0 && !isOpen)
        .keyboardShortcut("j", modifiers: .command)
        .help(L("Agents waiting on you, across every organization"))
        .animation(.bouncy(duration: 0.4), value: count == 0)
        .animation(.snappy(duration: 0.3), value: count)
        .animation(.snappy(duration: 0.2), value: isHovered)
    }
}

/// The agents waiting on the developer as a stack of cards. The top one shows its agent's live
/// terminal to answer in; dragging it aside marks it done and brings up the next.
struct NeedsYouDeck: View {
    let agents: AgentStore
    let projects: ProjectStore
    @Binding var isOpen: Bool
    /// Where each card was dragged, kept while it flies off.
    @State private var drags: [UUID: CGSize] = [:]
    /// Cards flying off: out of the queue already, gone from the store once they land.
    @State private var leaving: Set<UUID> = []
    /// Whether the top card takes the keyboard. Off when the card above left on its own (its
    /// agent was answered and went back to work): typing still aimed at that agent must not
    /// land in the next one, maybe on a permission prompt. A click on the terminal turns it on.
    @State private var focusFollows = true
    @State private var leftByUser: Set<UUID> = []
    /// What had the keyboard before the deck opened, to give it back on close.
    @State private var previousResponder: NSResponder?
    /// The hint shows until the first card is dragged away.
    @AppStorage("needsYou.hasSwiped") private var hasSwiped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Past this, or thrown past twice this, a released card leaves.
    private static let threshold: CGFloat = 150
    private static let behind = 3

    private var queue: [AttentionRequest] {
        agents.attention.filter { agents.record($0.id) != nil && !leaving.contains($0.id) }
    }

    var body: some View {
        GeometryReader { proxy in
            // Small windows give the card more of themselves, so the terminal stays readable.
            let inset: CGFloat = proxy.size.height < 640 ? 40 : 96
            let size = CGSize(width: min(880, proxy.size.width - inset), height: min(600, proxy.size.height - inset))
            ZStack {
                Theme.line.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture(perform: close)
                ZStack {
                    // One list, so a card keeps its identity (and its terminal) as it flies off.
                    let flying = agents.attention.filter { leaving.contains($0.id) }
                    let cards = flying.map { ($0, 0, true) } + queue.prefix(Self.behind).enumerated().map { ($1, $0, false) }
                    ForEach(cards.reversed(), id: \.0.id) { request, depth, isLeaving in
                        if let record = agents.record(request.id) {
                            card(request, record, depth: depth, size: size, isLeaving: isLeaving)
                                .zIndex(isLeaving ? 1 : Double(-depth))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: close)
        .onChange(of: queue.isEmpty) { _, empty in if empty { close() } }
        .onAppear { previousResponder = NSApp.keyWindow?.firstResponder }
        .onChange(of: queue.first?.id) { old, _ in
            guard let old else { return }
            focusFollows = leftByUser.remove(old) != nil || leaving.contains(old)
        }
        // Every way of closing: Esc, a click outside, the toolbar button, ⌘J.
        .onDisappear {
            if let previousResponder, let window = NSApp.keyWindow,
               (previousResponder as? NSView)?.window.map({ $0 === window }) ?? true {
                DispatchQueue.main.async { window.makeFirstResponder(previousResponder) }
            }
        }
    }

    @ViewBuilder
    private func card(_ request: AttentionRequest, _ record: AgentRecord, depth: Int, size: CGSize, isLeaving: Bool = false) -> some View {
        let drag = drags[request.id] ?? .zero
        let isTop = depth == 0 && !isLeaving
        let progress = isLeaving ? 1 : isTop ? min(abs(drag.width) / Self.threshold, 1) : 0
        NeedsYouCard(agents: agents, request: request, record: record, place: place(of: record), isActive: isTop,
                     isLive: isTop || isLeaving,
                     position: L("\(queue.count) waiting"), showsHint: !hasSwiped, progress: progress,
                     takesFocus: isTop && focusFollows, onDone: { leave(request.id, direction: 1) }, onEscape: close)
            .frame(width: size.width, height: size.height)
            .scaleEffect(1 - CGFloat(depth) * 0.04)
            .offset(x: drag.width, y: drag.height * 0.4 + CGFloat(depth) * 14)
            .rotationEffect(.degrees(depth == 0 ? (reduceMotion ? 0 : Double(drag.width / 24)) : Self.tilt(depth, request.id)))
            .opacity(isLeaving && reduceMotion ? 0 : 1)
            .allowsHitTesting(isTop)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
            .simultaneousGesture(isTop ? swipe(request.id) : nil)
            .animation(.snappy(duration: 0.4), value: depth)
    }

    /// The cards behind lean a little each way, the same way every time for the same agent.
    private static func tilt(_ depth: Int, _ id: UUID) -> Double {
        let side: Double = id.uuid.0 % 2 == 0 ? 1 : -1
        return side * (depth.isMultiple(of: 2) ? -1 : 1) * (1 + Double(depth) * 0.75)
    }

    private func swipe(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let before = abs(drags[id]?.width ?? 0) > Self.threshold
                drags[id] = value.translation
                if before != (abs(value.translation.width) > Self.threshold) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { value in
                let distance = value.translation.width, thrown = value.predictedEndTranslation.width
                if abs(distance) > Self.threshold || abs(thrown) > Self.threshold * 2 {
                    hasSwiped = true
                    leave(id, direction: (abs(distance) > Self.threshold ? distance : thrown) < 0 ? -1 : 1)
                } else {
                    withAnimation(.bouncy(duration: 0.4)) { drags[id] = .zero }
                }
            }
    }

    /// Flies the card off toward `direction`, then takes it out of the queue.
    private func leave(_ id: UUID, direction: CGFloat) {
        guard !leaving.contains(id) else { return }
        leftByUser.insert(id)
        let current = drags[id] ?? .zero
        // The next card rises while this one leaves.
        withAnimation(.snappy(duration: 0.4)) { _ = leaving.insert(id) }
        withAnimation(.snappy(duration: 0.32)) {
            drags[id] = CGSize(width: direction * (reduceMotion ? 80 : 1400), height: current.height)
        } completion: {
            leaving.remove(id)
            drags[id] = nil
            agents.dismissAttention(id)
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.3)) { isOpen = false }
    }

    /// Where the agent works: its organization (when there are several) and worktree folder.
    private func place(of record: AgentRecord) -> String {
        let folder = URL(fileURLWithPath: record.worktree).lastPathComponent
        guard projects.organizations.count > 1,
              let organization = projects.organizations.first(where: { $0.id == record.organization }) else { return folder }
        return "\(organization.name) · \(folder)"
    }
}

private struct NeedsYouCard: View {
    let agents: AgentStore
    let request: AttentionRequest
    let record: AgentRecord
    let place: String
    /// The top card: its terminal is live and its shortcuts work.
    let isActive: Bool
    /// Shows the live terminal: the active card, and the one flying off.
    let isLive: Bool
    let position: String
    let showsHint: Bool
    /// How far the card is dragged toward leaving, 0 to 1.
    let progress: CGFloat
    let takesFocus: Bool
    let onDone: () -> Void
    let onEscape: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Group {
                if isLive {
                    LiveTerminal(store: agents, record: record, onEscape: onEscape, takesFocus: takesFocus)
                } else {
                    Color.white
                }
            }
            .padding(.horizontal, 12)
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .background(Theme.surface, in: .rect(cornerRadius: 18))
        .overlay(alignment: .top) {
            // Says what letting go does, once the drag is most of the way there.
            Label(L("Done"), systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.accent, in: .capsule)
                .padding(.top, -14)
                .opacity(Double(max(0, (progress - 0.6) / 0.4)))
                .scaleEffect(progress >= 1 ? 1.06 : 1)
                .animation(.snappy(duration: 0.2), value: progress >= 1)
        }
        .shadow(color: Theme.line.opacity(isLive ? 0.18 : 0.10), radius: isLive ? 30 : 16, y: isLive ? 14 : 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.line)
                    Text(place)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.line.opacity(0.55))
                        .lineLimit(1)
                }
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.line.opacity(0.78))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { context in
                Text(Self.age.localizedString(for: request.since, relativeTo: max(context.date, request.since)))
            }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.line.opacity(0.5))
        }
    }

    private var footer: some View {
        HStack {
            Text(position)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.line.opacity(0.5))
            Spacer()
            if showsHint {
                Text(L("Drag aside when you're done"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.line.opacity(0.5))
            }
            if isActive {
                Button(L("Done"), action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(L("Marks this one as handled and shows the next. ⌥Esc sends Esc to the agent."))
            }
        }
        .frame(minHeight: 22)
    }

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var message: String {
        switch request.reason {
        case .turnEnded: L("Finished its turn. Your move.")
        case .waiting: L("Waiting for you.")
        case .said(let text): text
        }
    }
}
