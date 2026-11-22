import SwiftUI
import TerminalCore
import UIKit

/// Draws a TerminalCore screen as text: one run per stretch of equal style.
/// shortcut: SwiftUI text, not the Mac's Metal renderer (TerminalRenderer doesn't build for iOS
/// yet); fine for one terminal on screen, swap for TerminalPresenter once it does.
struct TerminalScreen: View {
    let terminal: Terminal
    /// Changes whenever the terminal does.
    let version: Int

    var body: some View {
        GeometryReader { geometry in
            // Monospaced glyphs are ~0.6 em wide: the host's columns fit the width.
            let size = min(14, max(4, geometry.size.width / (CGFloat(terminal.cols) * 0.602)))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<terminal.rows, id: \.self) { row in
                    Text(Self.line(terminal, row: row)).lineLimit(1).fixedSize()
                }
            }
            .font(.system(size: size, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.surface)
        .id(version)
    }

    static func line(_ terminal: Terminal, row: Int) -> AttributedString {
        var line = AttributedString()
        let cursor = terminal.cursor
        for column in 0..<terminal.cols {
            let cell = terminal.cell(column: column, row: row)
            if cell.width == .tail { continue }
            var piece = AttributedString(terminal.text(of: cell) ?? " ")
            let attributes = cell.attributes
            var foreground = Self.color(cell.foreground, fallback: Theme.ink)
            var background = cell.background.isDefault ? nil : Self.color(cell.background, fallback: Theme.surface)
            if attributes.contains(.inverse) || (cursor.visible && cursor.row == row && cursor.column == column) {
                (foreground, background) = (background ?? Theme.surface, foreground)
            }
            piece.foregroundColor = attributes.contains(.dim) ? foreground.opacity(0.55) : foreground
            if let background { piece.backgroundColor = background }
            if attributes.contains(.bold) { piece.inlinePresentationIntent = .stronglyEmphasized }
            if attributes.contains(.underline) { piece.underlineStyle = .single }
            line += piece
        }
        return line
    }

    /// The terminal ANSI palette the Mac's light theme uses (an allowed exception to Theme).
    static let ansi: [UInt32] = [0x14233D, 0xCE2C31, 0x2F7D45, 0xA35F00, 0x3463C9, 0x8E4EC6, 0x107D98, 0x8B8799,
                                 0x6F6A80, 0xE5484D, 0x3E9B58, 0xC27C0E, 0x5B8DEF, 0xA66BD9, 0x2A9DB8, 0xC7C3D1]

    static func color(_ color: TerminalColor, fallback: Color) -> Color {
        switch color.kind {
        case .default: return fallback
        case .rgb(let r, let g, let b): return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .palette(let index):
            if index < 16 { return Theme.color(ansi[Int(index)]) }
            if index >= 232 { let level = Double(8 + Int(index - 232) * 10) / 255; return Color(.sRGB, red: level, green: level, blue: level) }
            let steps: [Double] = [0, 95, 135, 175, 215, 255]
            let i = Int(index) - 16
            return Color(.sRGB, red: steps[i / 36] / 255, green: steps[i / 6 % 6] / 255, blue: steps[i % 6] / 255)
        }
    }
}

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

    var body: some View {
        let terminal = link.terminal(card.id)
        VStack(spacing: 0) {
            TerminalScreen(terminal: terminal, version: link.screens)
                .padding(8)
                .contentShape(Rectangle())
                .onTapGesture { typing.toggle() }
                .background(KeyCatcher(active: $typing) { text in
                    let bytes = control ? ExtraKey.controlled(text) : text == "\n" ? terminal.encode(.enter) : Array(text.utf8)
                    control = false
                    link.type(bytes, to: card.id)
                } backspace: { link.type(terminal.encode(.backspace), to: card.id) })
            keys(terminal)
            composer
        }
        .background(Theme.canvas)
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func keys(_ terminal: Terminal) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ExtraKey.allCases) { key in
                    Button(key.rawValue) {
                        if let code = key.key { link.type(terminal.encode(code), to: card.id) } else { control.toggle() }
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
            } label: { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
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
