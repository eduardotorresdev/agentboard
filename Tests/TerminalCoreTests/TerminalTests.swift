import Foundation
import Testing
@testable import TerminalCore

private func terminal(_ cols: Int = 20, _ rows: Int = 5, scrollback: Int = 100, _ input: String = "") -> Terminal {
    let terminal = Terminal(cols: cols, rows: rows, scrollback: scrollback)
    terminal.feed(input)
    return terminal
}

private func lines(_ terminal: Terminal) -> [String] { terminal.screenText() }

@Suite("Printing and cursor")
struct PrintingTests {
    @Test func printsAndMovesCursor() {
        let t = terminal(10, 3, "hello")
        #expect(lines(t)[0] == "hello")
        #expect(t.cursor.column == 5 && t.cursor.row == 0)
    }

    @Test func wrapsOnlyWhenTheNextCharacterArrives() {
        let t = terminal(5, 3, "abcde")
        #expect(t.cursor.column == 4 && t.cursor.row == 0, "pending wrap keeps the cursor on the last column")
        t.feed("f")
        #expect(lines(t)[0] == "abcde" && lines(t)[1] == "f")
        #expect(t.cursor.column == 1 && t.cursor.row == 1)
    }

    @Test func carriageReturnCancelsPendingWrap() {
        let t = terminal(5, 3, "abcde\rX")
        #expect(lines(t)[0] == "Xbcde")
        #expect(lines(t)[1] == "")
    }

    @Test func noAutowrapOverwritesLastColumn() {
        let t = terminal(5, 3, "\u{1b}[?7labcdefg")
        #expect(lines(t)[0] == "abcdg")
        #expect(t.cursor.row == 0)
    }

    @Test func cursorAddressingAndRelativeMoves() {
        let t = terminal(10, 5, "\u{1b}[3;4HX\u{1b}[2AY\u{1b}[5CZ\u{1b}[GW")
        // X lands at column 3, Y two rows up right after it, Z clamps to the last column.
        #expect(lines(t)[2] == "   X")
        #expect(lines(t)[0] == "W   Y    Z")
    }

    @Test func lineFeedScrollsIntoScrollback() {
        let t = terminal(10, 2, "one\r\ntwo\r\nthree")
        #expect(lines(t) == ["two", "three"])
        #expect(t.scrollback.count == 1)
        #expect(t.scrollback.line(0, cols: 10)?.cells.prefix(3).map(\.scalar) == Array("one".unicodeScalars.map(\.value)))
    }

    @Test func tabsStopEveryEightColumns() {
        let t = terminal(20, 2, "a\tb\tc")
        #expect(lines(t)[0] == "a       b       c")
    }

    @Test func backspaceAndRepeat() {
        let t = terminal(10, 2, "ab\u{8}c\u{1b}[3b")
        #expect(lines(t)[0] == "acccc")
    }
}

@Suite("Erasing and editing")
struct EditingTests {
    @Test func eraseLineModes() {
        let t = terminal(10, 3, "0123456789\r\u{1b}[5C\u{1b}[K")
        #expect(lines(t)[0] == "01234")
        t.feed("\r\u{1b}[2C\u{1b}[1K")
        #expect(lines(t)[0] == "   34")
        t.feed("\u{1b}[2K")
        #expect(lines(t)[0] == "")
    }

    @Test func eraseLineWithPendingWrapClearsTheLastColumn() {
        // xterm: a full line leaves the cursor on the last column with a wrap pending; EL then
        // erases from that column, so the last cell goes too and nothing wraps.
        let t = terminal(5, 2, "\u{1b}[41mabcde\u{1b}[0m\u{1b}[K")
        #expect(lines(t) == ["abcd", ""])
        #expect(t.cell(column: 4, row: 0).background == .default)
        #expect(t.cursor.row == 0)
    }

    @Test func eraseDisplayBelowAndAll() {
        let t = terminal(5, 3, "aaaaa\r\nbbbbb\r\nccccc\u{1b}[2;3H\u{1b}[J")
        #expect(lines(t) == ["aaaaa", "bb", ""])
        t.feed("\u{1b}[2J")
        #expect(lines(t) == ["", "", ""])
    }

    @Test func eraseUsesCurrentBackground() {
        let t = terminal(5, 2, "\u{1b}[41m\u{1b}[2K")
        #expect(t.cell(column: 3, row: 0).background == .palette(1))
    }

    @Test func insertAndDeleteCharacters() {
        let t = terminal(10, 2, "abcdef\r\u{1b}[2C\u{1b}[2@")
        #expect(lines(t)[0] == "ab  cdef")
        t.feed("\u{1b}[3P")
        #expect(lines(t)[0] == "abdef")
        t.feed("\u{1b}[2X")
        #expect(lines(t)[0] == "ab  f")
    }

    @Test func scrollRegionAndInsertDeleteLines() {
        let t = terminal(5, 5, "1\r\n2\r\n3\r\n4\r\n5\u{1b}[2;4r\u{1b}[4;1H\n")
        #expect(lines(t) == ["1", "3", "4", "", "5"], "scrolling inside the region leaves rows outside it alone")
        #expect(t.scrollback.count == 0, "region scrolls don't feed the scrollback")
        t.feed("\u{1b}[2;1H\u{1b}[L")
        #expect(lines(t) == ["1", "", "3", "4", "5"])
        t.feed("\u{1b}[M")
        #expect(lines(t) == ["1", "3", "4", "", "5"])
    }

    @Test func reverseIndexAtTopScrollsDown() {
        let t = terminal(5, 3, "a\r\nb\r\nc\u{1b}[H\u{1b}M")
        #expect(lines(t) == ["", "a", "b"])
    }
}

@Suite("Attributes and colors")
struct AttributeTests {
    @Test func basicAndBrightColors() {
        let t = terminal(10, 2, "\u{1b}[1;31;42mA\u{1b}[0;95;104mB\u{1b}[mC")
        let a = t.cell(column: 0, row: 0), b = t.cell(column: 1, row: 0), c = t.cell(column: 2, row: 0)
        #expect(a.attributes.contains(.bold) && a.foreground == .palette(1) && a.background == .palette(2))
        #expect(!b.attributes.contains(.bold) && b.foreground == .palette(13) && b.background == .palette(12))
        #expect(c.foreground == .default && c.background == .default && c.attributes.isEmpty)
    }

    @Test func extendedColorsInBothSyntaxes() {
        let t = terminal(10, 2, "\u{1b}[38;5;208mA\u{1b}[38;2;215;119;87mB\u{1b}[38:2::1:2:3mC\u{1b}[48:5:17mD\u{1b}[38:2:9:8:7mE")
        #expect(t.cell(column: 0, row: 0).foreground == .palette(208))
        #expect(t.cell(column: 1, row: 0).foreground == .rgb(215, 119, 87))
        #expect(t.cell(column: 2, row: 0).foreground == .rgb(1, 2, 3))
        #expect(t.cell(column: 3, row: 0).background == .palette(17))
        #expect(t.cell(column: 4, row: 0).foreground == .rgb(9, 8, 7))
    }

    @Test func attributesSetAndClear() {
        let t = terminal(10, 2, "\u{1b}[2;3;4;7;9mA\u{1b}[22;23;24;27;29mB\u{1b}[4:3mC\u{1b}[53mD")
        #expect(t.cell(column: 0, row: 0).attributes == [.dim, .italic, .underline, .inverse, .strikethrough])
        #expect(t.cell(column: 1, row: 0).attributes.isEmpty)
        #expect(t.cell(column: 2, row: 0).attributes == [.curlyUnderline])
        #expect(t.cell(column: 3, row: 0).attributes == [.curlyUnderline, .overline])
    }
}

@Suite("Unicode")
struct UnicodeTests {
    @Test func wideCharactersTakeTwoCells() {
        let t = terminal(10, 2, "a终b")
        #expect(t.cell(column: 1, row: 0).width == .wide)
        #expect(t.cell(column: 2, row: 0).width == .tail)
        #expect(t.cursor.column == 4)
        #expect(lines(t)[0] == "a终b")
    }

    @Test func wideCharacterAtLastColumnWraps() {
        let t = terminal(4, 2, "abc终")
        #expect(lines(t) == ["abc", "终"])
    }

    @Test func combiningMarksJoinThePreviousCell() {
        let t = terminal(10, 2, "e\u{301}x")
        #expect(t.cell(column: 0, row: 0).isCluster)
        #expect(t.text(of: t.cell(column: 0, row: 0)) == "e\u{301}")
        #expect(t.cursor.column == 2)
    }

    @Test func zeroWidthJoinerSequencesStayInOneCell() {
        let t = terminal(10, 2, "👨\u{200D}👩\u{200D}👧!")
        #expect(t.text(of: t.cell(column: 0, row: 0)) == "👨\u{200D}👩\u{200D}👧")
        #expect(t.cell(column: 2, row: 0).scalar == UInt32(("!" as Unicode.Scalar).value))
    }

    @Test func utf8SplitAcrossReads() {
        let t = terminal(10, 2)
        let bytes = Array("ação".utf8)
        for byte in bytes { t.feed([byte]) }
        #expect(lines(t)[0] == "ação")
    }

    @Test func invalidUTF8BecomesReplacementCharacter() {
        let t = terminal(10, 2)
        t.feed([0x61, 0xFF, 0x62, 0xE2, 0x82, 0x63])
        #expect(lines(t)[0] == "a\u{FFFD}b\u{FFFD}c")
    }

    @Test func decSpecialGraphicsDrawsLines() {
        let t = terminal(10, 2, "\u{1b}(0lqk\u{1b}(Bx")
        #expect(lines(t)[0] == "┌─┐x")
    }

    @Test func claudeGlyphWidths() {
        // Claude Code lays out these as one column each; disagreeing shifts its whole UI.
        let t = terminal(20, 2, "⏺⎿❯✻✳⏵▐▛█▜▌")
        #expect(t.cursor.column == 11)
    }
}

@Suite("Screens and modes")
struct ScreenTests {
    @Test func alternateScreenSavesAndRestores() {
        let t = terminal(10, 3, "main\u{1b}[?1049h")
        #expect(t.isAlternateScreen && lines(t) == ["", "", ""])
        t.feed("alt")
        t.feed("\u{1b}[?1049l")
        #expect(!t.isAlternateScreen && lines(t)[0] == "main")
        #expect(t.cursor.column == 4)
    }

    @Test func alternateScreenDoesNotFeedScrollback() {
        let t = terminal(5, 2, "\u{1b}[?1049h1\r\n2\r\n3\r\n4")
        #expect(t.scrollback.count == 0)
    }

    @Test func modesToggle() {
        let t = terminal(10, 2, "\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?25l\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2026h")
        #expect(t.modes.contains([.applicationCursor, .bracketedPaste, .focusEvents, .synchronizedOutput]))
        #expect(!t.cursor.visible)
        #expect(t.mouseTracking == .buttonEvent && t.mouseEncoding == .sgr)
        t.feed("\u{1b}[?2026l\u{1b}[?1002l")
        #expect(!t.isSynchronizing && t.mouseTracking == .none)
    }

    @Test func resizeKeepsCursorLineVisible() {
        let t = terminal(10, 5, "1\r\n2\r\n3\r\n4\r\n5")
        t.resize(cols: 6, rows: 3)
        #expect(lines(t) == ["3", "4", "5"])
        #expect(t.scrollback.count == 2)
        #expect(t.cursor.row == 2)
    }
}

@Suite("Replies to the program")
struct ReplyTests {
    private func reply(_ t: Terminal) -> String { String(decoding: t.takeOutput() ?? [], as: UTF8.self) }

    @Test func deviceAttributesAndStatus() {
        let t = terminal(10, 5, "\u{1b}[c")
        #expect(reply(t) == "\u{1b}[?62;22c")
        t.feed("\u{1b}[>c")
        #expect(reply(t) == "\u{1b}[>1;10;0c")
        t.feed("\u{1b}[3;4H\u{1b}[6n")
        #expect(reply(t) == "\u{1b}[3;4R")
        t.feed("\u{1b}[5n")
        #expect(reply(t) == "\u{1b}[0n")
    }

    @Test func modeQueries() {
        let t = terminal(10, 2, "\u{1b}[?2026$p")
        #expect(reply(t) == "\u{1b}[?2026;2$y")
        t.feed("\u{1b}[?2026h\u{1b}[?2026$p\u{1b}[?9999$p")
        #expect(reply(t) == "\u{1b}[?2026;1$y\u{1b}[?9999;0$y")
    }

    @Test func colorQueriesAnswerWithTheTheme() {
        let t = terminal(10, 2, "\u{1b}]11;?\u{07}")
        #expect(reply(t) == "\u{1b}]11;rgb:ffff/ffff/ffff\u{07}")
        t.feed("\u{1b}]10;?\u{1b}\\")
        #expect(reply(t) == "\u{1b}]10;rgb:2626/2121/3a3a\u{1b}\\")
    }

    @Test func kittyKeyboardQueryGetsNoAnswer() {
        let t = terminal(10, 2, "\u{1b}[?u\u{1b}[>0q")
        #expect(t.takeOutput() == nil)
    }

    @Test func titleBellAndNotifications() {
        let t = terminal(10, 2, "\u{1b}]0;✳ Claude Code\u{07}\u{07}\u{1b}]9;Claude needs input\u{1b}\\\u{1b}]9;4;1;50\u{07}")
        let events = t.takeEvents()
        #expect(t.title == "✳ Claude Code" && events.titleChanged)
        #expect(events.bells == 1)
        #expect(events.notifications == ["Claude needs input"])
    }
}

@Suite("Input encoding")
struct InputTests {
    @Test func cursorKeysFollowApplicationMode() {
        let t = terminal()
        #expect(t.encode(.up) == Array("\u{1b}[A".utf8))
        t.feed("\u{1b}[?1h")
        #expect(t.encode(.up) == Array("\u{1b}OA".utf8))
        #expect(t.encode(.left, modifiers: .control) == Array("\u{1b}[1;5D".utf8))
        #expect(t.encode(.enter, modifiers: .shift) == Array("\u{1b}\r".utf8))
    }

    @Test func pasteIsBracketedAndCannotEscape() {
        let t = terminal()
        #expect(t.encodePaste("a\nb") == Array("a\rb".utf8))
        t.feed("\u{1b}[?2004h")
        #expect(t.encodePaste("x\u{1b}[201~y") == Array("\u{1b}[200~xy\u{1b}[201~".utf8))
    }

    @Test func mouseReportsInSGR() {
        let t = terminal()
        #expect(t.encodeMouse(MouseEvent(kind: .press, column: 0, row: 0)) == nil)
        t.feed("\u{1b}[?1000h\u{1b}[?1006h")
        #expect(t.encodeMouse(MouseEvent(kind: .press, column: 4, row: 2)) == Array("\u{1b}[<0;5;3M".utf8))
        #expect(t.encodeMouse(MouseEvent(kind: .release, column: 4, row: 2)) == Array("\u{1b}[<0;5;3m".utf8))
        #expect(t.encodeMouse(MouseEvent(kind: .scrollDown, column: 0, row: 0)) == Array("\u{1b}[<65;1;1M".utf8))
        #expect(t.encodeMouse(MouseEvent(kind: .motion, column: 0, row: 0)) == nil, "?1000 doesn't report motion")
    }

    @Test func focusReportsOnlyWhenEnabled() {
        let t = terminal()
        #expect(t.encodeFocus(true) == nil)
        t.feed("\u{1b}[?1004h")
        #expect(t.encodeFocus(false) == Array("\u{1b}[O".utf8))
    }
}

@Suite("Damage tracking")
struct DamageTests {
    @Test func reportsOnlyChangedRows() {
        let t = terminal(10, 4)
        t.consumeDamage(all: true) { _, _ in }
        t.feed("\u{1b}[3;1Hx")
        var changed: [Int] = []
        t.consumeDamage { row, _ in changed.append(row) }
        #expect(changed == [2])
        t.consumeDamage { row, _ in changed.append(row) }
        #expect(changed == [2], "damage is consumed")
    }

    @Test func scrollingRotatesTheRowMap() {
        let t = terminal(10, 3, "a\r\nb\r\nc")
        t.consumeDamage(all: true) { _, _ in }
        let version = t.rowMapVersion
        t.feed("\r\nd")
        #expect(t.rowMapVersion != version)
        var changed: [Int] = []
        t.consumeDamage { row, _ in changed.append(row) }
        #expect(changed.count == 1, "only the recycled row is new; the others just moved")
        var map = [UInt32](repeating: 0, count: 3)
        map.withUnsafeMutableBufferPointer { t.copyRowMap(into: $0.baseAddress!) }
        #expect(map[2] == UInt32(changed[0]))
    }
}

@Suite("Scrollback")
struct ScrollbackTests {
    @Test func packsAndUnpacksStyledLines() {
        let t = terminal(12, 1, scrollback: 10)
        t.feed("\u{1b}[1;38;2;1;2;3mab\u{1b}[0m 终\u{1b}[44mz\r\n")
        let line = t.scrollback.line(0, cols: 12)!
        #expect(line.cells[0].attributes.contains(.bold) && line.cells[0].foreground == .rgb(1, 2, 3))
        #expect(line.cells[3].width == .wide && line.cells[4].width == .tail)
        #expect(line.cells[5].background == .palette(4))
        #expect(line.cells[6] == .blank())
    }

    @Test func dropsOldestBeyondTheLimit() {
        let t = terminal(8, 1, scrollback: 3)
        for i in 0..<10 { t.feed("line\(i)\r\n") }
        #expect(t.scrollback.count == 3)
        let first = t.scrollback.line(0, cols: 8)!.cells.prefix(5).compactMap { Unicode.Scalar($0.scalar).map(Character.init) }
        #expect(String(first) == "line7")
    }

    @Test func manyLinesStayCompact() {
        let t = terminal(120, 40, scrollback: 5000)
        for i in 0..<6000 { t.feed("\u{1b}[32mok\u{1b}[0m line number \(i) with some typical output text\r\n") }
        #expect(t.scrollback.count == 5000)
        #expect(t.scrollback.memoryUsage < 600 * 1024, "about 100 bytes per line, not 12 per cell")
    }
}

@Suite("Real Claude Code output")
struct ClaudeCaptureTests {
    @Test func startupScreenRenders() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/corpus/claude-startup.rec")
        let data = try [UInt8](Data(contentsOf: url))
        let t = Terminal(cols: 120, rows: 40)
        var index = 0
        var replies = ""
        // Play up to the moment the prompt was typed (before Ctrl+C left the alternate screen).
        while index + 8 <= data.count {
            let time = Int(data[index]) | Int(data[index + 1]) << 8 | Int(data[index + 2]) << 16
            let length = Int(data[index + 4]) | Int(data[index + 5]) << 8
            index += 8
            if time > 9000 { break }
            t.feed(Array(data[index..<index + length]))
            replies += String(decoding: t.takeOutput() ?? [], as: UTF8.self)
            index += length
        }
        let screen = t.screenText()
        #expect(t.isAlternateScreen)
        #expect(screen[1].contains("Claude Code") && screen[1].hasPrefix(" ▐▛███▛█"))
        #expect(screen[36].hasPrefix("❯\u{a0}explique como o render funciona"))
        #expect(screen[35].allSatisfy { $0 == "─" } && screen[35].count == 120)
        #expect(replies.contains("\u{1b}[?62;22c"), "DA1 answered so Claude stops probing")
        #expect(t.mouseTracking == .anyEvent && t.mouseEncoding == .sgr)
    }
}

@Suite("Recent text")
struct RecentTextTests {
    /// Lines come from the scrollback and the screen in order; soft-wrapped rows join back
    /// into one line, and the blank rows under the output are left out.
    @Test func joinsScrollbackAndScreen() {
        let t = terminal(10, 4, scrollback: 100, (1...8).map { "line \($0)" }.joined(separator: "\r\n") + "\r\nabcdefghijKLM")
        #expect(t.recentText(lines: 100) == (1...8).map { "line \($0)" } + ["abcdefghijKLM"])
        #expect(t.recentText(lines: 2) == ["line 8", "abcdefghijKLM"])
    }

    @Test func emptyTerminal() {
        #expect(terminal(10, 4).recentText(lines: 10).isEmpty)
    }
}
