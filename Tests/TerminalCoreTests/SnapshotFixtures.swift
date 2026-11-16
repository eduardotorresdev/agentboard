import Foundation
import Testing
@testable import TerminalCore

// Golden files for the Rust port (`core/crates/terminal`): what this terminal holds and answers
// after a known input. The Rust tests replay each case and compare byte for byte.
//
// Written to `core/fixtures/terminal/`, per case:
// - `<name>.steps`: `size <cols> <rows> <scrollback>`, then one line per step: `feed <bytes>`
//   (the next bytes of `<name>.input`), `resize <cols> <rows>`, or `snapshot <replies so far>`
//   (the state at that point is `<name>.snapshot.<n>`, n counting from 0).
// - `<name>.restored.<n>`: where a terminal restored from snapshot n and fed the rest ends,
//   when that isn't `<name>.snapshot`.
// - `<name>.input`: every fed byte, in order.
// - `<name>.snapshot`: `snapshot()` after the last step.
// - `<name>.replies`: everything the terminal answered.
// - `<name>.expect`: title, events and text, as `describe` prints them.
// Plus `widths.txt`, `graphemes.txt` and `paste.txt`: the tables and string behavior the port
// has to copy from this platform's Unicode data and Foundation; and `input.txt`: how keys,
// focus and the mouse are encoded in every mode.

private let e = "\u{1b}"

private enum Step {
    case feed([UInt8])
    case resize(Int, Int)
    case snapshot

    static func text(_ text: String) -> Step { .feed(Array(text.utf8)) }
}

private struct Case {
    var name: String
    var cols: Int
    var rows: Int
    var scrollback = 100
    var steps: [Step]

    init(_ name: String, _ cols: Int, _ rows: Int, scrollback: Int = 100, _ steps: [Step]) {
        self.name = name
        self.cols = cols
        self.rows = rows
        self.scrollback = scrollback
        self.steps = steps
    }

    /// One feed of `text`.
    init(_ name: String, _ cols: Int, _ rows: Int, scrollback: Int = 100, _ text: String) {
        self.init(name, cols, rows, scrollback: scrollback, [.text(text)])
    }
}

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0...values.count - 1)] }
}

/// Joined without `+`, which the type checker gives up on in long chains.
private func j(_ parts: String...) -> String { parts.joined() }

private func hex(_ text: String) -> String { text.isEmpty ? "-" : text.utf8.map { String(format: "%02x", $0) }.joined() }

/// What the owner reads besides the snapshot.
private func describe(_ terminal: Terminal, _ events: TerminalEvents) -> String {
    var lines = [
        "size \(terminal.cols) \(terminal.rows)",
        "cursor \(terminal.cursor.column) \(terminal.cursor.row) \(terminal.cursor.visible) \(terminal.cursor.shape.rawValue)",
        "modes \(terminal.modes.rawValue) mouse \(terminal.mouseTracking.rawValue) \(terminal.mouseEncoding.rawValue)",
        "alternate \(terminal.isAlternateScreen) synchronizing \(terminal.isSynchronizing) scrollback \(terminal.scrollback.count)",
        "title \(hex(terminal.title))",
        "cwd \(terminal.workingDirectory.map(hex) ?? "none")",
        "bells \(events.bells) titleChanged \(events.titleChanged)",
    ]
    lines += events.notifications.map { "notification \(hex($0))" }
    lines += terminal.screenText().map { "screen \(hex($0))" }
    lines += terminal.recentText(lines: 1000).map { "recent \(hex($0))" }
    lines += terminal.recentText(lines: 3).map { "recent3 \(hex($0))" }
    return lines.joined(separator: "\n") + "\n"
}

private func split(_ bytes: [UInt8], every size: Int) -> [Step] {
    stride(from: 0, to: bytes.count, by: size).map { .feed(Array(bytes[$0..<min(bytes.count, $0 + size)])) }
}

// MARK: Corpus

private func handWritten() -> [Case] {
    var cases: [Case] = []

    cases.append(Case("plain_wrap", 20, 6,
        "hello world\r\nthis line is longer than twenty columns and wraps twice\r\nab\u{8}c\u{8}\u{8}\u{8}\u{8}X\r\n" +
        "12345678901234567890\rZ\r\n12345678901234567890\u{8}Y\n\nend"))
    cases.append(Case("pending_wrap", 5, 4, [.text("abcde"), .snapshot, .text("f\u{1b}[Kgh"), .text("\r\n12345\u{1b}[1Ax\r\n12345\tT")]))
    cases.append(Case("no_autowrap", 8, 4, "\(e)[?7labcdefghijkl\r\nxy终终终终终\r\n\(e)[?7hback to wrapping here"))
    cases.append(Case("scroll_plain", 12, 4, scrollback: 6, (0..<20).map { j("row \($0) ", String(repeating: "x", count: $0)) }.joined(separator: "\r\n")))

    var sgr = ""
    for code in 0...110 { sgr += "\(e)[\(code)mS\(code)\(e)[m " }
    cases.append(Case("sgr_each", 60, 12, sgr))
    cases.append(Case("sgr_colors", 40, 12,
        j((0..<16).map { "\(e)[38;5;\($0 * 17)m\(e)[48;5;\(255 - $0 * 3)mP" }.joined(), "\(e)[0m\r\n",
        "\(e)[38;2;215;119;87mA\(e)[48;2;1;2;3mB\(e)[38:2::10:20:30mC\(e)[48:5:17mD\(e)[38:2:9:8:7mE\(e)[38:5:200mF\(e)[m\r\n",
        "\(e)[38;5;300mG\(e)[38;2;999;0;256mH\(e)[38;5mI\(e)[38;2;1;2mJ\(e)[38mK\(e)[38;9;1mL\(e)[48;2mM\(e)[38:5mN\(e)[38:2:1:2mO\(e)[38:3:1:2:3mP\(e)[m\r\n",
        "\(e)[1;31;42mA\(e)[0;95;104mB\(e)[mC\(e)[58;5;3;4mD\(e)[58:2::1:2:3;9mE\(e)[58;2;1;2;3;53mF\(e)[m\r\n",
        "\(e)[38;5;1;48;5;2;1;3mG\(e)[39mH\(e)[49mI\(e)[22;23mJ\(e)[;7mK\(e)[7;mL\(e)[;mM")))
    cases.append(Case("sgr_underlines", 40, 6,
        "\(e)[4mA\(e)[4:0mB\(e)[4:1mC\(e)[4:2mD\(e)[4:3mE\(e)[4:4mF\(e)[4:5mG\(e)[21mH\(e)[24mI\(e)[4;21mJ\(e)[4:3;1mK\(e)[24;53mL\(e)[55mM" +
        "\(e)[4:mN\(e)[m\(e)[2;3;5;6;7;8;9mO\(e)[22;23;25;27;28;29mP\(e)[1:2:3mQ\(e)[0:1mR\(e)[4:3:9:9;31mS"))
    cases.append(Case("sgr_many_params", 40, 4,
        j("\(e)[", (0..<40).map { "\($0 % 9 + 1)" }.joined(separator: ";"), "mA",
          "\(e)[", (0..<31).map { _ in "0" }.joined(separator: ";"), ";4:3mB",
          "\(e)[", (0..<31).map { _ in "0" }.joined(separator: ";"), ";4:mC",
          "\(e)[", (0..<30).map { _ in "1" }.joined(separator: ";"), ";38;5;9mD",
          "\(e)[", (0..<70).map { _ in "3" }.joined(separator: ":"), "mE")))

    cases.append(Case("cursor_moves", 20, 8,
        "\(e)[3;4HX\(e)[2AY\(e)[5CZ\(e)[GW\(e)[4BV\(e)[3DU\(e)[2ET\(e)[1FS\(e)[10GR\(e)[6dQ\(e)[2;2fP\(e)[5`O\(e)[3aN\(e)[2eM" +
        "\(e)[999;999HL\(e)[0;0HK\(e)[;5HJ\(e)[4;HI\(e)[99AH\(e)[99BG\(e)[99CF\(e)[99DE\(e)[0AD\(e)[0CC\(e)[65535;65535HB\(e)[70000dA"))
    cases.append(Case("scroll_region", 10, 8,
        j((1...8).map { "\($0)" }.joined(separator: "\r\n"),
        "\(e)[3;6r\(e)[6;1H\nA\nB\(e)[3;1H\(e)MC\(e)MD\(e)[2S\(e)[1TE\(e)[8;1H\nF\n\(e)[1;1H\(e)MG\(e)[4;1H\(e)[10AH\(e)[10BI\(e)[7;1H\(e)[5AJ",
        "\(e)[5;3r\(e)[0;0rK\(e)[2;99rL\(e)[4;4rM\(e)[3;8r\(e)[8;1H\n\nN\(e)[rO\(e)D\(e)E\(e)M")))
    cases.append(Case("origin_mode", 10, 8, "\(e)[3;6r\(e)[?6hA\(e)[2;2HB\(e)[99;1HC\(e)[6n\(e)[?6n\(e)[5AD\(e)[2dE\(e)7\(e)[?6l\(e)[1;1HF\(e)[6n\(e)8G\(e)[6n"))
    cases.append(Case("insert_delete_chars", 12, 6,
        "abcdefghij\r\(e)[2C\(e)[2@\r\n" + "abcdefghij\r\(e)[3C\(e)[3P\r\n" + "abcdefghij\r\(e)[4C\(e)[2X\r\n" +
        "\(e)[41m终端终端终端\r\(e)[1C\(e)[1@\r\n终端终端终端\r\(e)[3C\(e)[2P\(e)[m\r\n终端终端终端\r\(e)[1C\(e)[2X\(e)[99@\(e)[5G\(e)[99P\(e)[99X"))
    cases.append(Case("insert_delete_lines", 6, 8,
        j((1...8).map { "L\($0)" }.joined(separator: "\r\n"), "\(e)[2;3H\(e)[2L\(e)[5;2H\(e)[M\(e)[3;6r\(e)[4;1H\(e)[42m\(e)[L\(e)[99M\(e)[1;1H\(e)[L\(e)[8;1H\(e)[M\(e)[4;3H\(e)[99L")))
    cases.append(Case("erase", 10, 8,
        j((0..<8).map { _ in "0123456789" }.joined(), "\(e)[1;5H\(e)[K\(e)[2;5H\(e)[1K\(e)[3;5H\(e)[2K\(e)[44m\(e)[4;5H\(e)[0K\(e)[5;10H\(e)[1K",
        "\(e)[6;3H\(e)[?K\(e)[7;3H\(e)[?1K\(e)[8;5H\(e)[J\(e)[1;3H\(e)[1J\(e)[3K\(e)[m")))
    cases.append(Case("erase_display", 6, 4, scrollback: 50, [
        .text((0..<12).map { "ln\($0)" }.joined(separator: "\r\n")), .snapshot, .text("\(e)[3J"), .snapshot,
        .text("\(e)[45m\(e)[2J"), .snapshot, .text("\(e)[mAAAAAABBBBBBCCCCCC\(e)[2;3H\(e)[?J\(e)[3;3H\(e)[?1J\(e)[9J"),
    ]))
    cases.append(Case("erase_wide", 10, 6,
        "终端终端终\r\(e)[1C\(e)[K\r\n终端终端终\r\(e)[3C\(e)[1K\r\n终端终端终\r\(e)[1C\(e)[4X\r\n终端终端终\(e)[3Gab\r\n终端终端终\(e)[2Gabc\r\n终端终端终\(e)[2G语"))
    cases.append(Case("tabs", 30, 8,
        "a\tb\tc\td\te\r\n\(e)[3g\(e)[5G\(e)H\(e)[12G\(e)H\ra\tb\tc\td\r\n\(e)[5G\(e)[g\ra\tb\tc\r\n\(e)[25G\(e)H\(e)[2Ix\(e)[2Zy\(e)[99Zz\(e)[99Iw\r\n" +
        "\(e)[30Gq\tp\r\n\(e)[0Io\(e)[0Zn\(e)[1g\(e)[2g\(e)[4g"))
    cases.append(Case("tabs_resize", 20, 3, [.text("\(e)[3g\(e)[4G\(e)H\(e)[19G\(e)H\ra\tb\tc"), .resize(40, 3), .text("\r\na\tb\tc\td\te\tf"), .resize(10, 3), .text("\r\na\tb\tc")]))

    cases.append(Case("alternate_screen", 12, 4, [
        .text("main text\r\nsecond\(e)[31m"), .text("\(e)[?1049h"), .snapshot, .text("alt\(e)[2;2Hscreen\(e)7\(e)[44m"), .snapshot,
        .text("\(e)[?1049l"), .snapshot, .text("X\(e)[?47hA47\(e)[?47l\(e)[?47hB\(e)[?47l"), .text("\(e)[?1047hC1047\(e)[?1047l\(e)[?1047hD"), .snapshot,
        .text("\(e)[?1049hE\(e)[?1049hF\(e)8G\(e)[?1047l\(e)[?1049lH\(e)[?1048h\(e)[3;3HI\(e)[?1048lJ"),
    ]))
    cases.append(Case("alternate_scroll", 6, 3, "\(e)[?1049h1\r\n2\r\n3\r\n4\r\n5\(e)[?1049l\r\nm1\r\nm2\r\nm3\r\nm4"))
    cases.append(Case("saved_cursor", 12, 6,
        "\(e)[2;3H\(e)[1;35m\(e)(0\(e)7\(e)[m\(e)(B\(e)[5;5Hqq\(e)8qq\(e)[s\(e)[1;1H\(e)[uX\(e)[3;6r\(e)[?6h\(e)[2;2H\(e)7\(e)[?6l\(e)[r\(e)8Y\(e)[6n" +
        "\(e)[1;12HZZ\(e)7\(e)[1;1H\(e)8W\(e)[!p\(e)8V"))
    cases.append(Case("saved_cursor_none", 12, 4, "abc\(e)8X\(e)[5;5H\(e)[uY\(e)[?1049h\(e)[3;3H\(e)8Z"))
    cases.append(Case("saved_cursor_resize", 5, 4, [
        .text("abcde\(e)7\r\n"), .resize(10, 4), .text("\(e)8X\(e)[9G\(e)7"), .resize(5, 4), .text("\(e)8Y\r\nabcde\(e)7"), .resize(3, 4), .text("\(e)8Z"),
        .resize(6, 2), .text("\(e)[2;6H\(e)7\(e)[?1049hq"), .resize(4, 1), .text("\(e)[?1049lW"),
    ]))
    // Enough history to fill and free whole pages of the packed scrollback.
    cases.append(Case("scrollback_pages", 40, 3, scrollback: 300,
        (0..<1300).map { "\(e)[3\($0 % 8)m\($0)\(e)[m history line \($0 % 7 == 0 ? "终端 e\u{301}" : "plain")" }.joined(separator: "\r\n")))
    cases.append(Case("charsets", 40, 6,
        j("\(e)(0", String(decoding: Array(UInt8(0x5F)...UInt8(0x7E)), as: UTF8.self), "ABC^\(e)(B\r\n",
        "\(e))0ab\u{0E}lqqk\u{0F}ab\u{0E}x\(e)[3b\u{0F}\r\n\(e)(0q\(e)[4b\(e)(Bq\(e)[2b\r\n\(e)(Aa\(e))Bb\u{0E}c\u{0F}\(e)(0\(e)[!pqq\(e)(0é终q")))
    cases.append(Case("rep", 10, 5, "\(e)[3ba\(e)[3b\(e)[0b终\(e)[2b\r\ne\u{301}\(e)[2b\r\nx\(e)[25b\r\n\(e)[2bY\(e)[70000b"))
    cases.append(Case("decaln", 7, 4, "\(e)[41mab终\r\n\(e)[2;3r\(e)#8\(e)[3;4Hx\(e)#3\(e)#9"))
    cases.append(Case("insert_mode", 10, 5, "abcdef\r\(e)[4hXY\r\n终端终端终\r\(e)[1C语\r\nabcdefghij\r\(e)[9Cz\r\n\(e)[4labc\r\(e)[4h\u{301}e\u{301}\(e)[4lZ\(e)[4$p\(e)[20$p\(e)[7$p"))
    cases.append(Case("linefeed_mode", 8, 5, "ab\ncd\(e)[20hef\ngh\u{0B}ij\u{0C}kl\(e)[20$p\(e)[20lmn\nop\(e)[20$p"))

    cases.append(Case("wide_chars", 9, 8,
        "终端渲染器使用图形处理器绘制\r\na终b端c\r\n한국어 텍스트\r\nｆｕｌｌ　ｗｉｄｔｈ\r\n12345678终\r\n\(e)[?7l12345678终终\(e)[?7h\r\n终\u{8}x\r\n终\u{8}\u{8}y"))
    cases.append(Case("wide_resize", 8, 3, [.text("终端终端\r\n1终端终x\r\nab终cd"), .resize(5, 3), .snapshot, .resize(3, 3), .text("z"), .resize(9, 2), .text("终终")]))
    cases.append(Case("emoji", 16, 10,
        "👨\u{200D}👩\u{200D}👧!\r\n👩\u{200D}💻 dev\r\n👍🏽👍\u{1F3FB}x\r\n❤\u{FE0F}❤\u{FE0E}☺\u{FE0F}y\r\n🇧🇷🇯🇵z\r\n1\u{FE0F}\u{20E3}#\u{FE0F}\u{20E3}w\r\n🏳\u{FE0F}\u{200D}🌈v\r\n" +
        "🚀✨🔥⏺⎿❯✻✳⏵▐▛█▜▌\r\n\u{200D}a\u{200D}b\u{200D}\u{301}c\u{200D}\r\nd\r\n©®™✓✗→⇒☀☁⚡⭐"))
    cases.append(Case("combining", 8, 10,
        "e\u{301}clair nai\u{308}ve\r\n\u{301}x\r\n1234567e\u{301}\u{302}\u{303}\r\n12345678\u{301}Z\r\n终\u{301}a\u{20DD}\r\n" +
        "\u{1100}\u{1161}\u{11A8} 한\r\na\u{300}\u{300}\u{300}a\u{300}\u{300}\u{300}b\u{300}\r\n\(e)[5C\u{301}q\r\nक\u{94D}ष \u{0903}x\u{AD}y\u{600}z\u{0D4E}w\r\n\u{FEFF}a\u{2060}b\u{E0100}c\u{1D167}"))
    cases.append(Case("combining_wrap", 4, 4, "abcd\u{301}e\u{302}\r\n终终\u{301}终\u{302}\r\nabc终\u{303}"))

    cases.append(Case("scrollback_overflow", 30, 4, scrollback: 25,
        (0..<120).map { j("\(e)[3\($0 % 8)mline \($0)\(e)[0m \(e)[1mbold\(e)[22m ", String(repeating: "w", count: $0 % 37)) }.joined(separator: "\r\n")))
    cases.append(Case("scrollback_none", 10, 3, scrollback: 0, (0..<10).map { "l\($0)" }.joined(separator: "\r\n")))
    cases.append(Case("scrollback_wide_styles", 14, 3, scrollback: 40,
        j((0..<30).map { "\(e)[48;2;\($0);\($0 * 2);\($0 * 3)m终\($0)\(e)[4:3me\u{301}\(e)[m 👩\u{200D}💻\(e)[K" }.joined(separator: "\r\n"), "\r\n")))
    let filler: String = (0..<40).map { "\(e)[3\($0 % 7 + 1)m\($0) the quick brown fox jumps over the lazy dog\(e)[m 终端" }.joined(separator: "\r\n")
    cases.append(Case("resize_main", 30, 8, scrollback: 200, [
        .text(filler), .snapshot, .resize(20, 5), .snapshot, .text("\r\nnarrow now and wrapping again"), .resize(50, 12), .snapshot,
        .text("\r\nwide"), .resize(50, 3), .resize(8, 20), .text("\r\nx\r\ny"), .resize(30, 8), .text("\(e)[2;3r\(e)[3g"), .resize(31, 8), .text("\tend"),
    ]))
    cases.append(Case("resize_alternate", 20, 6, [
        .text("one\r\ntwo\r\nthree\r\nfour\r\nfive\(e)[?1049h\(e)[6;1Hbottom\(e)[1;1Htop\(e)[6;7H"), .resize(12, 3), .snapshot,
        .text("X"), .resize(25, 9), .text("\(e)[9;1Hlow"), .resize(25, 4), .text("\(e)[?1049lback"), .resize(10, 2), .text("!"),
    ]))
    cases.append(Case("resize_cursor_top", 10, 6, [.text("a\r\nb\(e)[1;1H"), .resize(10, 2), .text("X"), .resize(4, 9), .text("12345")]))

    let allModes = [1, 5, 6, 7, 9, 12, 25, 47, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1047, 1048, 1049, 2004, 2026, 3, 8, 1001, 2027]
    cases.append(Case("modes_set", 20, 5, [
        .text(allModes.filter { ![47, 1047, 1049].contains($0) }.map { "\(e)[?\($0)h" }.joined()), .snapshot,
        .text(j(allModes.map { "\(e)[?\($0)$p" }.joined(), "\(e)[4h\(e)[20h\(e)=")), .snapshot,
        .text("\(e)[?1;5;6;7l\(e)[?25;12l\(e)[?2004l\(e)>\(e)[4;20l"), .snapshot,
        .text(allModes.map { "\(e)[?\($0)l\(e)[?\($0)$p" }.joined()),
    ]))
    cases.append(Case("modes_alternate_queries", 20, 5, "\(e)[?1049h\(e)[?47$p\(e)[?1047$p\(e)[?1049$p\(e)[?1049l\(e)[?1049$p\(e)[?1049;2004;1h\(e)[?1049$p\(e)[?2004$p"))
    let mouseModes = [9, 1000, 1002, 1003], encodings = [1005, 1006, 1015, 1016]
    let mouseQueries = (mouseModes + encodings).map { "\(e)[?\($0)$p" }.joined()
    var mouseSteps: [Step] = []
    for mode in mouseModes + encodings {
        mouseSteps += [.text("\(e)[?\(mode)h"), .snapshot, .text(j(mouseQueries, "\(e)[?\(mode)l")), .snapshot]
    }
    mouseSteps += [.text("\(e)[?1003h\(e)[?1006h"), .snapshot, .text("\(e)[?1000l\(e)[?1015l")]
    cases.append(Case("mouse_modes", 20, 5,
        mouseSteps))
    var shapeSteps: [Step] = []
    for shape in 0...7 { shapeSteps += [.text("\(e)[\(shape) q"), .snapshot] }
    shapeSteps.append(.text("\(e)[ q\(e)[5 q\(e)[?25l"))
    cases.append(Case("cursor_shapes", 10, 3, shapeSteps))
    cases.append(Case("soft_and_full_reset", 12, 5, [
        .text("\(e)]2;titled\u{07}\(e)[?1;6;7;25;1004;2004;1002;1006h\(e)[4h\(e)=\(e)[2;4r\(e)[1;31;44m\(e)(0\(e)7\(e)[3g\(e)[4 qtext"), .snapshot,
        .text("\(e)[!p"), .snapshot, .text("after\(e)[?1049h\(e)[?7l\(e)[5 q\(e)[41malt\(e)7"), .snapshot, .text("\(e)c"), .snapshot, .text("fresh\ttab"),
    ]))

    cases.append(Case("osc_title_cwd", 20, 3, [
        .text("\(e)]0;✳ Claude Code\u{07}"), .snapshot, .text("\(e)]2;second title\(e)\\\(e)]7;file:///Users/me/proj\u{07}"), .snapshot,
        .text("\(e)]1;icon only\u{07}\(e)]2;\u{07}"), .snapshot, .text("\(e)]0;cancelled\u{18}\(e)]0;escaped\(e)[1mX\(e)]7;\(e)\\"),
        .text("\(e)]2;no separator title"), .text("\u{07}\(e)]2\u{07}\(e)]+2;plus\u{07}\(e)]-0;minus\u{07}\(e)]02;zeros\u{07}\(e)] 2;space\u{07}\(e)]2x;bad\u{07}"),
        .text("\(e)]99999999999999999999;overflow\u{07}\(e)]2;a;b;c\u{07}\(e)]0;tab\there\nnewline\u{07}"),
    ]))
    cases.append(Case("osc_invalid_utf8", 20, 3, [
        .feed([0x1B, 0x5D, 0x32, 0x3B, 0x61, 0xFF, 0x62, 0xC0, 0xAF, 0x63, 0xE0, 0x80, 0x64, 0xED, 0xA0, 0x80, 0x65, 0xF4, 0x90, 0x80, 0x80, 0x66,
               0xF0, 0x9F, 0x67, 0x80, 0x68, 0xE2, 0x82, 0x07]),
        .feed([0x1B, 0x5D, 0x37, 0x3B, 0xF0, 0x9F, 0x98, 0x80, 0xF0, 0x9F, 0x98, 0xC3, 0xA9, 0xF8, 0x88, 0x80, 0x80, 0x80, 0xE1, 0x80, 0xE2, 0x07]),
        .feed([0x1B, 0x5D, 0x39, 0x3B, 0xC3, 0x28, 0xA0, 0xA1, 0xF0, 0x28, 0x8C, 0xBC, 0x07, 0x1B, 0x5D, 0xC3, 0xA9, 0x3B, 0x78, 0x07]),
    ]))
    cases.append(Case("osc_notifications", 20, 3,
        "\(e)]9;Claude needs input\(e)\\\(e)]9;4;1;50\u{07}\(e)]9;4\u{07}\(e)]9;\u{07}\(e)]9\u{07}\(e)]9;4;\u{301}joined\u{07}\(e)]9;4\u{37E}greek\u{07}\(e)]9;4\u{301};mark\u{07}" +
        "\(e)]9;4;é later\u{07}\(e)]9;é 4;x\u{07}\(e)]9;\u{600}4;prepend\u{07}" +
        "\(e)]777;notify;Title;Body text\u{07}\(e)]777;notify;Only title\u{07}\(e)]777;notify\u{07}\(e)]777;notify;a;b;c;d\u{07}\(e)]777;notify;;empty\u{07}" +
        "\(e)]777;other;a;b\u{07}\(e)]777;notify\u{301};a;b\u{07}\(e)]777;notify;a;\u{301}b;c\u{07}\(e)]777;notify\u{37E}g\u{37E}h\u{37E}i\u{07}\(e)]777;notify;a\u{600};b;c\u{07}" +
        "\(e)]777;notify;é;ü\u{07}\(e)]777;\u{07}\(e)]777;notify;a;\u{200D};b\u{07}\(e)]777;notify;x;\r\ny\u{07}\u{07}\u{07}\(e)]9;after bells\u{07}\(e)]777;Notify;x\u{07}\(e)]777;notify;a\u{0D4E};b\u{07}"))
    cases.append(Case("osc_colors", 20, 3,
        "\(e)]10;?\u{07}\(e)]11;?\(e)\\\(e)]12;?\u{07}\(e)]11;??\u{07}\(e)]11;?\u{301}\u{07}\(e)]11;rgb:00/00/00\u{07}\(e)]11\u{07}\(e)]10;?;?\u{07}\(e)]11;?é\u{07}\(e)]11;é?\u{07}" +
        "\(e)]4;1;?\u{07}\(e)]13;?\u{07}\(e)]11;?\u{200D}\u{07}\(e)]10;?\u{0903}\u{07}\(e)]8;;http://x\u{07}link\(e)]8;;\u{07}\(e)]52;c;?\u{07}\(e)]133;A\u{07}"))
    cases.append(Case("device_queries", 20, 6,
        "\(e)[c\(e)[0c\(e)[1c\(e)[>c\(e)[>0c\(e)[>1c\(e)[=c\(e)Z\(e)[5n\(e)[6n\(e)[4;7H\(e)[6n\(e)[?6n\(e)[?5n\(e)[7n\(e)[18t\(e)[14t\(e)[18;1t\(e)[>0q\(e)[?u\(e)[>4;2m" +
        "\(e)P$qm\(e)\\\(e)P+q544e\(e)\\\(e)P1$qr\(e)\\\(e)P$q\u{18}\(e)P$$qm\(e)\\\(e)P>|x\(e)\\\(e)Pq#0;2\(e)\\\(e)P+q\u{07}after\u{1A}\(e)P?$qm\(e)\\" +
        "\(e)[20Gxx\(e)[6n\(e)[$p\(e)[99$p\(e)[?$p\(e)[?0$p\(e)[?70000$p\(e)[?1;2$p\(e)[5;6n\(e)[6;5n"))
    cases.append(Case("parser_edges", 30, 8, [
        .text("a\(e)[3\u{18}b\(e)[3\u{1A}c\(e)[1\(e)[2Cd\(e)[\r2Ce\(e)[\n\(e)[3\u{8}Cf\(e)[?1;2\u{7F}Cg\r\n"),
        .text("\(e)[1?2Ch\(e)[1 2Ci\(e)[  @j\(e)[<1Ck\(e)[=1Cl\(e)[>1Cm\(e)[?<1Cn\(e)[1;2;3;4$~o\(e)[!!pp\r\n"),
        .text("\(e)Xsos string\(e)\\q\(e)^pm\(e)\\r\(e)_apc\u{07}still\(e)\\s\(e)\u{7F}Dt\(e) Fu\(e)%Gv\(e)(\u{7F}0q\(e)  0w\r\n"),
        .feed([0x78, 0xC2, 0x9B, 0x33, 0x31, 0x6D, 0x79, 0xC2, 0x85, 0x7A, 0xC2, 0x80, 0xC2, 0x9F, 0xC2, 0xA0, 0xC2, 0xAD, 0x7C, 0x0D, 0x0A]),
        .text("\(e)[99999999999999999999Ca\r\(e)[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;33;34;35Hb"),
        .text("\(e)[5;;5H*\(e)[;;;H*\(e)[:5:H*\(e)[1:2:3T\(e)[1;2T\(e)[2T\(e)\(e)\(e)[31mc\u{18}\u{18}\u{1A}d\(e)P1;2;3|pay\u{7F}load\(e)\\e\(e)P 1q\(e)\\f\(e)P1 qx\(e)\\g"),
        .text("\(e)]2;t\(e)]0;u\u{07}\(e)P$q\(e)]2;v\u{07}\(e)[\(e)]2;w\(e)\\\(e)]2;keep\u{1A}x\(e)]2;keep2\(e)x"),
    ]))
    cases.append(Case("utf8_invalid", 30, 4, [
        .feed([0x61, 0xFF, 0x62, 0xE2, 0x82, 0x63, 0xC0, 0xAF, 0x64, 0xC1, 0xBF, 0x65, 0xE0, 0x80, 0x80, 0x66, 0xED, 0xA0, 0x80, 0x67, 0xF4, 0x90, 0x80, 0x80, 0x68]),
        .feed([0xF0, 0x80, 0x80, 0x80, 0x69, 0xF5, 0x80, 0x6A, 0x80, 0xBF, 0x6B, 0xF0, 0x9F, 0x98, 0x1B, 0x5B, 0x43, 0x6C, 0xE2, 0x82, 0x0D, 0x0A]),
        .feed([0xEF, 0xBF, 0xBD, 0xEF, 0xBF, 0xBE, 0xEF, 0xBF, 0xBF, 0xF4, 0x8F, 0xBF, 0xBF, 0xF3, 0xA0, 0x80, 0x81, 0xEE, 0x80, 0x80, 0xF0, 0x90, 0x80, 0x80, 0xE2, 0x82]),
        .snapshot,
        .feed([0xAC, 0xF0, 0x9F]), .snapshot, .feed([0x98, 0x80, 0xF0, 0x9F, 0x98]),
    ]))

    // A snapshot at every byte of a stream that has every kind of sequence in it.
    let stream = Array(j("\(e)[38;2;200;100;50mcolored\(e)[0m 日本 e\u{301} 👩\u{200D}💻 \(e)]2;new title\u{07}\(e)[4:3mu\(e)[?1049h\(e)[3;5Halt\(e)P1$qm\(e)\\",
                        "\(e)(0lqk\(e)(B\(e)[?1049l done \(e)[5Dend\(e)]777;notify;a;b\(e)\\\(e)[6n\(e)[ q\(e)#8\(e)[2;3r").utf8)
    var streamSteps: [Step] = []
    for byte in stream { streamSteps += [.feed([byte]), .snapshot] }
    cases.append(Case("mid_sequence", 30, 5, streamSteps))
    cases.append(Case("mid_osc_and_dcs", 20, 3, [
        .text("\(e)]2;half a ti"), .snapshot, .text("tle\(e)"), .snapshot, .text("\\\(e)P1;2$q pay"), .snapshot, .text("load\(e)\\\(e)[1;3"), .snapshot,
        .text("8:2::1:"), .snapshot, .text("2:3mX\(e)"), .snapshot, .text("(0\(e)("), .snapshot, .text("Bq\(e)[?"), .snapshot, .text("25l\(e)X ignored"), .snapshot, .text(" still\(e)\\Y"),
    ]))
    return cases
}

/// A fullscreen agent TUI in the style of `Benchmarks/Sources/ClaudeSim`: header, transcript,
/// spinner, prompt between two rules and a status line, repainted with cursor addressing.
private func agentScreen(cols: Int, rows: Int, frames: Int) -> [UInt8] {
    var rng = SplitMix64(state: 7)
    let words = ["render", "the", "terminal", "grid", "with", "ação", "终端", "snapshot", "→", "`code`", "tokens", "e\u{301}", "✓"]
    var transcript: [String] = []
    var out = "\(e)[?1049h\(e)[?25l\(e)[?2004h\(e)[?1004h\(e)[?1003h\(e)[?1006h\(e)[>1u\(e)[c\(e)]0;✳ Agent\u{07}"
    let spinner = ["✻", "✳", "✶", "✢", "·"]
    for frame in 0..<frames {
        out += "\(e)[?2026h"
        if frame == 0 {
            out += "\(e)[2J\(e)[1;1H \(e)[38;2;215;119;87m▐▛███▜▌\(e)[39m   \(e)[1mAgent Code\(e)[22m \(e)[2mv2.1\(e)[22m"
            out += "\(e)[2;1H\(e)[38;2;215;119;87m▝▜█████▛▘\(e)[39m  \(e)[2m~/projects/board\(e)[22m"
        }
        if frame % 3 == 0 {
            var line = rng.int(0...3) == 0 ? "\(e)[38;5;114m⏺\(e)[39m \(e)[1mBash\(e)[22m(swift build)" : "\(e)[38;5;231m⏺\(e)[39m "
            for _ in 0..<rng.int(3...9) { line += rng.pick(words) + " " }
            transcript.append(line)
            if rng.int(0...2) == 0 { transcript.append("  \(e)[2m⎿ \(e)[22m \(e)[38;5;246m\(rng.int(1...400)) lines (ctrl+o to expand)\(e)[39m") }
        }
        let room = rows - 8
        for (index, line) in transcript.suffix(room).enumerated() { out += "\(e)[\(4 + index);1H\(line)\(e)[K" }
        out += "\(e)[\(rows - 4);1H\(e)[38;2;215;119;87m\(spinner[frame % spinner.count])\(e)[39m \(e)[38;2;215;119;87mPondering…\(e)[39m \(e)[2m(\(frame)s · ↑ \(frame * 37) tokens · esc to interrupt)\(e)[22m\(e)[K"
        out += j("\(e)[\(rows - 3);1H\(e)[2m", String(repeating: "─", count: cols), "\(e)[22m")
        out += j("\(e)[\(rows - 2);1H❯\u{a0}", String("explain how the render works".prefix(frame)), "\(e)[7m \(e)[27m\(e)[K")
        out += j("\(e)[\(rows - 1);1H\(e)[2m", String(repeating: "─", count: cols), "\(e)[22m")
        out += "\(e)[\(rows);1H\(e)[2m  ? for shortcuts\(e)[\(rows);\(cols - 18)H\(frame % 100)% context left\(e)[22m\(e)[?2026l"
    }
    return Array(out.utf8)
}

/// The same program drawing inline on the main screen: output scrolls into history and the
/// live area at the bottom is rewritten by moving the cursor up.
private func inlineSession(lines: Int) -> [UInt8] {
    var rng = SplitMix64(state: 11)
    var out = "\(e)]7;file:///Users/me/board\u{07}\(e)]133;A\u{07}\(e)[1;34m~/board\(e)[0m \(e)[32m❯\(e)[0m ls --color\r\n"
    let names = ["Package.swift", "Sources", "Tests", "README.md", "core", "docs", "日本語.txt", "build.sh"]
    for index in 0..<lines {
        if index % 5 == 0 {
            out += j(names.map { "\(e)[\($0.contains(".") ? "0" : "1;36")m\($0)\(e)[0m" }.joined(separator: "  "), "\r\n")
        } else {
            let listed = (0..<rng.int(2...14)).map { _ in rng.pick(names) }.joined(separator: " ")
            out += "\(e)[38;5;\(rng.int(16...231))m\(index)\(e)[39m\t\(listed)\r\n"
        }
        if index % 7 == 3 {
            out += "\(e)[2m⠋ working \(index)\(e)[22m\r\n\(e)[2m  step two\(e)[22m\(e)[1A\(e)[2K\(e)[G\(e)[32m✔ done \(index)\(e)[39m\r\n\(e)[2K"
        }
    }
    out += "\(e)[?2004h\(e)[1;34m~/board\(e)[0m \(e)[32m❯\(e)[0m "
    return Array(out.utf8)
}

/// Seeded noise, biased toward escape sequences and the parameters this terminal acts on.
private func fuzzStream(seed: UInt64, length: Int) -> [UInt8] {
    var rng = SplitMix64(state: seed)
    var out: [UInt8] = []
    let samples = ["ação", "终端渲染", "🚀", "👩\u{200D}💻", "e\u{301}", "│─┼", "한국", "\u{FE0F}", "\u{200D}", "👍🏽", "ｗ", "\u{301}\u{302}", "🇧🇷", "⏺ ❯"]
    let numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 18, 20, 21, 24, 25, 38, 47, 48, 58, 66, 100, 255, 256, 1000, 1002, 1003, 1004, 1005, 1006,
                   1007, 1015, 1016, 1047, 1048, 1049, 2004, 2026, 9999, 65535, 70000]
    let modes = [1, 5, 6, 7, 9, 12, 25, 47, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1047, 1048, 1049, 2004, 2026]
    let finals = Array("@ABCDEFGHIJKLMPSTXZ`abcdefghlmnpqrstu".utf8)
    func add(_ text: String) { out += Array(text.utf8) }
    func number() -> String { rng.int(0...5) == 0 ? "" : rng.int(0...2) == 0 ? "\(rng.pick(numbers))" : "\(rng.int(0...30))" }
    while out.count < length {
        switch rng.int(0...99) {
        case 0..<22:
            for _ in 0..<rng.int(1...40) { out.append(UInt8(rng.int(0x20...0x7E))) }
        case 22..<30:
            add(rng.pick(samples))
        case 30..<50:
            var sequence = "\(e)[" + rng.pick(["", "", "", "", "?", ">", "=", "<"])
            let count = rng.int(0...5)
            for index in 0..<count { sequence += number() + (index == count - 1 ? "" : rng.int(0...6) == 0 ? ":" : ";") }
            sequence += rng.pick(["", "", "", "", "", " ", "$", "!", "#"])
            add(sequence)
            out.append(rng.int(0...9) == 0 ? UInt8(rng.int(0x40...0x7E)) : rng.pick(finals))
        case 50..<60:
            var sequence = "\(e)["
            for _ in 0..<rng.int(0...4) {
                sequence += rng.pick(["0", "1", "2", "3", "4", "4:3", "4:2", "7", "9", "21", "22", "24", "27", "53", "55", "39", "49",
                                      "3\(rng.int(0...7))", "4\(rng.int(0...7))", "9\(rng.int(0...7))", "10\(rng.int(0...7))",
                                      "38;5;\(rng.int(0...300))", "48;5;\(rng.int(0...255))", "38;2;\(rng.int(0...255));\(rng.int(0...255));\(rng.int(0...255))",
                                      "48:2::\(rng.int(0...255)):\(rng.int(0...255)):\(rng.int(0...255))", "38:5:\(rng.int(0...255))", "38;2;1", "58;5;1", ""]) + ";"
            }
            add(sequence + "\(rng.int(0...9))m")
        case 60..<66:
            add("\(e)[?\(rng.pick(modes))\(rng.int(0...1) == 0 ? "h" : "l")")
        case 66..<72:
            out.append(rng.pick([0x07, 0x08, 0x08, 0x09, 0x09, 0x0A, 0x0A, 0x0D, 0x0D, 0x0B, 0x0C, 0x0E, 0x0F, 0x18, 0x1A, 0x7F, 0x00]))
        case 72..<78:
            add("\r\n")
        case 78..<84:
            add(e)
            out.append(rng.pick(Array("78DEHMM=>Z()#DE78c".utf8)))
            if rng.int(0...1) == 0 { out.append(rng.pick(Array("0B8A".utf8))) }
        case 84..<90:
            add("\(e)]" + rng.pick(["0", "2", "7", "9", "10", "11", "12", "777", "8", "52", "133", "", "x"]) + rng.pick([";", ";", ";", ""]))
            add(rng.pick(["?", "notify;a;b", "notify;" + rng.pick(samples), "4;1;50", "title " + rng.pick(samples), "file:///tmp/x", "", "?" + rng.pick(samples), "a;b"]))
            if rng.int(0...4) == 0 { out.append(UInt8(rng.int(0x80...0xFF))) }
            add(rng.pick(["\u{07}", "\u{07}", "\(e)\\", "\(e)\\", "\u{18}", ""]))
        case 90..<93:
            add("\(e)P\(number())" + rng.pick(["$q", "+q", "q", "1$r", "$", ""]) + rng.pick(["m", "544e", "", "\" q"]) + rng.pick(["\(e)\\", "\(e)\\", "\u{07}", ""]))
        case 93..<97:
            for _ in 0..<rng.int(1...6) { out.append(UInt8(rng.int(0...255))) }
        default:
            add("\(e)[\(rng.int(0...45));\(rng.int(0...130))H")
        }
    }
    return out
}

private func fuzzCase(_ name: String, seed: UInt64, cols: Int, rows: Int, scrollback: Int, length: Int) -> Case {
    var rng = SplitMix64(state: seed &* 31 &+ 5)
    let stream = fuzzStream(seed: seed, length: length)
    var steps: [Step] = []
    var offset = 0
    while offset < stream.count {
        let end = min(stream.count, offset + rng.int(1...200))
        steps.append(.feed(Array(stream[offset..<end])))
        offset = end
        switch rng.int(0...39) {
        case 0: steps.append(.resize(rng.int(2...100), rng.int(1...40)))
        case 1, 2: steps.append(.snapshot)
        default: break
        }
    }
    return Case(name, cols, rows, scrollback: scrollback, steps)
}

// MARK: Writing

private func write(_ fixture: Case, to directory: URL) throws {
    let terminal = Terminal(cols: fixture.cols, rows: fixture.rows, scrollback: fixture.scrollback)
    var manifest = "size \(fixture.cols) \(fixture.rows) \(fixture.scrollback)\n"
    var input: [UInt8] = [], replies: [UInt8] = []
    var events = TerminalEvents()
    var snapshots = 0
    // Terminals restored from each snapshot, fed the rest alongside the original.
    var copies: [(terminal: Terminal, replies: [UInt8], since: Int)] = []
    func file(_ suffix: String) -> URL { directory.appendingPathComponent("\(fixture.name).\(suffix)") }
    for step in fixture.steps {
        switch step {
        case .feed(let bytes):
            terminal.feed(bytes)
            input += bytes
            manifest += "feed \(bytes.count)\n"
            replies += terminal.takeOutput() ?? []
            let taken = terminal.takeEvents()
            events.bells += taken.bells
            events.titleChanged = events.titleChanged || taken.titleChanged
            events.notifications += taken.notifications
            for index in copies.indices {
                copies[index].terminal.feed(bytes)
                copies[index].replies += copies[index].terminal.takeOutput() ?? []
            }
        case .resize(let cols, let rows):
            // `Terminal.resize` reads rows the main screen doesn't have when the cursor saved
            // on entering the alternate screen is below a screen that shrank since: skip those.
            if terminal.isAlternateScreen, (terminal.savedMain?.y ?? 0) >= terminal.rows { continue }
            terminal.resize(cols: cols, rows: rows)
            copies.forEach { $0.terminal.resize(cols: cols, rows: rows) }
            manifest += "resize \(cols) \(rows)\n"
        case .snapshot:
            let snapshot = terminal.snapshot()
            try Data(snapshot).write(to: file("snapshot.\(snapshots)"))
            let copy = Terminal(cols: 7, rows: 3, scrollback: fixture.scrollback)
            #expect(copy.restore(snapshot))
            copies.append((copy, [], replies.count))
            manifest += "snapshot \(replies.count)\n"
            snapshots += 1
        }
    }
    try Data(input).write(to: file("input"))
    try Data(manifest.utf8).write(to: file("steps"))
    let final = terminal.snapshot()
    try Data(final).write(to: file("snapshot"))
    // A copy ends where the original did, except for what a snapshot doesn't carry: history
    // lines are cut at the width they are saved at, which shows once a copy is made wider.
    for (number, copy) in copies.enumerated() {
        #expect(copy.replies == Array(replies[copy.since...]), "\(fixture.name): copy \(number) answered differently")
        let ended = copy.terminal.snapshot()
        if ended != final { try Data(ended).write(to: file("restored.\(number)")) }
    }
    try Data(replies).write(to: file("replies"))
    try Data(describe(terminal, events).utf8).write(to: file("expect"))
}

/// `start end value` (hex, inclusive) for every run of scalars where `value` isn't `skip`.
private func ranges(skipping skip: Int, _ value: (UInt32) -> Int) -> [String] {
    var lines: [String] = []
    var start: UInt32 = 0, current = value(0)
    for scalar in UInt32(1)...0x11_0000 {
        let next = scalar == 0x11_0000 ? Int.min : value(scalar)
        if next != current {
            if current != skip { lines.append(String(format: "%X %X %d", start, scalar - 1, current)) }
            start = scalar
            current = next
        }
    }
    return lines
}

struct SnapshotFixtures {
    @Test func writesGoldenFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("core/fixtures/terminal")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var cases = handWritten()
        let capture = try [UInt8](Data(contentsOf: root.appendingPathComponent("Benchmarks/corpus/claude-startup.rec")))
        var chunks: [Step] = []
        var index = 0
        while index + 8 <= capture.count {
            let length = Int(capture[index + 4]) | Int(capture[index + 5]) << 8
            index += 8
            chunks.append(.feed(Array(capture[index..<min(capture.count, index + length)])))
            if chunks.count % 6 == 0 { chunks.append(.snapshot) }
            index += length
        }
        cases.append(Case("claude_capture", 120, 40, scrollback: 5000, chunks))
        let screen = agentScreen(cols: 100, rows: 30, frames: 40)
        cases.append(Case("agent_fullscreen", 100, 30, scrollback: 5000,
                          split(Array(screen[..<(screen.count / 2)]), every: 97) + [.snapshot] + split(Array(screen[(screen.count / 2)...]), every: 1021) + [.resize(80, 24)]))
        let inline = inlineSession(lines: 90)
        cases.append(Case("agent_inline", 80, 24, scrollback: 5000,
                          split(Array(inline[..<(inline.count / 3)]), every: 211) + [.snapshot, .resize(60, 20)] + split(Array(inline[(inline.count / 3)...]), every: 64)))
        let sizes = [(80, 24, 5000), (40, 10, 50), (120, 40, 200), (10, 4, 20), (2, 1, 5), (33, 17, 0), (80, 24, 5000), (25, 60, 1000)]
        for (number, size) in sizes.enumerated() {
            cases.append(fuzzCase("fuzz_\(number)", seed: UInt64(number) + 1, cols: size.0, rows: size.1, scrollback: size.2, length: 24_000))
        }
        #expect(Set(cases.map(\.name)).count == cases.count)
        for fixture in cases { try write(fixture, to: directory) }

        // Column widths, as `CharacterWidth.of` answers for every code point.
        let widths = ranges(skipping: 1) { CharacterWidth.of($0) }
        try Data((widths.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("widths.txt"))

        // What the next or previous scalar does to string operations that see characters, not
        // bytes. Bit 1: it joins the `Character` of an ordinary scalar before it; bit 2: of one
        // after it (`hasPrefix`, `split`, `last`). Bit 4: Foundation doesn't find a line feed
        // (alone or after a carriage return) that has it next; bit 16: nor an end-of-paste marker.
        let plain = Terminal(cols: 10, rows: 2), bracketed = Terminal(cols: 10, rows: 2)
        bracketed.feed("\(e)[?2004h")
        var surprises = 0
        let graphemes = ranges(skipping: 0) { value in
            guard let scalar = Unicode.Scalar(value) else { return 0 }
            let text = String(Character(scalar))
            let joinsBefore = (";" + text).count == 1, joinsAfter = (text + ";").count == 1
            let hidesLineFeed = plain.encodePaste("\n" + text).first != 0x0D
            let hidesMarker = bracketed.encodePaste("\(e)[201~" + text).count > 12 + text.utf8.count
            // The port assumes these: a line feed is found whatever comes before it, and CR LF
            // is hidden by the same scalars as a lone line feed.
            if plain.encodePaste(text + "\n").last != 0x0D { surprises += 1 }
            if (plain.encodePaste("\r\n" + text).count > 1 + text.utf8.count) != hidesLineFeed { surprises += 1 }
            return (joinsBefore ? 1 : 0) | (joinsAfter ? 2 : 0) | (hidesLineFeed ? 4 : 0) | (hidesMarker ? 16 : 0)
        }
        #expect(surprises == 0)
        try Data((graphemes.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("graphemes.txt"))

        // `encodePaste` leans on Foundation's string search: `<input> <plain> <bracketed>`.
        let pastes: [String] = ["a\nb", "a\r\nb", "a\rb", "\r\r\n\n", "a\n\u{301}b", "a\r\n\u{301}b", "x\(e)[201~y", "x\(e)[201~\u{301}y", "\(e)[20\(e)[201~1~",
                      "\(e)[201\(e)[201~~", "e\u{301}\n", "", "\r\n\r\n", "\n\r", "a\u{200D}\nb", "\(e)\u{301}[201~", "x\(e)[201~\u{200D}y", "\u{600}\n",
                      "\r\u{301}\n", "\n\n\n", "x\(e)[201\u{37E}y", "x\(e)[201~\(e)[201~y", "\u{1F469}\u{200D}\u{1F4BB}\n终\r\n", "\(e)[200~inner\(e)[201~"]
            + ["\u{0903}", "\u{20DD}", "\u{FE0F}", "\u{1F3FB}", "\u{200C}", "\u{600}", "\u{1161}", "\u{E0020}", "\u{FF9E}", "\u{1F1E7}", "\u{0E33}", "\u{302A}", "é", "\u{3099}"]
                .flatMap { ["a\r\n\($0)b", "a\n\($0)b", "a\(e)[201~\($0)b", "\($0)\n\($0)\r\n\(e)[201~"] }
        var rng = SplitMix64(state: 99)
        let pieces = ["\n", "\n", "\r", "\r\n", "\r\n", "\(e)[201~", "\(e)[201~", "\(e)[20", "1~", "a", "é", "终", "\u{301}", "\u{363}", "\u{903}", "\u{E33}",
                      "\u{200D}", "\u{FE0F}", "\u{1F3FB}", "\u{600}", "\u{1161}", "\u{20DD}", "\u{94D}", "\u{D4E}", "👩", "\u{1100}", "\u{1F1E7}", "~", e]
        let random = (0..<1500).map { _ in (0..<rng.int(1...8)).map { _ in rng.pick(pieces) }.joined() }
        let pasted = (pastes + random).map { "\(hex($0)) \(hex(String(decoding: plain.encodePaste($0), as: UTF8.self))) \(hex(String(decoding: bracketed.encodePaste($0), as: UTF8.self)))" }
        try Data((pasted.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("paste.txt"))

        // `key <key> <modifiers> <application cursor> <bytes>`, keys numbered as below, then
        // `focus <enabled> <focused> <bytes>` and
        // `mouse <tracking> <encoding> <kind> <button> <column> <row> <modifiers> <bytes>`.
        var encoded: [String] = []
        let keys: [TerminalKey] = [.enter, .tab, .backspace, .escape, .delete, .insert, .up, .down, .left, .right, .home, .end, .pageUp, .pageDown]
            + (0...13).map { .function($0) }
        let typist = Terminal(cols: 10, rows: 2)
        for application in [false, true] {
            typist.feed(application ? "\(e)[?1h" : "\(e)[?1l")
            for (number, key) in keys.enumerated() {
                for modifiers in UInt8(0)..<8 {
                    let bytes = typist.encode(key, modifiers: KeyModifiers(rawValue: modifiers))
                    encoded.append("key \(number) \(modifiers) \(application) \(hex(String(decoding: bytes, as: UTF8.self)))")
                }
            }
        }
        for enabled in [false, true] {
            typist.feed(enabled ? "\(e)[?1004h" : "\(e)[?1004l")
            for focused in [false, true] {
                encoded.append("focus \(enabled) \(focused) \(typist.encodeFocus(focused).map { hex(String(decoding: $0, as: UTF8.self)) } ?? "none")")
            }
        }
        let kinds: [MouseEvent.Kind] = [.press, .release, .drag, .motion, .scrollUp, .scrollDown, .scrollLeft, .scrollRight]
        for tracking in UInt8(0)..<5 {
            for encoding in UInt8(0)..<5 {
                typist.mouseTracking = MouseTracking(rawValue: tracking)!
                typist.mouseEncoding = MouseEncoding(rawValue: encoding)!
                #expect(typist.wantsMouse == (tracking != 0))
                for (kind, value) in kinds.enumerated() {
                    for button in [0, 2] {
                        for modifiers in [UInt8(0), 5, 2] {
                            for (column, row) in [(0, 0), (4, 2), (94, 95), (222, 223), (300, 5), (2100, 1)] {
                                let event = MouseEvent(kind: value, button: button, column: column, row: row, modifiers: KeyModifiers(rawValue: modifiers))
                                // Raw bytes: the X10 encoding isn't UTF-8.
                                let bytes = typist.encodeMouse(event).map { $0.isEmpty ? "-" : $0.map { String(format: "%02x", $0) }.joined() } ?? "none"
                                encoded.append("mouse \(tracking) \(encoding) \(kind) \(button) \(column) \(row) \(modifiers) \(bytes)")
                            }
                        }
                    }
                }
            }
        }
        try Data((encoded.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("input.txt"))
    }
}
