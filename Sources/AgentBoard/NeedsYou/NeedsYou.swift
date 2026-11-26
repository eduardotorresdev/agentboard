import AgentRuntime
import Orchestration
import SwiftUI

/// One card of the Needs You queue: an agent waiting in its terminal, or an agent's decisions.
enum NeedsYouItem: Identifiable {
    case attention(AttentionRequest)
    case decisions(agent: UUID, blocking: Bool)

    /// An agent can have both at once: a prompt in its terminal and decisions on the board.
    struct ID: Hashable {
        let agent: UUID
        let isDecision: Bool
    }

    var agent: UUID {
        switch self {
        case .attention(let request): request.id
        case .decisions(let agent, _): agent
        }
    }

    var id: ID {
        if case .decisions = self { return ID(agent: agent, isDecision: true) }
        return ID(agent: agent, isDecision: false)
    }
}

extension NeedsYouItem {
    /// What waits on the developer: agents with a blocking decision first (they are stopped),
    /// then agents waiting in their terminal, oldest first, then agents with provisional
    /// decisions (they carry on meanwhile). An agent that only ended its turn while its
    /// decisions wait shows as its decisions alone.
    @MainActor static func queue(stores: [AgentStore], attention: [AttentionRequest]) -> [NeedsYouItem] {
        var blocking: [NeedsYouItem] = [], provisional: [NeedsYouItem] = []
        var asking = Set<UUID>()
        for store in stores {
            for decision in store.decisions where !asking.contains(decision.agent) {
                guard store.record(decision.agent) != nil, store.decisionSequence(of: decision.agent)?.isWaiting == true else { continue }
                asking.insert(decision.agent)
                let blocks = store.decisions.contains { $0.agent == decision.agent && $0.blocking && $0.state == .open && $0.answer == nil }
                if blocks { blocking.append(.decisions(agent: decision.agent, blocking: true)) }
                else { provisional.append(.decisions(agent: decision.agent, blocking: false)) }
            }
        }
        let waiting = attention.filter { request in
            guard stores.contains(where: { $0.record(request.id) != nil }) else { return false }
            if asking.contains(request.id), case .turnEnded = request.reason, (request.questions ?? []).isEmpty { return false }
            return true
        }
        return blocking + waiting.map(NeedsYouItem.attention) + provisional
    }
}

extension HostStores {
    var needsYou: [NeedsYouItem] { NeedsYouItem.queue(stores: connected, attention: attention) }
}

/// The count of agents waiting on the developer, centered in the toolbar. Opens the deck.
struct NeedsYouButton: View {
    let hosts: HostStores
    let projects: ProjectStore
    @Binding var isOpen: Bool
    @State private var isHovered = false

    private var waiting: [AgentRecord] { hosts.needsYou.compactMap { hosts.store(of: $0.agent)?.record($0.agent) } }
    private var count: Int { hosts.needsYou.count }

    /// How many projects have an agent waiting; a worktree outside every project counts as its own.
    private var projectCount: Int {
        Set(waiting.map { record in
            projects.projects.first { project in
                project.path == record.worktree || projects.worktrees[project.id]?.contains { $0.path == record.worktree } == true
            }?.path ?? record.worktree
        }).count
    }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) { isOpen.toggle() }
        } label: {
            if count == 0 && !isOpen {
                // Quiet while nothing waits.
                Label(L("All clear"), systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
            } else {
            HStack(spacing: 6) {
                Label(L("Needs you"), systemImage: "bell.fill")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.trailing, 4)
                // Open, the badge closes the screen; the cards show how many wait.
                if isOpen {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .heavy))
                        .modifier(Tally(isLit: count > 0))
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    tally("folder.fill", projectCount, L("Projects with an agent waiting"))
                    tally("sparkles", count, L("Agents waiting"))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 32)
            .foregroundStyle(count > 0 ? Theme.onYou : Theme.inkMuted)
            // Amber: the "waiting for you" color.
            .background(count > 0 ? Theme.you.opacity(isHovered ? 0.88 : 1) : Theme.line.opacity(isHovered ? 0.07 : 0.04),
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect(cornerRadius: Theme.Radius.control))
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.bouncy(duration: 0.4), value: isOpen)
        .keyboardShortcut("j", modifiers: .command)
        .help(isOpen ? L("Back to the board (Esc)") : L("Agents waiting on you, across every organization"))
        .animation(.bouncy(duration: 0.4), value: count == 0)
        .animation(.snappy(duration: 0.3), value: count)
        .animation(.snappy(duration: 0.3), value: projectCount)
        .animation(.snappy(duration: 0.2), value: isHovered)
    }

    /// An icon and how many of it wait.
    private func tally(_ symbol: String, _ value: Int, _ meaning: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(value, format: .number)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
        }
        .modifier(Tally(isLit: count > 0))
        .transition(.scale(scale: 0.5).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meaning): \(value)")
    }

    /// A dark block on the button's amber fill.
    private struct Tally: ViewModifier {
        let isLit: Bool

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 22)
                .foregroundStyle(isLit ? Theme.you : Theme.inkMuted)
                .background(isLit ? Theme.onYou : Theme.line.opacity(0.08), in: .rect(cornerRadius: Theme.Radius.thumb))
        }
    }
}

/// The agents waiting on the developer, as a screen of its own: a canvas with a faint grid (no
/// sidebar) with a stack of cards. The top one says where the agent works and what it asks, over
/// its live terminal to answer in; dragging it aside marks it done and brings up the next.
struct NeedsYouDeck: View {
    /// The agents wait on this Mac and on the account's hosts: each request is its host's store's.
    let hosts: HostStores
    let projects: ProjectStore
    @Binding var isOpen: Bool
    /// Opens the agent's worktree on the board, focused on its card.
    let onReveal: (AgentRecord) -> Void
    /// Where each card was dragged, kept while it flies off.
    @State private var drags: [NeedsYouItem.ID: CGSize] = [:]
    /// Cards flying off: out of the queue already, gone from the store once they land.
    @State private var leaving: Set<NeedsYouItem.ID> = []
    /// Decisions put aside for later: they go to the end of the queue while this screen is open.
    @State private var later: [NeedsYouItem.ID] = []
    /// Whether the top card takes the keyboard. Off when the card above left on its own (its
    /// agent was answered and went back to work): typing still aimed at that agent must not
    /// land in the next one, maybe on a permission prompt. A click on the terminal turns it on.
    @State private var focusFollows = true
    @State private var leftByUser: Set<NeedsYouItem.ID> = []
    /// What had the keyboard before the deck opened, to give it back on close.
    @State private var previousResponder: NSResponder?
    /// The hint shows until the first card is dragged away.
    @AppStorage("needsYou.hasSwiped", store: AppDefaults.shared) private var hasSwiped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far opening has come: 1 once the board is blurred away, 2 once the cards are in.
    @State private var stage = 0

    /// Past this, or thrown past twice this, a released card leaves.
    private static let threshold: CGFloat = 150
    private static let behind = 3

    private var queue: [NeedsYouItem] {
        let waiting = hosts.needsYou.filter { !leaving.contains($0.id) }
        return waiting.filter { !later.contains($0.id) } + later.compactMap { id in waiting.first { $0.id == id } }
    }

    var body: some View {
        GeometryReader { proxy in
            // Small windows give the card more of themselves, so the terminal stays readable.
            let inset: CGFloat = proxy.size.height < 640 ? 40 : 96
            let size = CGSize(width: proxy.size.width - inset, height: min(820, proxy.size.height - inset))
            ZStack {
                // A blurred surface over the board, its pulses running underneath.
                Rectangle().fill(.ultraThinMaterial)
                    .opacity(stage >= 1 ? 1 : 0)
                .contentShape(.rect)
                ZStack {
                    // One list, so a card keeps its identity (and its terminal) as it flies off.
                    let flying = hosts.needsYou.filter { leaving.contains($0.id) }
                    let cards = flying.map { ($0, 0, true) } + queue.prefix(Self.behind).enumerated().map { ($1, $0, false) }
                    ForEach(cards.reversed(), id: \.0.id) { item, depth, isLeaving in
                        if let agents = hosts.store(of: item.agent), let record = agents.record(item.agent) {
                            card(item, record, in: agents, depth: depth, size: size, isLeaving: isLeaving)
                                .zIndex(isLeaving ? 1 : Double(-depth))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                if queue.isEmpty && leaving.isEmpty {
                    emptyCard(size: size)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            // The cards come in once the board has blurred.
            .opacity(stage >= 2 ? 1 : 0)
            .scaleEffect(stage >= 2 ? 1 : 0.97)
            .animation(.snappy(duration: 0.4), value: queue.isEmpty && leaving.isEmpty)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: close)
        .onAppear {
            previousResponder = NSApp.keyWindow?.firstResponder
            withAnimation(.smooth(duration: 0.45)) { stage = 1 }
            withAnimation(.smooth(duration: 0.5).delay(0.2)) { stage = 2 }
        }
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

    /// Where the next card will land: an outline of one, with nothing waiting in it.
    private func emptyCard(size: CGSize) -> some View {
        EmptyCanvas(symbol: "checkmark.circle", title: L("Nobody is waiting on you"),
                    message: L("An agent shows up here when it finishes its turn or asks you something.")) { EmptyView() }
            .frame(width: min(size.width, size.height * 0.72), height: size.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.dialog).fill(Theme.surface.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.dialog)
                .strokeBorder(Theme.line.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
    }

    @ViewBuilder
    private func card(_ item: NeedsYouItem, _ record: AgentRecord, in agents: AgentStore, depth: Int, size: CGSize, isLeaving: Bool = false) -> some View {
        let drag = drags[item.id] ?? .zero
        let isTop = depth == 0 && !isLeaving
        let progress = isLeaving ? 1 : isTop ? min(abs(drag.width) / Self.threshold, 1) : 0
        let position = L("\(queue.count) waiting")
        let reveal = {
            if case .attention = item { agents.dismissAttention(item.agent) }
            close()
            onReveal(record)
        }
        Group {
            switch item {
            case .attention(let request):
                NeedsYouCard(agents: agents, request: request, record: record, place: projects.place(ofPath: record.worktree),
                             organization: organization(of: record), size: size, isActive: isTop,
                             isLive: isTop || isLeaving,
                             position: position, showsHint: !hasSwiped, progress: progress,
                             takesFocus: isTop && focusFollows, onDone: { leave(item.id, direction: 1) },
                             onAnswer: { answers in leave(item.id, direction: 1) { agents.answerQuestions(request.id, answers) } },
                             onTerminal: { agents.answerQuestions(request.id, nil) }, onEscape: close, onReveal: reveal)
                    .frame(width: Self.width(of: record, in: size))
            case .decisions:
                if let sequence = agents.decisionSequence(of: item.agent) {
                    NeedsYouDecisions(agents: agents, record: record, sequence: sequence, place: projects.place(ofPath: record.worktree),
                                      isActive: isTop, position: position, onLater: { leave(item.id, direction: 1) }, onReveal: reveal)
                        .frame(width: min(size.width, DecisionMetrics.width))
                }
            }
        }
            .frame(maxHeight: size.height)
            .scaleEffect(1 - CGFloat(depth) * 0.04)
            .offset(x: drag.width, y: drag.height * 0.4 + CGFloat(depth) * 14)
            .rotationEffect(.degrees(depth == 0 ? (reduceMotion ? 0 : Double(drag.width / 24)) : Self.tilt(depth, item.agent)))
            .opacity(isLeaving ? 0 : 1)
            .allowsHitTesting(isTop)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
            .simultaneousGesture(isTop ? swipe(item.id) : nil)
            .animation(.snappy(duration: 0.4), value: depth)
    }

    /// Narrow like a playing card, but wide enough to show the agent's terminal whole.
    private static func width(of record: AgentRecord, in size: CGSize) -> CGFloat {
        min(size.width, max(size.height * 0.72, CardMetrics.terminal(of: record).width + 24))
    }

    /// The cards behind lean a little each way, the same way every time for the same agent.
    private static func tilt(_ depth: Int, _ id: UUID) -> Double {
        let side: Double = id.uuid.0 % 2 == 0 ? 1 : -1
        return side * (depth.isMultiple(of: 2) ? -1 : 1) * (1 + Double(depth) * 0.75)
    }

    private func swipe(_ id: NeedsYouItem.ID) -> some Gesture {
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

    /// Slides the card a little toward `direction` as it fades, then takes it out of the queue.
    /// `then` runs as it lands, before the request leaves the queue (answering questions).
    private func leave(_ id: NeedsYouItem.ID, direction: CGFloat, then: (() -> Void)? = nil) {
        guard !leaving.contains(id) else { return }
        leftByUser.insert(id)
        let current = drags[id] ?? .zero
        // The next card rises while this one leaves.
        withAnimation(.snappy(duration: 0.4)) { _ = leaving.insert(id) }
        withAnimation(.snappy(duration: 0.32)) {
            drags[id] = CGSize(width: direction * (reduceMotion ? 40 : 220), height: current.height)
        } completion: {
            leaving.remove(id)
            drags[id] = nil
            then?()
            if id.isDecision {
                // Decisions leave when answered; put aside, they come back after the rest.
                later.removeAll { $0 == id }
                later.append(id)
            } else {
                hosts.store(of: id.agent)?.dismissAttention(id.agent)
            }
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.3)) { isOpen = false }
    }

    /// The agent's organization, named only when there are several.
    private func organization(of record: AgentRecord) -> String? {
        projects.organizations.count > 1 ? projects.organizations.first { $0.id == record.organization }?.name : nil
    }
}

/// An agent's decisions in the queue: the canvas balloon itself, walking through its questions.
private struct NeedsYouDecisions: View {
    let agents: AgentStore
    let record: AgentRecord
    let sequence: AgentStore.DecisionSequence
    let place: ProjectStore.Place
    let isActive: Bool
    let position: String
    let onLater: () -> Void
    let onReveal: () -> Void
    @State private var model: DecisionBalloonModel

    init(agents: AgentStore, record: AgentRecord, sequence: AgentStore.DecisionSequence, place: ProjectStore.Place,
         isActive: Bool, position: String, onLater: @escaping () -> Void, onReveal: @escaping () -> Void) {
        self.agents = agents
        self.record = record
        self.sequence = sequence
        self.place = place
        self.isActive = isActive
        self.position = position
        self.onLater = onLater
        self.onReveal = onReveal
        let model = DecisionBalloonModel(decision: sequence.shown)
        model.pointsAtCard = false
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                DecisionBalloon(store: agents, model: model)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack {
                Text(position)
                    .font(Theme.Font.label.weight(.regular).monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                if isActive {
                    Button(action: onReveal) {
                        Label(L("Go to Agent"), systemImage: "arrow.up.right").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                    .help(L("Opens its worktree with its card in focus; the decision stays on the card."))
                    Button(action: onLater) {
                        Label(L("Later"), systemImage: "arrow.turn.down.right").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                    .help(L("Keeps the decision open and shows it again after the others."))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.dialog))
        .clipShape(.rect(cornerRadius: Theme.Radius.dialog))
        .onChange(of: sequence, initial: true) {
            model.decision = sequence.shown
            model.position = sequence.position
            model.total = sequence.total
            model.agentName = record.name
            model.place = place
        }
    }
}

private struct NeedsYouCard: View {
    let agents: AgentStore
    let request: AttentionRequest
    let record: AgentRecord
    let place: ProjectStore.Place
    /// Named only when there are several.
    let organization: String?
    let size: CGSize
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
    let onAnswer: ([String: String]) -> Void
    let onTerminal: () -> Void
    let onEscape: () -> Void
    let onReveal: () -> Void

    /// Questions to answer on the card, which then needs no terminal.
    private var questions: [AgentQuestion]? { request.questions.flatMap { $0.isEmpty ? nil : $0 } }

    /// An agent that only finished its turn says so in its terminal: the card shows that alone.
    private var showsContext: Bool { request.context != nil && !(request.reason == .turnEnded && questions == nil) }

    /// Alone, the terminal takes the card; next to the context, enough lines to answer in.
    private var terminalHeight: CGFloat {
        showsContext ? min(320, max(180, size.height * 0.42)) : max(180, size.height - 190)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
            if showsContext {
                context
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }
            if let questions {
                QuestionForm(questions: questions, maxHeight: max(160, size.height - (request.context == nil ? 190 : 330)),
                             isActive: isActive, onSend: onAnswer, onTerminal: onTerminal)
                    .padding(.horizontal, 24)
                    .id(request.since)
            } else {
                Group {
                    if isLive {
                        LiveTerminal(store: agents, record: record, onEscape: onEscape, takesFocus: takesFocus)
                    } else {
                        Theme.surface
                    }
                }
                .frame(height: terminalHeight)
                .padding(.horizontal, 12)
            }
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.dialog))
        .overlay(alignment: .top) {
            // Says what letting go does, once the drag is most of the way there.
            Label(L("Done"), systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.accent, in: .rect(cornerRadius: Theme.Radius.control))
                .padding(.top, -14)
                .opacity(Double(max(0, (progress - 0.6) / 0.4)))
                .scaleEffect(progress >= 1 ? 1.06 : 1)
                .animation(.snappy(duration: 0.2), value: progress >= 1)
        }
        .shadow(color: Theme.window.opacity(Double(Theme.Shadow.opacity) * 3), radius: Theme.Shadow.radius, y: Theme.Shadow.y)
    }

    /// Where the agent works leads: the project, then the worktree. The agent's name and its
    /// organization (when there are several) come after, smaller.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                PlaceTitle(place: place)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.line)
                Label(L("Agent: \([record.name, organization].compactMap { $0 }.joined(separator: " - "))"), systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.line.opacity(0.5))
                    .padding(.top, 3)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                    .padding(.top, 6)
                if let orchestrators = request.orchestrators {
                    // Its orchestrator can't give this one: it waits on the developer directly.
                    Label(L("Via \(orchestrators.joined(separator: ", "))"), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.deep)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { context in
                Text(Self.age.localizedString(for: request.since, relativeTo: max(context.date, request.since)))
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.line.opacity(0.5))
        }
    }

    /// What the agent asks: its last words, its question, or the command it wants to run.
    @ViewBuilder
    private var context: some View {
        if let text = request.context {
            let body = Text(Self.markdown(text))
                .font(.system(size: 13))
                .foregroundStyle(Theme.line.opacity(0.85))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            // Short context sits as it is; long context scrolls in what the terminal leaves.
            ViewThatFits(in: .vertical) {
                body
                ScrollView { body }
            }
            .frame(maxHeight: questions == nil ? max(80, size.height - terminalHeight - 190) : 140)
            .background(Theme.canvas, in: .rect(cornerRadius: Theme.Radius.dialog))
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
                Button(action: onReveal) {
                    Label(L("Go to Agent"), systemImage: "arrow.up.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                    .help(L("Opens its worktree with its card in focus, and takes it off this list."))
            }
            if isActive && questions == nil {
                Button(action: onDone) {
                    Label(L("Done"), systemImage: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 120)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(L("Marks this one as handled and shows the next. ⌥Esc sends Esc to the agent."))
            }
        }
        .frame(minHeight: 36)
    }

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var message: String {
        if let questions { return questions.count == 1 ? L("Asks you a question") : L("Asks you \(questions.count) questions") }
        return switch request.reason {
        case .turnEnded: L("Finished its turn. Your move.")
        case .waiting: L("Waiting for you.")
        case .said(let text): text
        }
    }
}
