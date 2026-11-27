import AppKit
import Orchestration
import SwiftUI

/// Asks only for a new event source's name; its URL and secret show on its card, masked.
struct EventSourceDialog: View {
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        AppDialog(title: L("New event source")) {
            FormRow(label: L("Name"), message: L("Programs on this Mac post events to it; each event names a channel.")) {
                TextField("", text: $name, prompt: Text(L("Events")))
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Add event source")) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                onDone(trimmed.isEmpty ? L("Events") : trimmed)
                dismiss()
            }
            .buttonStyle(DialogButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Where an event source card's parts sit, in world points from the top of its content; the
/// board puts each channel's port beside its row.
enum EventSourceLayout {
    static let header: CGFloat = 46
    static let row: CGFloat = 30
    static let footer: CGFloat = 84

    /// How many channel rows fit in content `height`.
    static func rows(in height: CGFloat) -> Int { max(0, Int((height - header - footer - 6) / row)) }

    /// The middle of channel row `index`, from the top of the content.
    static func rowMiddle(_ index: Int) -> CGFloat { header + CGFloat(index) * row + row / 2 }
}

/// An event source card's content: status, today's count, channels and, on a darker footer, its
/// URL and secret, masked.
struct EventSourceView: View {
    let store: AgentStore
    let id: UUID
    @State private var showsHistory = false
    @State private var confirmingRegenerate = false

    var body: some View {
        if let source = store.eventSource(id) {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 0) {
                    header(source)
                        .frame(height: EventSourceLayout.header, alignment: .top)
                    channels(source, fitting: EventSourceLayout.rows(in: geometry.size.height))
                    Spacer(minLength: 0)
                    footer(source)
                        .frame(height: EventSourceLayout.footer)
                }
            }
            .font(Theme.Font.body)
            .foregroundStyle(Theme.ink)
        }
    }

    // MARK: Header

    private func header(_ source: EventSourceRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { showsHistory = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    status(source)
                    Text(L("\(source.eventsToday()) today"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L("The last \(EventSourceRecord.historyLimit) events: their channel, when they came and which agents got them."))
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) { EventHistoryView(source: source) }
            Menu {
                Button(L("Regenerate secret")) { withAnimation(.snappy) { confirmingRegenerate = true } }
                Button(L("Delete source"), role: .destructive) { store.removeEventSource(id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
                    .background(Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(L("Event source actions"))
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func status(_ source: EventSourceRecord) -> some View {
        if let error = source.lastError {
            Text(error)
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .help(error)
        } else if let last = source.lastEvent {
            Text(L("Active · last event \(last.formatted(.relative(presentation: .named)))"))
                .lineLimit(1)
        } else {
            Text(L("Waiting for the first event"))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    // MARK: Channels

    @ViewBuilder
    private func channels(_ source: EventSourceRecord, fitting count: Int) -> some View {
        if source.channels.isEmpty {
            Text(L("Channels show up with their first event. Draw a line from the source to an agent to wake it with every channel, or from one channel for only that one."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let shown = source.channels.prefix(count)
            ForEach(shown) { channel in
                HStack(spacing: 8) {
                    Text(channel.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(agentsLabel(channel))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
                .padding(.trailing, 6)
                .frame(height: EventSourceLayout.row)
            }
            if source.channels.count > shown.count {
                Text(L("\(source.channels.count - shown.count) more: make the card taller to see them"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    /// Who a channel's events reach (by its own lines or the source's), or that it only keeps history.
    private func agentsLabel(_ channel: EventChannel) -> String {
        let peers = Set(store.connections.compactMap { $0.other(than: channel.id) ?? $0.other(than: id) })
        let names = store.agents.filter { peers.contains($0.id) }.map(\.name)
        return names.isEmpty ? L("history only") : "→ " + names.joined(separator: ", ")
    }

    // MARK: Footer

    private func footer(_ source: EventSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if confirmingRegenerate {
                Text(L("Regenerate the secret? Programs using the old one get refused until they use the new one."))
                    .font(Theme.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button(L("Cancel")) { withAnimation(.snappy) { confirmingRegenerate = false } }
                        .buttonStyle(EventButtonStyle())
                    Button(L("Regenerate")) {
                        store.regenerateEventSecret(id)
                        withAnimation(.snappy) { confirmingRegenerate = false }
                    }
                    .buttonStyle(EventButtonStyle(prominent: true))
                }
            } else {
                MaskedField(label: L("URL"), value: source.url)
                MaskedField(label: L("Secret"), value: source.secret.isEmpty ? nil : source.secret)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// A value shown as dots: the eye reveals it for a few seconds, copy takes it without showing it.
private struct MaskedField: View {
    let label: String
    let value: String?
    static let revealFor: Duration = .seconds(5)
    @State private var revealed = false
    @State private var copied = false
    /// Bumped on each reveal and copy, so an earlier timer doesn't end a later one.
    @State private var revealToken = 0
    @State private var copyToken = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.Font.label)
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 48, alignment: .leading)
            Text(revealed ? value ?? "—" : "•••••••••••••")
                .font(Theme.Font.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(EventButtonStyle(icon: true))
                .accessibilityLabel(revealed ? L("Hide \(label)") : L("Show \(label)"))
                .help(revealed ? L("Hide it now.") : L("Shows it for 5 seconds."))
            Button { copy() } label: {
                if copied { Text(L("Copied")) } else { Image(systemName: "doc.on.doc") }
            }
            .buttonStyle(EventButtonStyle(icon: !copied))
            .accessibilityLabel(L("Copy \(label)"))
            .help(L("Copies it without showing it."))
        }
        .disabled(value == nil)
    }

    private func toggle() {
        revealToken += 1
        guard !revealed else { return withAnimation(.snappy) { revealed = false } }
        withAnimation(.snappy) { revealed = true }
        let token = revealToken
        Task {
            try? await Task.sleep(for: Self.revealFor)
            if token == revealToken { withAnimation(.snappy) { revealed = false } }
        }
    }

    private func copy() {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copyToken += 1
        let token = copyToken
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if token == copyToken { withAnimation(.snappy) { copied = false } }
        }
    }
}

/// The last events of a source.
private struct EventHistoryView: View {
    let source: EventSourceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Last events"))
                .font(Theme.Font.title)
            if source.history.isEmpty {
                Text(L("No events yet."))
                    .foregroundStyle(Theme.inkMuted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(source.history.enumerated()), id: \.offset) { _, entry in row(entry) }
                    }
                }
            }
        }
        .font(Theme.Font.body)
        .foregroundStyle(Theme.ink)
        .padding(16)
        .frame(width: 380, height: source.history.isEmpty ? nil : 420, alignment: .topLeading)
        .background(Theme.surface)
    }

    private func row(_ entry: EventLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.channel).font(Theme.Font.label)
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            if !entry.summary.isEmpty { Text(entry.summary).lineLimit(2) }
            Text(entry.deliveredTo.isEmpty ? L("History only") : L("To \(entry.deliveredTo.joined(separator: ", "))"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.inkMuted)
            if let error = entry.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
    }
}

/// The rule on a line from a channel to an agent: what it tells the agent, what the agent does,
/// when, and how often.
struct EventRuleEditor: View {
    let initial: EventRule
    let title: String
    let onSave: (EventRule) -> Void
    let onCancel: () -> Void
    @State private var rule = EventRule()
    @State private var windowed = false
    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var end = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.Font.title)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Instruction")).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                TextField("", text: $rule.instruction, prompt: Text(L("What the agent should do with these events")), axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Action")).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                HStack(spacing: 8) {
                    choice(.organize, L("Organize and note"), L("Sorts what came in and notes what matters."))
                    choice(.notify, L("Just notify"), L("Only tells you what came in."))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy) { windowed.toggle() } } label: { Text(L("Only between")) }
                    .buttonStyle(EventButtonStyle(on: windowed))
                    .help(L("Events outside these hours wait, and go in together when the window opens."))
                if windowed {
                    HStack {
                        DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                        Text(L("and"))
                        DatePicker("", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
            }
            Stepper(value: $rule.perHour, in: 1...600) {
                Text(L("At most \(rule.perHour) a hour"))
            }
            .help(L("Past it, the events wait and go in together as one."))
            HStack {
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .buttonStyle(EventButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { onSave(saved) }
                    .buttonStyle(EventButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(Theme.Font.body)
        .foregroundStyle(Theme.ink)
        .padding(16)
        .frame(width: 360)
        .background(Theme.surface)
        .onAppear {
            rule = initial
            if let windowStart = initial.windowStart, let windowEnd = initial.windowEnd {
                windowed = true
                start = Self.date(windowStart)
                end = Self.date(windowEnd)
            }
        }
    }

    private var saved: EventRule {
        var rule = rule
        rule.windowStart = windowed ? Self.minutes(start) : nil
        rule.windowEnd = windowed ? Self.minutes(end) : nil
        return rule
    }

    private func choice(_ action: EventRule.Action, _ title: String, _ detail: String) -> some View {
        Button { withAnimation(.snappy) { rule.action = action } } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.label)
                Text(detail).font(Theme.Font.caption).opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(EventButtonStyle(on: rule.action == action, card: true))
    }

    private static func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
}

/// Small solid controls on event source cards and their rule: filled with the accent when on.
private struct EventButtonStyle: ButtonStyle {
    var prominent = false
    var icon = false
    var on = false
    /// A large choice, its own text laid out inside.
    var card = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        return configuration.label
            .font(card ? nil : Theme.Font.label)
            .foregroundStyle(prominent || on ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, card || icon ? 0 : 10)
            .frame(width: icon ? 26 : nil, height: card ? nil : 24)
            .background(prominent || on ? Theme.accent : Theme.surface, in: shape)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
