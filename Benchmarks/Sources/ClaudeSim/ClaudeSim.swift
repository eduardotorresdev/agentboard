import Foundation

/// Deterministic stand-in for Claude Code's terminal output, modeled on a captured session of
/// Claude Code 2.1 (see `corpus/claude-startup.rec`): fullscreen in the alternate screen, a
/// header with the block-art mascot, a transcript area, a spinner line, the prompt between two
/// rules and a status line, all updated with cursor addressing and erase-to-end-of-line.
///
/// When the transcript scrolls, every transcript row is rewritten, which is the expensive case
/// for a terminal and the one benchmarks should not flatter.
public struct ClaudeSim {
    public enum Mode: String, CaseIterable, Sendable {
        /// Waits for the user, types a prompt, thinks, streams, calls tools, then waits again.
        case mixed
        /// Never waits: thinking, streaming and tool calls back to back.
        case stream
        /// Only the spinner animates, as during a long think.
        case spinner
    }

    public struct Chunk {
        /// Seconds to wait before writing `bytes`.
        public var delay: Double
        public var bytes: [UInt8]
    }

    private enum Phase {
        case boot
        case idle
        case typing(text: [Character], typed: Int)
        case thinking(remaining: Double)
        case streaming(words: [Word], shown: Int)
        case tool
    }

    private struct Word {
        enum Style { case plain, bold, code }
        let text: String
        let style: Style
    }

    public private(set) var cols: Int
    public private(set) var rows: Int
    private let mode: Mode
    private var rng: SplitMix64
    private var phase: Phase = .boot
    /// Styled transcript lines; the newest are at the end.
    private var transcript: [String] = []
    /// Index in `transcript` where the message being streamed starts.
    private var messageStart = 0
    private var spinnerVisible = false
    private var spinnerFrame = 0
    private var verb = "Pondering"
    private var turnTime: Double = 0
    private var tokens = 0
    private var contextPercent = 3
    private var toolCallsLeft = 0
    private var prompt = ""

    public init(cols: Int, rows: Int, mode: Mode = .mixed, seed: UInt64 = 1) {
        self.cols = max(20, cols)
        self.rows = max(12, rows)
        self.mode = mode
        rng = SplitMix64(seed: seed)
    }

    // MARK: Layout (1-based rows, like the escape sequences)

    private var transcriptTop: Int { 6 }
    private var spinnerRow: Int { rows - 5 }
    private var transcriptHeight: Int { spinnerRow - 1 - transcriptTop }
    private var promptRow: Int { rows - 3 }
    private var statusRow: Int { rows - 1 }

    // MARK: Driving

    /// The next write and how long to wait before it.
    public mutating func next() -> Chunk {
        var out = Output()
        var delay: Double = 0
        switch phase {
        case .boot:
            boot(&out)
            phase = mode == .mixed ? .idle : .thinking(remaining: rng.double(1.5...4))
            if mode == .spinner { phase = .thinking(remaining: .infinity) }
            delay = 0.3
        case .idle:
            // Waiting for the user: nothing on screen changes until they type.
            delay = rng.double(3...12)
            let text = Array(Self.prompts[rng.int(0...Self.prompts.count - 1)])
            phase = .typing(text: text, typed: 0)
            typePrompt(text: text, typed: 0, into: &out)
        case .typing(let text, let typed):
            delay = rng.double(0.08...0.16)
            let typed = min(text.count, typed + rng.int(1...3))
            if typed == text.count {
                submitPrompt(String(text), into: &out)
                toolCallsLeft = rng.int(0...3)
                phase = .thinking(remaining: rng.double(1.5...5))
            } else {
                typePrompt(text: text, typed: typed, into: &out)
                phase = .typing(text: text, typed: typed)
            }
        case .thinking(let remaining):
            delay = 0.05
            turnTime += delay
            tokens += rng.int(3...12)
            drawSpinner(into: &out)
            if remaining - delay <= 0 {
                messageStart = transcript.count
                phase = .streaming(words: makeMessage(), shown: 0)
            } else {
                phase = .thinking(remaining: remaining - delay)
            }
        case .streaming(let words, let shown):
            delay = 0.05
            turnTime += delay
            let shown = min(words.count, shown + rng.int(2...5))
            tokens += rng.int(4...10)
            layoutMessage(Array(words[0..<shown]), into: &out)
            drawSpinner(into: &out)
            if shown == words.count {
                phase = .tool
            } else {
                phase = .streaming(words: words, shown: shown)
            }
        case .tool:
            delay = rng.double(0.2...0.6)
            if mode == .stream || toolCallsLeft > 0 {
                toolCallsLeft -= 1
                addToolCall(into: &out)
                phase = .thinking(remaining: rng.double(1...3))
            } else {
                finishTurn(into: &out)
                phase = .idle
            }
        }
        return Chunk(delay: delay, bytes: out.bytes)
    }

    /// A full repaint at the new size, as Claude Code does on SIGWINCH.
    public mutating func resize(cols: Int, rows: Int) -> [UInt8] {
        self.cols = max(20, cols)
        self.rows = max(12, rows)
        var out = Output()
        out.write("\u{1b}[?25l\u{1b}[2J\u{1b}[H")
        drawChrome(into: &out)
        drawTranscript(from: 0, into: &out)
        if spinnerVisible { drawSpinner(into: &out) }
        parkCursor(&out)
        return out.bytes
    }

    /// Everything the simulator would write in `seconds` of simulated time, without waiting.
    public static func dump(seconds: Double, cols: Int = 120, rows: Int = 40, mode: Mode = .stream, seed: UInt64 = 1) -> [UInt8] {
        var sim = ClaudeSim(cols: cols, rows: rows, mode: mode, seed: seed)
        var bytes: [UInt8] = []
        var time: Double = 0
        while time < seconds {
            let chunk = sim.next()
            time += chunk.delay
            bytes += chunk.bytes
        }
        return bytes
    }

    // MARK: Screens

    private mutating func boot(_ out: inout Output) {
        out.write("\u{1b}7\u{1b}[r\u{1b}8\u{1b}[?25h")
        out.write("\u{1b}[?2004h\u{1b}[?2031h\u{1b}[?1004h")
        out.write("\u{1b}]0;✳ Claude Code\u{07}")
        out.write("\u{1b}[?1049h\u{1b}[2J\u{1b}[H\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?25l")
        drawChrome(into: &out)
        parkCursor(&out)
        // Capability probes; the terminal's answer to DA1 tells Claude the others are unsupported.
        out.write("\u{1b}[>0q\u{1b}[?u\u{1b}]7501;?\u{07}\u{1b}[c")
    }

    private func drawChrome(into out: inout Output) {
        let orange = "\u{1b}[38;2;215;119;87m", gray = "\u{1b}[38;2;153;153;153m"
        out.write("\u{1b}[2;1H\(orange) ▐\u{1b}[48;2;0;0;0m▛███▜\u{1b}[49m▌\u{1b}[12G\u{1b}[39m\u{1b}[1mClaude Code\u{1b}[22m \(gray)v2.1.312")
        out.write("\u{1b}[3;1H\(orange)▝▜\u{1b}[48;2;0;0;0m█████\u{1b}[49m▛▘\u{1b}[12G\(gray)Opus 5.5 with high effort · Claude Max")
        out.write("\u{1b}[4;1H\(orange)  ▘▘ ▝▝  \u{1b}[12G\(gray)~/orca/agentboard\u{1b}[39m")
        let rule = "\u{1b}[38;2;136;136;136m" + String(repeating: "─", count: cols) + "\u{1b}[39m"
        out.write("\u{1b}[\(promptRow - 1);1H\(rule)")
        out.write("\u{1b}[\(promptRow);1H❯\u{a0}\u{1b}[2mTry \"write a test for <filepath>\"\u{1b}[22m\u{1b}[K")
        out.write("\u{1b}[\(promptRow + 1);1H\(rule)")
        drawStatus(into: &out)
        out.write("\u{1b}[\(rows);3H\u{1b}[38;2;255;193;7m⏵⏵ auto mode on\(gray) (shift+tab to cycle) · ← for agents\u{1b}[39m\u{1b}[K")
    }

    private func drawStatus(into out: inout Output) {
        let filled = contextPercent / 10
        let meter = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
        out.write("\u{1b}[\(statusRow);3H\u{1b}[38;2;153;153;153m\u{1b}[2mdev@example.com\u{1b}[22m | Opus 5.5 | ")
        out.write("\u{1b}[32m\(meter) \(contextPercent)% (\(contextPercent * 10)k/1000k)\u{1b}[39m\u{1b}[K")
    }

    private func parkCursor(_ out: inout Output) {
        out.write("\u{1b}[\(promptRow);\(3 + prompt.count)H\u{1b}[?25h")
    }

    private mutating func typePrompt(text: [Character], typed: Int, into out: inout Output) {
        prompt = String(text[0..<typed])
        out.write("\u{1b}[?25l\u{1b}[\(promptRow);3H\(prompt)\u{1b}[K")
        parkCursor(&out)
    }

    private mutating func submitPrompt(_ text: String, into out: inout Output) {
        prompt = ""
        out.write("\u{1b}[?25l\u{1b}[\(promptRow);3H\u{1b}[K")
        append(["", "\u{1b}[38;2;153;153;153m>\u{1b}[39m \(text)", ""], into: &out)
        verb = Self.verbs[rng.int(0...Self.verbs.count - 1)]
        turnTime = 0
        tokens = 0
        parkCursor(&out)
    }

    private mutating func drawSpinner(into out: inout Output) {
        spinnerVisible = true
        spinnerFrame += 1
        let glyphs: [Character] = ["·", "✢", "✳", "✶", "✻", "✽"]
        let glyph = glyphs[(spinnerFrame / 2) % glyphs.count]
        let word = Array(verb + "…")
        let shimmer = spinnerFrame % (word.count + 6) - 3
        out.write("\u{1b}[?25l\u{1b}[\(spinnerRow);1H\u{1b}[38;2;215;119;87m\(glyph)\u{1b}[39m ")
        for (index, character) in word.enumerated() {
            let lit = abs(index - shimmer) <= 1
            out.write(lit ? "\u{1b}[38;2;245;169;137m" : "\u{1b}[38;2;215;119;87m")
            out.write(String(character))
        }
        let seconds = Int(turnTime)
        let count = tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
        out.write("\u{1b}[38;2;153;153;153m (esc to interrupt · \(seconds)s · ↓ \(count) tokens)\u{1b}[39m\u{1b}[K")
        parkCursor(&out)
    }

    private mutating func finishTurn(into out: inout Output) {
        spinnerVisible = false
        contextPercent = min(95, contextPercent + rng.int(1...4))
        out.write("\u{1b}[?25l\u{1b}[\(spinnerRow);1H\u{1b}[K")
        drawStatus(into: &out)
        parkCursor(&out)
    }

    // MARK: Transcript

    /// Replaces the lines from `messageStart` on with the message's current wrap.
    private mutating func layoutMessage(_ words: [Word], into out: inout Output) {
        let lines = wrap(words, prefix: "⏺ ")
        let old = Array(transcript[messageStart...])
        let previousCount = transcript.count
        transcript.replaceSubrange(messageStart..., with: lines)
        let firstChanged = (0..<min(old.count, lines.count)).first { old[$0] != lines[$0] } ?? min(old.count, lines.count)
        redraw(changedFrom: messageStart + firstChanged, previousCount: previousCount, into: &out)
    }

    private mutating func append(_ lines: [String], into out: inout Output) {
        let previousCount = transcript.count
        transcript += lines
        redraw(changedFrom: previousCount, previousCount: previousCount, into: &out)
    }

    /// Rewrites the transcript rows that changed; everything if the window scrolled.
    private mutating func redraw(changedFrom index: Int, previousCount: Int, into out: inout Output) {
        // Keep the transcript bounded like a long session's visible tail.
        if transcript.count > 400 {
            let drop = transcript.count - 400
            transcript.removeFirst(drop)
            messageStart = max(0, messageStart - drop)
            drawTranscript(from: 0, into: &out)
            return
        }
        let scrolled = transcript.count > transcriptHeight && transcript.count != previousCount
        drawTranscript(from: scrolled ? 0 : index - windowStart, into: &out)
    }

    private var windowStart: Int { max(0, transcript.count - transcriptHeight) }

    private func drawTranscript(from visibleRow: Int, into out: inout Output) {
        let start = windowStart
        out.write("\u{1b}[?25l")
        for row in max(0, visibleRow)..<transcriptHeight {
            out.write("\u{1b}[\(transcriptTop + row);1H")
            let index = start + row
            if index < transcript.count { out.write(transcript[index]) }
            out.write("\u{1b}[0m\u{1b}[K")
        }
    }

    private mutating func addToolCall(into out: inout Output) {
        let path = Self.paths[rng.int(0...Self.paths.count - 1)]
        let green = "\u{1b}[38;2;78;186;101m", gray = "\u{1b}[38;2;153;153;153m"
        var lines = [""]
        if rng.chance(0.4) {
            let added = rng.int(2...6), removed = rng.int(1...3)
            lines.append("\(green)⏺\u{1b}[39m \u{1b}[1mUpdate\u{1b}[22m(\(path))")
            lines.append("  ⎿  Updated \u{1b}[1m\(path)\u{1b}[22m with \(added) additions and \(removed) removals")
            var number = rng.int(10...400)
            for index in 0..<(added + removed) {
                let isRemoval = index < removed
                let code = Self.code[rng.int(0...Self.code.count - 1)]
                let body = "      \(number) \(isRemoval ? "-" : "+")  \(code)"
                let padding = String(repeating: " ", count: max(0, cols - body.count))
                let background = isRemoval ? "\u{1b}[48;2;255;220;220m" : "\u{1b}[48;2;220;240;255m"
                lines.append("\(background)\(body)\(padding)\u{1b}[49m")
                number += 1
            }
        } else {
            lines.append("\(green)⏺\u{1b}[39m \u{1b}[1mRead\u{1b}[22m(\(path))")
            lines.append("  ⎿  Read \u{1b}[1m\(rng.int(40...900))\u{1b}[22m lines \(gray)(ctrl+o to expand)\u{1b}[39m")
        }
        append(lines, into: &out)
        parkCursor(&out)
    }

    private mutating func makeMessage() -> [Word] {
        let count = mode == .stream ? rng.int(60...160) : rng.int(30...120)
        return (0..<count).map { _ in
            let roll = rng.double(0...1)
            if roll < 0.06 { return Word(text: Self.identifiers[rng.int(0...Self.identifiers.count - 1)], style: .code) }
            let text = Self.words[rng.int(0...Self.words.count - 1)]
            return Word(text: text, style: roll < 0.1 ? .bold : .plain)
        }
    }

    /// Word-wraps styled words to the screen width, keeping escape sequences out of the count.
    private func wrap(_ words: [Word], prefix: String) -> [String] {
        let width = cols - 2
        var lines: [String] = []
        var line = prefix, visible = prefix.count
        for word in words {
            if visible + 1 + word.text.count > width, visible > 2 {
                lines.append(line)
                line = "  "
                visible = 2
            }
            if visible > 2 { line += " "; visible += 1 }
            switch word.style {
            case .plain: line += word.text
            case .bold: line += "\u{1b}[1m\(word.text)\u{1b}[22m"
            case .code: line += "\u{1b}[38;2;177;185;249m\(word.text)\u{1b}[39m"
            }
            visible += word.text.count
        }
        lines.append(line)
        return lines
    }

    // MARK: Content

    private static let verbs = ["Pondering", "Thinking", "Cogitating", "Brewing", "Synthesizing", "Percolating"]
    private static let prompts = [
        "explique como o render funciona", "corrige o bug do cursor no card",
        "roda os testes e me diz o que quebrou", "refatora o BoardView em partes menores",
        "por que a memória sobe quando abro dez agentes?",
    ]
    private static let words = """
    o renderizador usa a GPU para desenhar cada célula do terminal e só as linhas alteradas são \
    enviadas ao buffer compartilhado então o custo por quadro fica proporcional ao que mudou e não \
    ao tamanho da tela quando a worktree sai de vista a sessão continua lendo o PTY mas para de \
    notificar a interface isso reduz a pressão na thread principal e evita trabalho desperdiçado \
    também é possível que a função não trate a sequência de escape corretamente vou verificar \
    agora os testes e ajustar a implementação até que todos passem sem regressões
    """.split(separator: " ").map(String.init)
    private static let identifiers = [
        "BoardView", "AgentSession", "GlyphAtlas", "setNeedsDisplay()", "MTLBuffer", "rowMap",
        "forkpty", "DispatchSource", "Terminal.feed(_:)", "CardMetrics.content(of:)",
    ]
    private static let paths = [
        "Sources/AgentBoard/Board/BoardView.swift", "Sources/AgentBoard/Agents/AgentSession.swift",
        "Sources/TerminalCore/Parser.swift", "Package.swift", "Sources/AgentBoard/ContentView.swift",
    ]
    private static let code = [
        "let cols = max(2, Int(content.width * scale) / atlas.cellWidth)",
        "session.resize(cols: cols, rows: rows)", "guard frame.intersects(bounds) else { return }",
        "store.onSessionChange = { [weak self] in self?.needsDisplay = true }",
        "if session.takeDirty() { rebuild() }", "}",
    ]
}

/// Accumulates UTF-8 output.
private struct Output {
    var bytes: [UInt8] = []
    mutating func write(_ text: String) { bytes.append(contentsOf: text.utf8) }
}

/// Small, fast, seedable PRNG so every run produces the same stream.
public struct SplitMix64 {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    public mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }

    public mutating func chance(_ probability: Double) -> Bool { double(0...1) < probability }
}
