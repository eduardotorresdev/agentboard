import AppKit
import Observation
import Orchestration
import SwiftUI

/// What a balloon on the canvas shows; the board keeps it current.
@Observable
final class DecisionBalloonModel {
    var decision: Decision
    var agentName = ""
    /// Other decisions the same agent has waiting behind this one.
    var more = 0
    /// The decision is gone: the balloon collapses into the terminal it points at.
    var leaving = false
    var height: CGFloat = 480
    /// Top left corner on the board, in world points.
    @ObservationIgnored var origin = CGPoint.zero
    @ObservationIgnored var onHeight: (() -> Void)?

    init(decision: Decision) {
        self.decision = decision
    }
}

enum DecisionMetrics {
    static let width: CGFloat = 640
    static let evidenceHeight: CGFloat = 360
    static let wedge = CGSize(width: 22, height: 20)
    static let wedgeTop: CGFloat = 10
    static let band: CGFloat = 40
    /// Between the wedge's tip and the card.
    static let gap: CGFloat = 6
    static let undoSeconds = 5
    static var outerWidth: CGFloat { width + wedge.width }
}

/// A decision on the canvas: evidence, then one ask, pointing at the terminal of the agent
/// that asked.
struct DecisionBalloon: View {
    let store: AgentStore
    let model: DecisionBalloonModel

    @State private var shown = false
    @State private var card = 0
    @State private var picked: Int?
    @State private var text = ""
    @State private var pending: Decision.Answer?
    @State private var secondsLeft = 0
    @FocusState private var typing: Bool

    private var decision: Decision { model.decision }
    private var variants: [Decision.Variant] { decision.ask.variants }
    private var isChoice: Bool { !variants.isEmpty }
    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var answered: Decision.Answer? { pending ?? decision.answer }
    /// The alternative a redirect is about: one is picked and there are words too.
    private var about: Decision.Variant? {
        guard !typed.isEmpty, let picked, picked < variants.count else { return nil }
        return variants[picked]
    }
    private var canSend: Bool { !isChoice || picked != nil || !typed.isEmpty }

    var body: some View {
        let tip = (DecisionMetrics.wedgeTop + DecisionMetrics.wedge.height / 2) / max(model.height, 1)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                band
                head
                evidence
                ask
            }
            .frame(width: DecisionMetrics.width)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dialog))
            Wedge().fill(Theme.deep)
                .frame(width: DecisionMetrics.wedge.width, height: DecisionMetrics.wedge.height)
                .padding(.top, DecisionMetrics.wedgeTop)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            model.height = height
            model.onHeight?()
        }
        .scaleEffect(shown && !model.leaving ? 1 : 0.02, anchor: UnitPoint(x: 1, y: tip))
        .opacity(shown && !model.leaving ? 1 : 0)
        .animation(.snappy, value: shown)
        .animation(.snappy, value: model.leaving)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { shown = true }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(action: key)
        .task(id: pending) { await countDown() }
        // Leaving the screen confirms; only Undo cancels.
        .onDisappear { if let pending, decision.answer == nil { store.send(.answerDecision(id: decision.id, answer: pending)) } }
    }

    // MARK: Header

    private var band: some View {
        HStack(spacing: 8) {
            Text(decision.family.capitalized)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.deep)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
            Text(URL(fileURLWithPath: decision.worktree).lastPathComponent)
                .font(Theme.Font.label)
                .foregroundStyle(Theme.onAccent)
                .lineLimit(1)
            Spacer()
            Text(model.more > 0 ? L("\(model.agentName) - \(model.more) more waiting") : model.agentName)
                .font(Theme.Font.label.weight(.regular))
                .foregroundStyle(Theme.accentTint)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: DecisionMetrics.band)
        .background(Theme.deep)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(decision.framing)
                .font(Theme.Font.headline)
                .tracking(Theme.Font.headlineTracking)
                .foregroundStyle(Theme.ink)
            Text(decision.blocking ? L("Blocking: the agent waits for your answer.")
                : L("Provisional: the agent continues with this version until you answer."))
                .font(Theme.Font.label.weight(.regular))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Evidence

    @ViewBuilder private var evidence: some View {
        let cards = decision.cards
        let current = cards[min(card, cards.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch current.evidence {
                case .image(let before, let after):
                    if let picture = picture(after) {
                        BeforeAfter(before: before.flatMap(picture(_:)), after: picture, pins: current.pins)
                    } else {
                        unavailable(L("This image is no longer on the board."))
                    }
                case .browser(let id), .video(let id):
                    unavailable(L("The evidence is the card “\(store.image(id)?.name ?? L("Browser"))”, connected to this agent."))
                }
            }
            .frame(width: DecisionMetrics.width, height: DecisionMetrics.evidenceHeight)
            .background(Theme.surfaceDeep)
            if !current.pins.isEmpty || current.reference != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(current.pins.enumerated()), id: \.offset) { index, pin in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            PinMark(number: index + 1)
                            Text(pin.question).font(Theme.Font.label.weight(.regular)).foregroundStyle(Theme.ink)
                        }
                    }
                    if let reference = current.reference {
                        Text(reference).font(Theme.Font.label.weight(.regular)).foregroundStyle(Theme.inkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Theme.surfaceDeep)
            }
            HStack(spacing: 8) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, each in
                    let on = index == min(card, cards.count - 1)
                    Button { withAnimation(.snappy) { card = index } } label: {
                        Text("\(index + 1) - \(each.claim)")
                            .font(Theme.Font.caption.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.deep : Theme.ink)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(on ? Theme.accentTint : Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    }
                    .buttonStyle(.plain)
                    .disabled(cards.count == 1)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center).padding(24)
    }

    private static let pictures = NSCache<NSString, NSImage>()

    private func picture(_ id: UUID) -> NSImage? {
        guard let record = store.image(id) else { return nil }
        if let cached = Self.pictures.object(forKey: record.file as NSString) { return cached }
        guard let image = NSImage(contentsOf: ImageFiles.url(of: record.file, in: store.dataFolder)) else { return nil }
        Self.pictures.setObject(image, forKey: record.file as NSString)
        return image
    }

    // MARK: Ask

    private var ask: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(decision.ask.question).font(Theme.Font.heading).foregroundStyle(Theme.ink)
            let chosen = chosenRow
            if isChoice, answered == nil || chosen != nil {
                VStack(spacing: 6) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                        row(index, key: "\(index + 1)", title: variant.title, detail: variant.detail, chosen: chosen)
                    }
                    row(variants.count, key: "U", title: L("Use Recommended"), detail: L("The agent picks now and tells you which."), chosen: chosen)
                }
            }
            if let answered {
                done(answered, namesAnswer: chosen == nil)
            } else {
                field
                Text(hint).font(Theme.Font.label.weight(.regular)).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .animation(.snappy, value: answered)
        .animation(.snappy, value: decision.echo)
    }

    /// The row the answer picked, once answered; a redirect picks none.
    private var chosenRow: Int? {
        switch answered {
        case .option(let letter): variants.firstIndex { $0.letter == letter }
        case .useRecommended: variants.count
        default: nil
        }
    }

    private func row(_ index: Int, key: String, title: String, detail: String?, chosen: Int?) -> some View {
        let on = (answered == nil ? picked : chosen) == index
        return Button { pick(index) } label: {
            HStack(alignment: .top, spacing: 8) {
                Keycap(key)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Font.label).foregroundStyle(on ? Theme.deep : Theme.ink)
                    if let detail {
                        Text(detail).font(Theme.Font.label.weight(.regular)).foregroundStyle(on ? Theme.deep : Theme.inkMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(on ? Theme.accentTint : Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answered != nil)
        .opacity(answered != nil && !on ? 0.45 : 1)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var field: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if !typing, typed.isEmpty { Keycap("R") }
                if let about {
                    Button { picked = nil } label: {
                        Text(L("About \(about.letter) ×"))
                            .font(Theme.Font.caption.weight(.semibold))
                            .foregroundStyle(Theme.deep)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                    }
                    .buttonStyle(.plain)
                    .help(L("Drop this from the redirect"))
                }
                TextField(L("Tell the agent what to change…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ink)
                    .focused($typing)
                    .onSubmit(send)
                    .accessibilityLabel(L("Redirect"))
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(typing ? Theme.accent : Theme.line.opacity(0.28), lineWidth: typing ? 2 : 1)
            }
            if canSend {
                Button(action: send) {
                    HStack(spacing: 8) {
                        Text(typed.isEmpty ? L("OK") : L("Redirect")).contentTransition(.interpolate)
                        Keycap("⏎")
                    }
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.leading, 12).padding(.trailing, 10)
                    .frame(height: 32)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: canSend)
        .animation(.snappy, value: typed.isEmpty)
    }

    private var hint: String {
        if !typed.isEmpty {
            return about.map { L("Redirect: sends your words about \($0.title); no alternative is picked.") }
                ?? L("Redirect: sends your words; the agent reworks this.")
        }
        guard isChoice else { return L("OK: keeps this version; the agent carries on.") }
        guard let picked else { return L("Pick an alternative, or tell the agent what to change.") }
        return picked == variants.count ? L("OK: the agent picks now and tells you which.")
            : L("OK: goes with \(variants[picked].title); the agent carries on.")
    }

    @ViewBuilder private func done(_ answer: Decision.Answer, namesAnswer: Bool) -> some View {
        HStack(spacing: 10) {
            if namesAnswer {
                Text(L("You answered: \(decision.title(of: answer))")).font(Theme.Font.heading).foregroundStyle(Theme.ink)
            }
            Spacer()
            if pending != nil, secondsLeft > 0 {
                HStack(spacing: 3) {
                    ForEach(0 ..< DecisionMetrics.undoSeconds, id: \.self) { second in
                        RoundedRectangle(cornerRadius: 2).fill(second < secondsLeft ? Theme.accent : Theme.surfaceDeep).frame(width: 14, height: 4)
                    }
                }
                Text(L("Sends in \(secondsLeft)s")).font(Theme.Font.label.weight(.regular)).foregroundStyle(Theme.inkMuted).monospacedDigit()
                Button { pending = nil } label: {
                    HStack(spacing: 6) {
                        Text(L("Undo"))
                        Keycap("⌘Z")
                    }
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
            } else if decision.echo == nil {
                Text(L("Sent")).font(Theme.Font.label.weight(.regular)).foregroundStyle(Theme.inkMuted)
            }
        }
        if let echo = decision.echo {
            Text("\(model.agentName) - \(echo)")
                .font(Theme.Font.label.weight(.regular))
                .foregroundStyle(Theme.deep)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .transition(.opacity)
        }
    }

    // MARK: Answering

    private func pick(_ index: Int) {
        guard isChoice, answered == nil, index <= variants.count else { return }
        picked = picked == index ? nil : index
    }

    /// Text wins: a redirect carries the picked alternative's letter and picks nothing.
    private func send() {
        guard canSend, answered == nil else { return }
        if !typed.isEmpty {
            pending = .redirect(about.map { "About \($0.title): \(typed)" } ?? typed)
        } else if !isChoice {
            pending = .ok
        } else if let picked {
            pending = picked == variants.count ? .useRecommended : .option(variants[picked].letter)
        }
        typing = false
        secondsLeft = DecisionMetrics.undoSeconds
    }

    /// The undo window, kept here only: the core hears the answer when it closes.
    private func countDown() async {
        guard let pending, decision.answer == nil else { return }
        while secondsLeft > 0 {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            secondsLeft -= 1
        }
        store.send(.answerDecision(id: decision.id, answer: pending))
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard answered == nil, !typing, press.modifiers.isEmpty else { return .ignored }
        switch press.characters.lowercased() {
        case "u": pick(variants.count)
        case "r": typing = true
        case "\r": send()
        case let digit:
            guard let number = Int(digit), number >= 1, number <= variants.count else { return .ignored }
            pick(number - 1)
        }
        return .handled
    }
}

/// The before and after of one screen behind a divider the user drags.
private struct BeforeAfter: View {
    let before: NSImage?
    let after: NSImage
    let pins: [Decision.Pin]
    /// Where the divider stands, 0 to 1 from the left: before on its left, after on its right.
    @State private var position: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let before {
                    fitted(before, in: size)
                        .mask(alignment: .leading) { Rectangle().frame(width: size.width * position) }
                    fitted(after, in: size)
                        .mask(alignment: .trailing) { Rectangle().frame(width: size.width * (1 - position)) }
                    Rectangle().fill(Theme.accent).frame(width: 2, height: size.height).offset(x: size.width * position - 1)
                    Image(systemName: "chevron.left.chevron.right")
                        .font(Theme.Font.caption.weight(.bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 28, height: 56)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .offset(x: size.width * position - 14, y: size.height - 64)
                    label(L("Before")).opacity(position < 0.14 ? 0 : 1).padding(8)
                    label(L("After")).opacity(position > 0.86 ? 0 : 1).padding(8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    fitted(after, in: size)
                }
                let shown = Self.fit(after.size, in: size)
                ForEach(Array(pins.enumerated()), id: \.offset) { index, pin in
                    PinMark(number: index + 1)
                        .position(x: shown.minX + shown.width * pin.x, y: shown.minY + shown.height * pin.y)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard before != nil else { return }
                position = min(1, max(0, drag.location.x / size.width))
            })
        }
        .clipped()
        .focusable(before != nil)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-0.02) }
        .onKeyPress(.rightArrow) { move(0.02) }
        .accessibilityElement()
        .accessibilityLabel(before == nil ? L("Evidence") : L("Before and after"))
        .accessibilityValue(before == nil ? "" : "\(Int(position * 100))%")
        .accessibilityAdjustableAction { direction in _ = move(direction == .increment ? 0.1 : -0.1) }
    }

    private func move(_ by: CGFloat) -> KeyPress.Result {
        guard before != nil else { return .ignored }
        withAnimation(.snappy) { position = min(1, max(0, position + by)) }
        return .handled
    }

    private func fitted(_ image: NSImage, in size: CGSize) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
    }

    /// Where a picture of `image` size lands when fitted in `size`.
    static func fit(_ image: CGSize, in size: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / image.width, size.height / image.height)
        let fitted = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

private struct PinMark: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(Theme.Font.caption.weight(.bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 20, height: 20)
            .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

private struct Keycap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
            .accessibilityHidden(true)
    }
}

/// The arrow at the balloon's side, pointing right at the agent's card.
private struct Wedge: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: rect.origin)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
