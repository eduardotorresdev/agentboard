//! Replays the golden files the Swift test `SnapshotFixtures` writes to
//! `core/fixtures/terminal` (the format is described there) and compares, byte for byte, what
//! this terminal holds and answers with what the Swift one did.

use std::fmt::Write;
use std::fs;
use std::path::{Path, PathBuf};

use terminal::{Terminal, TerminalEvents};

fn directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/terminal")
}

fn hex(text: &str) -> String {
    if text.is_empty() { "-".into() } else { text.bytes().map(|byte| format!("{byte:02x}")).collect() }
}

/// The Swift test's `describe`.
fn describe(terminal: &Terminal, events: &TerminalEvents) -> String {
    let cursor = terminal.cursor();
    let mut out = String::new();
    writeln!(out, "size {} {}", terminal.cols(), terminal.rows()).unwrap();
    writeln!(out, "cursor {} {} {} {}", cursor.column, cursor.row, cursor.visible, cursor.shape as u8).unwrap();
    writeln!(out, "modes {} mouse {} {}", terminal.modes().raw_value(), terminal.mouse_tracking() as u8, terminal.mouse_encoding() as u8).unwrap();
    writeln!(
        out,
        "alternate {} synchronizing {} scrollback {}",
        terminal.is_alternate_screen(),
        terminal.is_synchronizing(),
        terminal.scrollback().count()
    )
    .unwrap();
    writeln!(out, "title {}", hex(terminal.title())).unwrap();
    writeln!(out, "cwd {}", terminal.working_directory().map_or("none".into(), hex)).unwrap();
    writeln!(out, "bells {} titleChanged {}", events.bells, events.title_changed).unwrap();
    for (label, lines) in
        [("notification", events.notifications.clone()), ("screen", terminal.screen_text()), ("recent", terminal.recent_text(1000)), ("recent3", terminal.recent_text(3))]
    {
        for line in lines {
            writeln!(out, "{label} {}", hex(&line)).unwrap();
        }
    }
    out
}

fn difference(what: &str, actual: &[u8], expected: &[u8]) -> Option<String> {
    if actual == expected {
        return None;
    }
    let at = actual.iter().zip(expected).position(|(a, b)| a != b).unwrap_or(actual.len().min(expected.len()));
    Some(format!("{what}: differs at byte {at} ({} bytes, Swift has {})", actual.len(), expected.len()))
}

/// A terminal restored from a Swift snapshot, and what it answered since.
struct Copy {
    terminal: Terminal,
    replies: Vec<u8>,
    /// How much the original had answered when the snapshot was taken.
    since: usize,
}

/// Replays one case; the first thing that differs from Swift, if any.
fn replay(name: &str) -> Result<(), String> {
    let directory = directory();
    let read = |suffix: &str| fs::read(directory.join(format!("{name}.{suffix}"))).map_err(|error| format!("{suffix}: {error}"));
    let check = |what: String, actual: &[u8], expected: &[u8]| difference(&what, actual, expected).map_or(Ok(()), Err);
    let steps = String::from_utf8(read("steps")?).map_err(|error| error.to_string())?;
    let input = read("input")?;
    let mut lines = steps.lines().map(|line| line.split(' ').collect::<Vec<_>>());
    let number = |text: &str| text.parse::<usize>().map_err(|error| format!("steps: {error}"));
    let Some(["size", cols, rows, scrollback]) = lines.next().as_deref().map(|size| <[&str; 4]>::try_from(size).unwrap_or_default()) else {
        return Err("steps: no size".into());
    };
    let scrollback = number(scrollback)?;
    let mut terminal = Terminal::with_scrollback(number(cols)?, number(rows)?, scrollback);
    let (mut replies, mut events, mut copies) = (Vec::new(), TerminalEvents::default(), Vec::<Copy>::new());
    let (mut offset, mut snapshots) = (0, 0);

    // A copy made through `snapshot`, starting from a terminal of another size and content.
    let restored = |snapshot: &[u8], what: &str| {
        let mut copy = Terminal::with_scrollback(7, 3, scrollback);
        copy.feed(b"stale content\r\nthat must go\x1b[?1049h\x1b[31malt\x1b[6n");
        copy.take_output();
        if !copy.restore(snapshot) {
            return Err(format!("{what}: restore refused Swift's snapshot"));
        }
        check(format!("{what}, restored and taken again"), &copy.snapshot(), snapshot)?;
        Ok(copy)
    };

    for (index, step) in lines.enumerate() {
        match step.as_slice() {
            ["feed", count] => {
                let bytes = &input[offset..offset + number(count)?];
                offset += bytes.len();
                terminal.feed(bytes);
                replies.extend(terminal.take_output().unwrap_or_default());
                let taken = terminal.take_events();
                events.bells += taken.bells;
                events.title_changed |= taken.title_changed;
                events.notifications.extend(taken.notifications);
                for copy in &mut copies {
                    copy.terminal.feed(bytes);
                    copy.replies.extend(copy.terminal.take_output().unwrap_or_default());
                }
            }
            ["resize", cols, rows] => {
                terminal.resize(number(cols)?, number(rows)?);
                for copy in &mut copies {
                    copy.terminal.resize(number(cols)?, number(rows)?);
                }
            }
            ["snapshot", answered] => {
                let what = format!("snapshot {snapshots} (step {index})");
                let expected = read(&format!("snapshot.{snapshots}"))?;
                snapshots += 1;
                check(what.clone(), &terminal.snapshot(), &expected)?;
                if replies.len() != number(answered)? {
                    return Err(format!("{what}: answered {} bytes so far, Swift {answered}", replies.len()));
                }
                copies.push(Copy { terminal: restored(&expected, &what)?, replies: Vec::new(), since: replies.len() });
            }
            other => return Err(format!("steps: unknown step {other:?}")),
        }
    }

    let expected = read("snapshot")?;
    check("final snapshot".into(), &terminal.snapshot(), &expected)?;
    let expected_replies = read("replies")?;
    check("replies".into(), &replies, &expected_replies)?;
    let description = describe(&terminal, &events);
    let expected_description = String::from_utf8(read("expect")?).map_err(|error| error.to_string())?;
    if description != expected_description {
        let line = description.lines().zip(expected_description.lines()).position(|(a, b)| a != b).unwrap_or(0);
        return Err(format!(
            "expect: line {line} is {:?}, Swift has {:?}",
            description.lines().nth(line).unwrap_or(""),
            expected_description.lines().nth(line).unwrap_or("")
        ));
    }
    // Every copy restored along the way ends where Swift's copy did (where the original did,
    // unless there is a `restored` file) and answered the same.
    for (number, copy) in copies.iter().enumerate() {
        let ended = read(&format!("restored.{number}")).unwrap_or_else(|_| expected.clone());
        check(format!("the end of the copy restored at snapshot {number}"), &copy.terminal.snapshot(), &ended)?;
        check(format!("replies after snapshot {number}"), &copy.replies, &expected_replies[copy.since..])?;
    }
    let copy = restored(&expected, "final snapshot")?;
    if describe(&copy, &events) != expected_description {
        return Err("expect: differs on a terminal restored from the final snapshot".into());
    }
    Ok(())
}

#[test]
fn every_fixture_matches_swift() {
    let mut names: Vec<String> = fs::read_dir(directory())
        .expect("core/fixtures/terminal is written by `swift test --filter SnapshotFixtures`")
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.strip_suffix(".steps").map(String::from))
        .collect();
    names.sort();
    assert!(names.len() >= 30, "only {} cases in {:?}", names.len(), directory());
    let failures: Vec<String> = names.iter().filter_map(|name| replay(name).err().map(|error| format!("{name}: {error}"))).collect();
    assert!(failures.is_empty(), "{} of {} cases differ from Swift:\n{}", failures.len(), names.len(), failures.join("\n"));
    println!("{} cases match Swift", names.len());
}
