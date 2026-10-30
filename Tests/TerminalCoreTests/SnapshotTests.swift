import Testing
@testable import TerminalCore

/// Everything a snapshot carries, in a form two terminals can be compared by.
private func state(_ terminal: Terminal) -> [String] {
    func describe(_ grid: Grid) -> String {
        (0..<grid.rows).map { y in "\(grid.isWrapped(y))" + (0..<grid.cols).map { "\(grid.row(y)[$0])" }.joined() }.joined(separator: "\n")
    }
    var lines = [
        "\(terminal.cols)x\(terminal.rows) cursor \(terminal.cursorX),\(terminal.cursorY) wrap \(terminal.pendingWrap)",
        "modes \(terminal.modes.rawValue) mouse \(terminal.mouseTracking) \(terminal.mouseEncoding) shape \(terminal.cursorShape)",
        "title \(terminal.title) cwd \(terminal.workingDirectory ?? "-")",
        "pen \(terminal.pen) region \(terminal.scrollTop)-\(terminal.scrollBottom) tabs \(terminal.tabStops)",
        "charsets \(terminal.charsets) \(terminal.activeCharset) saved \(String(describing: terminal.savedMain)) \(String(describing: terminal.savedAlternate))",
        "last \(terminal.lastPrinted) join \(terminal.joinNext) clusters \(terminal.clusters.allScalars)",
        "alternate \(terminal.isAlternateScreen)",
        describe(terminal.main),
        terminal.alternate.map(describe) ?? "no alternate",
    ]
    for index in 0..<terminal.scrollback.count {
        let line = terminal.scrollback.line(index, cols: terminal.cols)!
        lines.append("\(line.wrapped)" + line.cells.map { "\($0)" }.joined())
    }
    return lines
}

/// A copy made through a snapshot, starting from a terminal of another size.
private func copy(_ terminal: Terminal) -> Terminal {
    let copy = Terminal(cols: 7, rows: 3, scrollback: terminal.scrollback.limit)
    copy.feed("stale content\r\nthat must go")
    #expect(copy.restore(terminal.snapshot()))
    return copy
}

/// Styled, wide, combined and wrapped text, scrolled into history, with a scroll region,
/// saved cursor, charset and modes set.
private let busyScreen = [
    "\u{1b}]2;agent title\u{07}\u{1b}]7;file:///tmp\u{07}",
    (0..<30).map { "line \($0) \u{1b}[1;38;5;\($0)m bold \u{1b}[48;2;10;20;30mbg\u{1b}[0m" }.joined(separator: "\r\n"),
    "\r\n日本語 wide e\u{301} 👩‍💻 cluster ",
    String(repeating: "wrapping ", count: 8),
    "\u{1b}[44m\u{1b}[K\u{1b}[0m",
    "\u{1b}[2;4r\u{1b}[3;5H\u{1b}7\u{1b}[4m\u{1b}(0qqq",
    "\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[5 q\u{1b}[3g\u{1b}[10G\u{1b}H",
].joined()

struct SnapshotTests {
    @Test func copiesTheMainScreenAndHistory() {
        let original = Terminal(cols: 24, rows: 6, scrollback: 100)
        original.feed(busyScreen)
        let restored = copy(original)
        #expect(state(restored) == state(original))
        #expect(restored.scrollback.count > 20)
    }

    /// The alternate screen, the main screen behind it and the cursor saved on entering.
    @Test func copiesTheAlternateScreen() {
        let original = Terminal(cols: 24, rows: 6, scrollback: 100)
        original.feed(busyScreen + "\u{1b}[?1049h\u{1b}[2J\u{1b}[HTUI frame\u{1b}[6;24H\u{1b}[7mX")
        let restored = copy(original)
        #expect(restored.isAlternateScreen)
        #expect(state(restored) == state(original))
        // Leaving it brings back the same main screen and cursor on both.
        original.feed("\u{1b}[?1049l")
        restored.feed("\u{1b}[?1049l")
        #expect(state(restored) == state(original))
    }

    /// State that only shows in later output (pen, region, charset, pending wrap, tab stops)
    /// carries over: the same input afterwards draws the same thing on both.
    @Test func laterOutputDrawsTheSame() {
        let original = Terminal(cols: 24, rows: 6, scrollback: 100)
        original.feed(busyScreen + "\u{1b}[1;24Hz")
        let restored = copy(original)
        let more = "after\tTab\u{1b}(Bjj\r\nnext\u{1b}8restored\u{1b}[r" + (0..<10).map { "more \($0)\r\n" }.joined() + "\u{301}"
        original.feed(more)
        restored.feed(more)
        #expect(state(restored) == state(original))
    }

    @Test func rejectsGarbageAndKeepsItsState() {
        let terminal = Terminal(cols: 10, rows: 2)
        terminal.feed("keep")
        let before = state(terminal)
        #expect(!terminal.restore([1, 2, 3]))
        var truncated = Terminal(cols: 10, rows: 2).snapshot()
        truncated.removeLast(5)
        #expect(!terminal.restore(truncated))
        #expect(state(terminal) == before)
    }

    @Test func restoringRedrawsEveryRow() {
        let original = Terminal(cols: 10, rows: 3)
        original.feed("abc")
        let restored = Terminal(cols: 10, rows: 3)
        restored.consumeDamage { _, _ in }
        let version = restored.layoutVersion
        restored.restore(original.snapshot())
        var damaged = 0
        restored.consumeDamage { _, _ in damaged += 1 }
        #expect(damaged == 3)
        #expect(restored.layoutVersion != version)
    }

    /// A snapshot taken anywhere, even inside an escape sequence or a UTF-8 character, carries
    /// the parser along: the rest of the stream then draws the same on the copy.
    @Test func resumesMidSequence() {
        let stream = Array(("\u{1b}[38;2;200;100;50mcolored\u{1b}[0m 日本 e\u{301} \u{1b}]2;new title\u{07}" +
                            "\u{1b}[?1049h\u{1b}[3;5Halt\u{1b}P1$qm\u{1b}\\\u{1b}[?1049l done \u{1b}[5Dend").utf8)
        for split in 0...stream.count {
            let original = Terminal(cols: 30, rows: 5, scrollback: 100)
            original.feed(Array(stream[..<split]))
            let copy = copy(original)
            for terminal in [original, copy] { terminal.feed(Array(stream[split...])) }
            #expect(state(copy) == state(original), "split at byte \(split)")
        }
    }
}
