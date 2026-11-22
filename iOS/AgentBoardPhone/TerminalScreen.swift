import AgentRuntime
import SwiftUI
import TerminalCore
import UIKit

/// The keys a phone keyboard lacks, as the bytes the program asked for.
enum ExtraKey: String, CaseIterable, Identifiable {
    case escape = "Esc", tab = "Tab", control = "Ctrl", up = "↑", down = "↓", left = "←", right = "→"
    var id: String { rawValue }

    var key: TerminalKey? {
        switch self {
        case .escape: .escape
        case .tab: .tab
        case .control: nil
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }

    /// What typing `text` sends with Ctrl held: a letter becomes its control code.
    static func controlled(_ text: String) -> [UInt8] {
        text.utf8.map { byte in
            let upper = byte & 0xDF
            if upper >= 0x40, upper <= 0x5F { return upper - 0x40 }
            return byte == 0x20 ? 0 : byte
        }
    }
}

/// A full-screen agent terminal: the screen, the system keyboard straight into it, the keys it
/// lacks, and a composer that sends a whole prompt.
struct TerminalPage: View {
    let link: HostLink
    let card: Card
    @Environment(\.dismiss) private var dismiss
    @State private var control = false
    @State private var prompt = ""
    @State private var typing = false
    @State private var stopped = false

    var body: some View {
        VStack(spacing: 0) {
            MetalTerminal(session: link.session(card.id), showsCursor: true)
                .padding(12)  // the Mac card's inset
                .contentShape(Rectangle())
                .onTapGesture { typing.toggle() }
                .background(KeyCatcher(active: $typing) { text in
                    let bytes = control ? ExtraKey.controlled(text) : text == "\n" ? encode(.enter) : Array(text.utf8)
                    control = false
                    link.type(bytes, to: card.id)
                } backspace: { link.type(encode(.backspace), to: card.id) })
            keys
            composer
        }
        .background(Theme.canvas)
        .navigationTitle(card.name)
        .toolbar {
            if stopped {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start") { link.send(BoardSay.restart(card.id)) }
                        .accessibilityHint("Runs the agent's program again.")
                }
            }
        }
        // The session's state isn't observable; a glance each second is enough for one button.
        .onAppear { WaitingBanner.viewing = card.id }
        .onDisappear { if WaitingBanner.viewing == card.id { WaitingBanner.viewing = nil } }
        .task {
            link.open(card.id)
            while !Task.isCancelled {
                let now = ![.running, .starting].contains(link.session(card.id).state)
                if now != stopped { withAnimation(.smooth) { stopped = now } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        #if DEBUG
        // `-typeText <text>`: typed into the terminal once it showed (started first if stopped), then Enter.
        .task {
            guard let text = DebugLaunch.value("typeText"), !DebugOnce.typed else { return }
            DebugOnce.typed = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // An agent not running is started first, as tapping Start would.
            if ![.running, .starting].contains(link.session(card.id).state) {
                link.send(BoardSay.restart(card.id))
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
            // `-answerFirst YES`: Down, Enter first (a fresh test folder's trust question).
            if UserDefaults.standard.bool(forKey: "answerFirst") {
                link.type(encode(.down), to: card.id)
                try? await Task.sleep(nanoseconds: 500_000_000)
                link.type(encode(.enter), to: card.id)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
            // Enter apart: in one write with the text, an agent's prompt takes it as pasted.
            link.type(Array(text.utf8), to: card.id)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            link.type(encode(.enter), to: card.id)
            // `-leaveAfterTyping YES`: back to the board, so what the agent does next finds the user elsewhere.
            if UserDefaults.standard.bool(forKey: "leaveAfterTyping") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                dismiss()
            }
        }
        #endif
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What `key` sends, as the program asked for it (application cursor keys and so on).
    private func encode(_ key: TerminalKey) -> [UInt8] { link.session(card.id).withTerminal { $0.encode(key) } }

    private var keys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ExtraKey.allCases) { key in
                    Button(key.rawValue) {
                        if let code = key.key { link.type(encode(code), to: card.id) } else { control.toggle() }
                    }
                    .buttonStyle(SolidButton(fill: key == .control && control ? Theme.accent : Theme.surfaceDeep,
                                             text: key == .control && control ? Theme.onAccent : Theme.ink))
                    .accessibilityLabel(key == .control ? "Control" : key.rawValue)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Theme.surface)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message the agent", text: $prompt, axis: .vertical)
                .font(Theme.Font.body)
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 10)
            Button {
                link.send(BoardSay.prompt(card.id, prompt))
                prompt = ""
            } label: { Image(systemName: "arrow.up").font(Theme.Font.label) }
                .buttonStyle(.glassProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// An invisible first responder: the system keyboard, typing straight into the terminal.
struct KeyCatcher: UIViewRepresentable {
    @Binding var active: Bool
    let insert: (String) -> Void
    let backspace: () -> Void

    final class Field: UIView, UIKeyInput {
        var insert: (String) -> Void = { _ in }
        var backspace: () -> Void = {}
        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }
        func insertText(_ text: String) { insert(text) }
        func deleteBackward() { backspace() }
        var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
        var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
        var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
        var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    }

    func makeUIView(context: Context) -> Field { Field() }

    func updateUIView(_ field: Field, context: Context) {
        field.insert = insert
        field.backspace = backspace
        DispatchQueue.main.async {
            if active, !field.isFirstResponder { field.becomeFirstResponder() }
            if !active, field.isFirstResponder { field.resignFirstResponder() }
        }
    }
}
