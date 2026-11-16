//! What the fixtures in `tests/fixtures.rs` don't reach: the tables against the files they
//! were generated from, input encoding, cell-level reads, and snapshots Swift never wrote.

use std::fs;
use std::path::Path;

use crate::cell::{Cell, CellAttributes, CellWidth, TerminalColor};
use crate::input::{KeyModifiers, MouseEvent, MouseEventKind, TerminalKey};
use crate::terminal::{CursorShape, MouseEncoding, MouseTracking, Terminal};
use crate::unicode_tables::{GRAPHEMES, WIDTHS};

fn fixture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/terminal").join(name);
    fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error} (written by `swift test --filter SnapshotFixtures`)", path.display()))
}

fn unhex(text: &str) -> Vec<u8> {
    if text == "-" {
        return Vec::new();
    }
    (0..text.len()).step_by(2).map(|index| u8::from_str_radix(&text[index..index + 2], 16).unwrap()).collect()
}

fn terminal(cols: usize, rows: usize, input: &str) -> Terminal {
    let mut terminal = Terminal::with_scrollback(cols, rows, 100);
    terminal.feed(input.as_bytes());
    terminal
}

fn reply(terminal: &mut Terminal) -> String {
    String::from_utf8(terminal.take_output().unwrap_or_default()).unwrap()
}

// Tables

fn ranges(name: &str) -> Vec<(u32, u32, u8)> {
    fixture(name)
        .lines()
        .map(|line| {
            let fields: Vec<&str> = line.split(' ').collect();
            (u32::from_str_radix(fields[0], 16).unwrap(), u32::from_str_radix(fields[1], 16).unwrap(), fields[2].parse().unwrap())
        })
        .collect()
}

/// The compiled tables are the ones Swift wrote: widths for every code point, and what each
/// scalar does to Swift's and Foundation's string operations.
#[test]
fn tables_match_swift() {
    assert!(WIDTHS[..] == ranges("widths.txt")[..], "unicode_tables.rs is stale: regenerate WIDTHS from widths.txt");
    assert!(GRAPHEMES[..] == ranges("graphemes.txt")[..], "unicode_tables.rs is stale: regenerate GRAPHEMES from graphemes.txt");
    // Spot checks of the lookup itself, edges included.
    for (scalar, width) in [(0x41, 1), (0x7F, 0), (0x9F, 0), (0xA0, 1), (0xAD, 1), (0x300, 0), (0x36F, 0), (0x370, 1), (0x1100, 2), (0x115F, 2), (0x1160, 0)] {
        assert_eq!(crate::character_width::of(scalar), width, "U+{scalar:X}");
    }
    for (scalar, width) in [(0x7EC8, 2), (0x1F680, 2), (0x1F3FB, 0), (0x200D, 0), (0xFE0F, 0), (0x23FA, 1), (0xD800, 1), (0x10FFFF, 1), (0x11_0000, 1), (u32::MAX, 1)] {
        assert_eq!(crate::character_width::of(scalar), width, "U+{scalar:X}");
    }
}

#[test]
fn paste_matches_foundation() {
    let plain = terminal(10, 2, "");
    let bracketed = terminal(10, 2, "\x1b[?2004h");
    let cases = fixture("paste.txt");
    assert!(cases.lines().count() > 1000);
    for (number, line) in cases.lines().enumerate() {
        let fields: Vec<Vec<u8>> = line.split(' ').map(unhex).collect();
        let text = std::str::from_utf8(&fields[0]).unwrap();
        assert_eq!(plain.encode_paste(text), fields[1], "paste.txt line {}: {text:?}", number + 1);
        assert_eq!(bracketed.encode_paste(text), fields[2], "paste.txt line {} bracketed: {text:?}", number + 1);
    }
}

#[test]
fn keys_focus_and_mouse_match_swift() {
    use MouseEventKind::*;
    use TerminalKey::*;
    let keys = [Enter, Tab, Backspace, Escape, Delete, Insert, Up, Down, Left, Right, Home, End, PageUp, PageDown];
    let kinds = [Press, Release, Drag, Motion, ScrollUp, ScrollDown, ScrollLeft, ScrollRight];
    let cases = fixture("input.txt");
    let mut checked = 0;
    for line in cases.lines() {
        let fields: Vec<&str> = line.split(' ').collect();
        let number = |index: usize| fields[index].parse::<usize>().unwrap();
        let expected = fields.last().filter(|&&bytes| bytes != "none").map(|bytes| unhex(bytes));
        match fields[0] {
            "key" => {
                let key = keys.get(number(1)).copied().unwrap_or_else(|| Function((number(1) - keys.len()) as u8));
                let typist = terminal(10, 2, if fields[3] == "true" { "\x1b[?1h" } else { "" });
                assert_eq!(Some(typist.encode(key, KeyModifiers(number(2) as u8))), expected, "{line}");
            }
            "focus" => {
                let typist = terminal(10, 2, if fields[1] == "true" { "\x1b[?1004h" } else { "" });
                assert_eq!(typist.encode_focus(fields[2] == "true"), expected, "{line}");
            }
            "mouse" => {
                let mut typist = terminal(10, 2, "");
                typist.mouse_tracking = MouseTracking::from_raw(number(1) as u8).unwrap();
                typist.mouse_encoding = MouseEncoding::from_raw(number(2) as u8).unwrap();
                assert_eq!(typist.wants_mouse(), number(1) != 0);
                let event =
                    MouseEvent { kind: kinds[number(3)], button: number(4) as u8, column: number(5), row: number(6), modifiers: KeyModifiers(number(7) as u8) };
                assert_eq!(typist.encode_mouse(event), expected, "{line}");
            }
            other => panic!("input.txt: unknown line {other}"),
        }
        checked += 1;
    }
    assert!(checked > 5000);
}

// Cells (TerminalTests.swift: attributes, colors, Unicode, scrollback)

#[test]
fn basic_bright_and_extended_colors() {
    let t = terminal(10, 2, "\x1b[1;31;42mA\x1b[0;95;104mB\x1b[mC\x1b[38;5;208mD\x1b[38;2;215;119;87mE\x1b[38:2::1:2:3mF\x1b[48:5:17mG\x1b[38:2:9:8:7mH");
    let (a, b, c) = (t.cell(0, 0), t.cell(1, 0), t.cell(2, 0));
    assert!(a.attributes().contains(CellAttributes::BOLD) && a.foreground() == TerminalColor::palette(1) && a.background() == TerminalColor::palette(2));
    assert!(!b.attributes().contains(CellAttributes::BOLD) && b.foreground() == TerminalColor::palette(13) && b.background() == TerminalColor::palette(12));
    assert!(c.foreground().is_default() && c.background().is_default() && c.attributes().is_empty());
    assert_eq!(t.cell(3, 0).foreground(), TerminalColor::palette(208));
    assert_eq!(t.cell(4, 0).foreground(), TerminalColor::rgb(215, 119, 87));
    assert_eq!(t.cell(5, 0).foreground(), TerminalColor::rgb(1, 2, 3));
    assert_eq!(t.cell(6, 0).background(), TerminalColor::palette(17));
    assert_eq!(t.cell(7, 0).foreground(), TerminalColor::rgb(9, 8, 7));
}

#[test]
fn attributes_set_and_clear() {
    use CellAttributes as A;
    let t = terminal(10, 2, "\x1b[2;3;4;7;9mA\x1b[22;23;24;27;29mB\x1b[4:3mC\x1b[53mD");
    assert_eq!(t.cell(0, 0).attributes(), A::DIM.union(A::ITALIC).union(A::UNDERLINE).union(A::INVERSE).union(A::STRIKETHROUGH));
    assert!(t.cell(1, 0).attributes().is_empty());
    assert_eq!(t.cell(2, 0).attributes(), A::CURLY_UNDERLINE);
    assert_eq!(t.cell(3, 0).attributes(), A::CURLY_UNDERLINE.union(A::OVERLINE));
}

#[test]
fn erase_uses_current_background() {
    let t = terminal(5, 2, "\x1b[41m\x1b[2K");
    assert_eq!(t.cell(3, 0).background(), TerminalColor::palette(1));
    // xterm: EL at the wrap-pending position erases the last column too.
    let t = terminal(5, 2, "\x1b[41mabcde\x1b[0m\x1b[K");
    assert_eq!(t.screen_text(), ["abcd", ""]);
    assert!(t.cell(4, 0).background().is_default());
}

#[test]
fn wide_characters_and_clusters() {
    let t = terminal(10, 2, "a终b");
    assert_eq!(t.cell(1, 0).width(), CellWidth::Wide);
    assert_eq!(t.cell(2, 0).width(), CellWidth::Tail);
    assert_eq!(t.cursor().column, 4);
    assert_eq!(t.text_of(t.cell(2, 0)), None);

    let t = terminal(10, 2, "e\u{301}x👨\u{200D}👩\u{200D}👧!");
    assert!(t.cell(0, 0).is_cluster());
    assert_eq!(t.text_of(t.cell(0, 0)).as_deref(), Some("e\u{301}"));
    assert_eq!(t.text_of(t.cell(2, 0)).as_deref(), Some("👨\u{200D}👩\u{200D}👧"));
    assert_eq!(t.cell(4, 0).scalar(), '!' as u32);

    // Claude Code lays these out as one column each; disagreeing shifts its whole UI.
    assert_eq!(terminal(20, 2, "⏺⎿❯✻✳⏵▐▛█▜▌").cursor().column, 11);
}

#[test]
fn scrollback_packs_and_unpacks_styled_lines() {
    let mut t = Terminal::with_scrollback(12, 1, 10);
    t.feed("\x1b[1;38;2;1;2;3mab\x1b[0m 终\x1b[44mz\r\n".as_bytes());
    let (cells, wrapped) = t.scrollback().line(0, 12).unwrap();
    assert!(!wrapped && cells.len() == 12);
    assert!(cells[0].attributes().contains(CellAttributes::BOLD) && cells[0].foreground() == TerminalColor::rgb(1, 2, 3));
    assert!(cells[3].width() == CellWidth::Wide && cells[4].width() == CellWidth::Tail);
    assert_eq!(cells[5].background(), TerminalColor::palette(4));
    assert_eq!(cells[6], Cell::blank(0));
    // Narrower and wider reads of the same line.
    assert_eq!(t.scrollback().line(0, 2).unwrap().0.len(), 2);
    assert_eq!(t.scrollback().line(0, 40).unwrap().0[39], Cell::blank(0));
    assert!(t.scrollback().line(1, 12).is_none());
}

#[test]
fn scrollback_drops_oldest_beyond_the_limit() {
    let mut t = Terminal::with_scrollback(8, 1, 3);
    for i in 0..10 {
        t.feed(format!("line{i}\r\n").as_bytes());
    }
    assert_eq!(t.scrollback().count(), 3);
    let first: String = t.scrollback().line(0, 8).unwrap().0[..5].iter().filter_map(|cell| char::from_u32(cell.scalar())).collect();
    assert_eq!(first, "line7");

    // Across many pages, with the head page expiring line by line.
    let mut t = Terminal::with_scrollback(120, 40, 5000);
    for i in 0..6000 {
        t.feed(format!("\x1b[32mok\x1b[0m line number {i} with some typical output text\r\n").as_bytes());
    }
    assert_eq!(t.scrollback().count(), 5000);
    assert_eq!(t.recent_text(1), ["ok line number 5999 with some typical output text"]);
    let oldest: String = t.scrollback().line(0, 120).unwrap().0.iter().filter_map(|cell| char::from_u32(cell.scalar())).filter(|&c| c != '\0').collect();
    assert_eq!(oldest, "ok line number 961 with some typical output text");
}

// Replies and events (the fixtures compare the bytes; these say what they mean)

#[test]
fn device_queries_are_answered() {
    let mut t = terminal(10, 5, "\x1b[c");
    assert_eq!(reply(&mut t), "\x1b[?62;22c");
    t.feed(b"\x1b[>c\x1b[3;4H\x1b[6n\x1b[5n\x1b[?2026$p\x1b[?2026h\x1b[?2026$p\x1b[?9999$p");
    assert_eq!(reply(&mut t), "\x1b[>1;10;0c\x1b[3;4R\x1b[0n\x1b[?2026;2$y\x1b[?2026;1$y\x1b[?9999;0$y");
    t.feed(b"\x1b]11;?\x07\x1b]10;?\x1b\\");
    assert_eq!(reply(&mut t), "\x1b]11;rgb:ffff/ffff/ffff\x07\x1b]10;rgb:1414/2323/3d3d\x1b\\");
    t.reported_background = 0x0A0B0C;
    t.feed(b"\x1b]11;?\x07\x1b[?u\x1b[>0q");
    assert_eq!(reply(&mut t), "\x1b]11;rgb:0a0a/0b0b/0c0c\x07");
    assert_eq!(t.take_output(), None);
}

#[test]
fn title_bell_and_notifications() {
    let mut t = terminal(10, 2, "\x1b]0;✳ Claude Code\x07\x07\x1b]9;Claude needs input\x1b\\\x1b]9;4;1;50\x07");
    let events = t.take_events();
    assert!(t.title() == "✳ Claude Code" && events.title_changed);
    assert_eq!(events.bells, 1);
    assert_eq!(events.notifications, ["Claude needs input"]);
    assert!(t.take_events().is_empty());
}

#[test]
fn modes_toggle() {
    use crate::terminal::TerminalModes as M;
    let mut t = terminal(10, 2, "\x1b[?1h\x1b[?2004h\x1b[?1004h\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2026h\x1b[5 q");
    for mode in [M::APPLICATION_CURSOR, M::BRACKETED_PASTE, M::FOCUS_EVENTS, M::SYNCHRONIZED_OUTPUT] {
        assert!(t.modes().contains(mode));
    }
    assert!(!t.cursor().visible && t.cursor().shape == CursorShape::Bar);
    assert!(t.mouse_tracking() == MouseTracking::ButtonEvent && t.mouse_encoding() == MouseEncoding::Sgr);
    t.feed(b"\x1b[?2026l\x1b[?1002l");
    assert!(!t.is_synchronizing() && t.mouse_tracking() == MouseTracking::None);
}

// Snapshots (SnapshotTests.swift; the fixtures cover copies of Swift's own snapshots)

#[test]
fn restore_rejects_garbage_and_keeps_its_state() {
    let mut t = terminal(10, 2, "keep");
    let before = t.snapshot();
    assert!(!t.restore(&[1, 2, 3]));
    assert!(!t.restore(&[]));
    let whole = Terminal::new(10, 2).snapshot();
    for length in 0..whole.len() {
        assert!(!t.restore(&whole[..length]), "accepted a snapshot cut at {length} of {}", whole.len());
    }
    assert_eq!(t.snapshot(), before);
    assert!(t.restore(&whole));
    assert_eq!(t.snapshot(), whole);
}

/// Version 1 had no parser position at the end; restoring one leaves the parser at rest.
#[test]
fn restores_a_version_1_snapshot() {
    let original = terminal(10, 2, "abc\x1b[31m");
    let mut bytes = original.snapshot();
    assert_eq!(bytes[4], 2);
    bytes[4] = 1;
    // The parser at rest is 1 state byte, 2 empty counts, 1 flag, 3 words, 1 count, 1 word,
    // 1 count and 1 word: 26 bytes.
    bytes.truncate(bytes.len() - 26);
    let mut copy = terminal(30, 5, "\x1b[38;5");
    assert!(copy.restore(&bytes));
    copy.feed(b"mX");
    // "m" printed as text: the half-read sequence of the restoring terminal is gone.
    assert_eq!(copy.screen_text()[0], "abcmX");
    assert_eq!(copy.cell(3, 0).foreground(), TerminalColor::palette(1));
}

/// A snapshot may come from another machine: whatever bytes it holds, restoring and then
/// using the terminal must not panic.
#[test]
fn corrupt_snapshots_never_panic() {
    let mut source = Terminal::with_scrollback(20, 6, 50);
    source.feed("\x1b]2;t\x07line one\r\n终端 e\u{301} 👩\u{200D}💻\r\n\x1b[2;4r\x1b7\x1b[?1049h\x1b[1;31malt\x1b7\x1b(0\x1b[38;2;1".as_bytes());
    for _ in 0..80 {
        source.feed(b"scrolling into history \x1b[4mstyled\x1b[m\r\n");
    }
    let snapshot = source.snapshot();
    let probe = "\x1b[6n\x1b8x\x1b[5b终\u{301}\u{200D}y\tz\x1b[?1049l\x1b8\x1b[3;3H\x1b[L\x1b[M\x1b[2P\x1b[2@\x1b[J\x1b[1J\x1b(0q\x0eq\r\n\r\n\x1b[10b\x1bM\x1bM\x1bM\x1b[r\x1b[99;99Hend";
    let mut state = 0x2545_F491_4F6C_DD1Du64;
    let mut random = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    let mut accepted = 0;
    for round in 0..20_000 {
        let mut bytes = snapshot.clone();
        for _ in 0..1 + round % 3 {
            let index = random() as usize % bytes.len();
            bytes[index] = if round % 2 == 0 { random() as u8 } else { bytes[index] ^ 1 << (random() % 8) };
        }
        let mut t = Terminal::with_scrollback(9, 3, 50);
        if !t.restore(&bytes) {
            continue;
        }
        accepted += 1;
        t.snapshot();
        t.screen_text();
        t.recent_text(100);
        t.feed(probe.as_bytes());
        t.resize(7, 2);
        t.feed(probe.as_bytes());
        t.resize(40, 12);
        t.recent_text(100);
        t.snapshot();
    }
    assert!(accepted > 1000, "only {accepted} corrupt snapshots were accepted: the test isn't reaching past restore");
}

/// Swift reads rows the main screen doesn't have here (see `Terminal::resize`); this must
/// stay inside the grid.
#[test]
fn resize_with_a_saved_cursor_below_the_main_screen() {
    let mut t = terminal(10, 24, "\x1b[24;1Hbottom\x1b7");
    t.feed(b"\x1b[1;1H");
    t.resize(10, 10);
    t.feed(b"\x1b[?47h");
    t.resize(10, 5);
    t.feed(b"\x1b[?47l\x1b8x");
    assert_eq!(t.cursor().row, 4);
}

/// Whatever a program writes, at any size and through any resize, the terminal keeps going:
/// a host that panics loses every session it owns.
#[test]
fn noise_never_panics() {
    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    let mut random = move |below: usize| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        (state >> 11) as usize % below
    };
    let pieces: [&[u8]; 24] = [
        b"\x1b[", b"\x1b[?", b"\x1b]", b"\x1bP", b"\x1b", b";", b":", b"\x07", b"\r\n", b"\x1b\\", b"\x1b[?1049h", b"\x1b[?1049l", b"\x1b7", b"\x1b8",
        "终端".as_bytes(), "👩\u{200D}💻".as_bytes(), "e\u{301}".as_bytes(), b"\x1b[?6h", b"\x1b[4h", b"\x1b(0", b"\x1b[?7l", b"\t", b"\x08", b"\x1bM",
    ];
    let finals = b"@ABCDEFGHIJKLMPSTXZ`abcdefghlmnpqrstu";
    for round in 0..300 {
        let mut t = Terminal::with_scrollback(2 + random(60), 1 + random(30), [0, 3, 500][round % 3]);
        for _ in 0..400 {
            let mut chunk = Vec::new();
            for _ in 0..1 + random(12) {
                match random(8) {
                    0 => chunk.extend((0..random(30)).map(|_| 0x20 + random(0x5F) as u8)),
                    1 => chunk.extend((0..random(4)).map(|_| random(256) as u8)),
                    2 | 3 => chunk.extend_from_slice(format!("{}", [0, 1, 2, 5, 9, 40, 99, 65535, 70000][random(9)]).as_bytes()),
                    4 => chunk.push(finals[random(finals.len())]),
                    _ => chunk.extend_from_slice(pieces[random(pieces.len())]),
                }
            }
            t.feed(&chunk);
            match random(12) {
                0 => t.resize(1 + random(70), random(35)),
                1 => {
                    let snapshot = t.snapshot();
                    let mut copy = Terminal::with_scrollback(3, 3, t.scrollback().limit());
                    assert!(copy.restore(&snapshot));
                    assert!(copy.snapshot() == snapshot, "round {round}: a restored terminal takes a different snapshot");
                }
                2 => {
                    t.screen_text();
                    t.recent_text(random(50));
                }
                _ => {}
            }
        }
    }
}

/// An OSC string longer than the parser keeps (64 KB) is cut, not dropped.
#[test]
fn overlong_osc_is_cut_at_the_parser_limit() {
    let mut t = terminal(10, 2, "\x1b]2;");
    t.feed(&vec![b'x'; 70_000]);
    t.feed(b"\x07after");
    assert_eq!(t.title().len(), 64 * 1024 - 2);
    assert_eq!(t.screen_text()[0], "after");
}
