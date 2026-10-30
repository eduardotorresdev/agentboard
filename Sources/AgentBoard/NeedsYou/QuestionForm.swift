import Orchestration
import SwiftUI

/// The questions an agent asked (AskUserQuestion), to answer on the card one at a time: one
/// option to pick, or several to check, and always a field for an answer of the developer's own.
/// Picking the one option of a question moves on to the next. Sending gives the agent the
/// answers keyed by question text, as Claude Code expects them.
struct QuestionForm: View {
    let questions: [AgentQuestion]
    /// Room for the question; past it it scrolls.
    let maxHeight: CGFloat
    let isActive: Bool
    let onSend: ([String: String]) -> Void
    /// Leaves the questions to the agent's terminal.
    let onTerminal: () -> Void

    /// The question shown.
    @State private var step = 0
    /// Which way the last step went, for the transition.
    @State private var forward = true
    /// Per question: the labels picked, oldest first.
    @State private var picks: [Int: [String]] = [:]
    /// Per question: the answer written in.
    @State private var written: [Int: String] = [:]
    /// Per single-choice question: the written answer is the one picked.
    @State private var writes: Set<Int> = []
    @FocusState private var focusedField: Int?

    private var isLast: Bool { step >= questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if questions.count > 1 { progress }
            ZStack(alignment: .topLeading) {
                ViewThatFits(in: .vertical) {
                    current
                    ScrollView { current }
                }
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxHeight: maxHeight, alignment: .top)
            .clipped()
            HStack(spacing: 10) {
                if step > 0 {
                    Button(L("Back")) { go(to: step - 1) }
                        .controlSize(.small)
                        .help(L("Shows the previous question, to change its answer."))
                }
                Spacer()
                Button(L("Answer in terminal"), action: onTerminal)
                    .controlSize(.small)
                    .help(L("Shows these questions in the agent's terminal, to answer there."))
                if isLast {
                    Button(L("Send answers")) { onSend(answers) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isComplete || !isActive)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(L("Gives the agent your answers; it carries on with them."))
                } else {
                    Button(L("Next")) { go(to: step + 1) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isAnswered(step))
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(L("Keeps this answer and shows the next question."))
                }
            }
        }
    }

    /// One dash per question: filled once answered, wider for the one shown.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(questions.indices, id: \.self) { index in
                Capsule()
                    .fill(index == step || isAnswered(index) ? Theme.accent : Theme.line.opacity(0.15))
                    .frame(width: index == step ? 22 : 8, height: 4)
            }
            Text(L("\(step + 1) of \(questions.count)"))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.line.opacity(0.5))
                .padding(.leading, 4)
        }
        .animation(.snappy(duration: 0.25), value: step)
    }

    private var current: some View {
        questionView(step, questions[min(step, questions.count - 1)])
            .padding(.vertical, 2)
    }

    private func go(to index: Int) {
        guard questions.indices.contains(index) else { return }
        focusedField = nil
        withAnimation(.snappy(duration: 0.3)) {
            forward = index > step
            step = index
        }
    }

    private func isAnswered(_ index: Int) -> Bool { answers[questions[index].question] != nil }

    private func questionView(_ index: Int, _ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let header = question.header, !header.isEmpty {
                    Text(header.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.4)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.1), in: .capsule)
                }
                Text(question.question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.line)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                Text(L("Pick any that apply."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.line.opacity(0.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(question.options, id: \.label) { option in
                    OptionRow(option: option, multiple: question.multiSelect,
                              isOn: picks[index, default: []].contains(option.label)) { toggle(option.label, in: index, question) }
                }
                ownAnswer(index, question)
            }
            .padding(.top, 2)
        }
    }

    /// The answer of the developer's own: picked as soon as something is written in it.
    private func ownAnswer(_ index: Int, _ question: AgentQuestion) -> some View {
        let text = Binding(
            get: { written[index] ?? "" },
            set: { value in
                written[index] = value
                if !question.multiSelect {
                    if value.trimmingCharacters(in: .whitespaces).isEmpty { writes.remove(index) } else {
                        writes.insert(index)
                        picks[index] = []
                    }
                }
            })
        let isOn = question.multiSelect ? !(written[index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty : writes.contains(index)
        return HStack(spacing: 10) {
            OptionMark(multiple: question.multiSelect, isOn: isOn)
            TextField(L("Something else…"), text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focusedField, equals: index)
                .onSubmit {
                    if !isLast { if isAnswered(index) { go(to: index + 1) } } else if isComplete { onSend(answers) }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func toggle(_ label: String, in index: Int, _ question: AgentQuestion) {
        withAnimation(.snappy(duration: 0.2)) {
            if question.multiSelect {
                var current = picks[index, default: []]
                if let found = current.firstIndex(of: label) { current.remove(at: found) } else { current.append(label) }
                picks[index] = current
            } else {
                picks[index] = [label]
                writes.remove(index)
                if focusedField == index { focusedField = nil }
            }
        }
        // One pick answers it: on to the next, after a beat to see the pick land.
        if !question.multiSelect && index == step && !isLast {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if step == index { go(to: index + 1) } }
        }
    }

    /// Each question's answer: the option picked, the options checked (in the order shown, then
    /// what was written) joined by commas, or what was written.
    private var answers: [String: String] {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            let own = (written[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer: String
            if question.multiSelect {
                let checked = question.options.map(\.label).filter { picks[index, default: []].contains($0) }
                answer = (checked + (own.isEmpty ? [] : [own])).joined(separator: ", ")
            } else {
                answer = writes.contains(index) ? own : picks[index]?.first ?? ""
            }
            if !answer.isEmpty { result[question.question] = answer }
        }
        return result
    }

    private var isComplete: Bool { answers.count == Set(questions.map(\.question)).count }
}

private struct OptionRow: View {
    let option: AgentQuestion.Option
    let multiple: Bool
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                OptionMark(multiple: multiple, isOn: isOn)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(Theme.line)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.line.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isOn ? Theme.accent.opacity(0.09) : Theme.line.opacity(isHovered ? 0.04 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

/// A radio dot for one choice, a check box for several.
private struct OptionMark: View {
    let multiple: Bool
    let isOn: Bool

    var body: some View {
        ZStack {
            // A ring reads as something to click; it fills when picked.
            RoundedRectangle(cornerRadius: multiple ? 4 : 8)
                .strokeBorder(isOn ? Theme.accent : Theme.line.opacity(0.3), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: multiple ? 4 : 8).fill(isOn && multiple ? Theme.accent : .clear))
            if isOn {
                if multiple {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: 16, height: 16)
        .animation(.snappy(duration: 0.18), value: isOn)
    }
}
