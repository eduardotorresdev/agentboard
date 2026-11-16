//! Swift compares and splits strings by `Character` (grapheme cluster, up to canonical
//! equivalence), and Foundation searches them its own way. Where the Swift terminal's answers
//! depend on that, these reproduce it for the few ASCII patterns involved, from a table of what
//! Swift does with every scalar (`unicode_tables::GRAPHEMES`).

use crate::character_width::lookup;
use crate::unicode_tables::GRAPHEMES;

/// The scalar joins the `Character` of an ordinary scalar before it (marks, joiners).
const JOINS_PREVIOUS: u8 = 1;
/// The scalar joins the `Character` of an ordinary scalar after it (prepended marks).
const JOINS_NEXT: u8 = 2;
/// Foundation's search doesn't find a line feed followed by the scalar.
const HIDES_LINE_FEED: u8 = 4;
/// Foundation's search doesn't find an end-of-paste marker followed by the scalar.
const HIDES_MARKER: u8 = 16;

fn has(scalar: Option<char>, bit: u8) -> bool {
    scalar.is_some_and(|scalar| lookup(&GRAPHEMES, scalar as u32).unwrap_or(0) & bit != 0)
}

/// U+037E (Greek question mark) is canonically a semicolon, so Swift sees them as equal.
fn canonical(scalar: char) -> char {
    if scalar == '\u{37E}' { ';' } else { scalar }
}

/// `text.hasPrefix(prefix)` for an ASCII `prefix`.
pub(crate) fn has_prefix(text: &str, prefix: &str) -> bool {
    let mut scalars = text.chars();
    prefix.chars().all(|expected| scalars.next().map(canonical) == Some(expected)) && !has(scalars.next(), JOINS_PREVIOUS)
}

/// `text.split(separator: ";", maxSplits:, omittingEmptySubsequences: false)`.
pub(crate) fn split_semicolons(text: &str, max_splits: usize) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut previous = None;
    let mut scalars = text.char_indices().peekable();
    while let Some((index, scalar)) = scalars.next() {
        let next = scalars.peek().map(|next| next.1);
        if canonical(scalar) == ';' && parts.len() < max_splits && !has(previous, JOINS_NEXT) && !has(next, JOINS_PREVIOUS) {
            parts.push(&text[start..index]);
            start = index + scalar.len_utf8();
        }
        previous = Some(scalar);
    }
    parts.push(&text[start..]);
    parts
}

/// `while text.last == " " { text.removeLast() }`: a space is a character of its own unless
/// the scalar before it joins it.
pub(crate) fn trim_trailing_spaces(text: &mut String) {
    while text.ends_with(' ') && !has(text[..text.len() - 1].chars().next_back(), JOINS_NEXT) {
        text.pop();
    }
}

/// Foundation's `text.replacingOccurrences(of: target, with: replacement)` for the targets
/// `encode_paste` uses: an occurrence doesn't count when the scalar after it combines with it.
fn replacing(text: &str, target: &str, replacement: &str, hidden_by: u8) -> String {
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(found) = rest.find(target) {
        let after = &rest[found + target.len()..];
        if has(after.chars().next(), hidden_by) {
            result.push_str(&rest[..found + 1]);
            rest = &rest[found + 1..];
        } else {
            result.push_str(&rest[..found]);
            result.push_str(replacement);
            rest = after;
        }
    }
    result + rest
}

pub(crate) fn replacing_line_breaks(text: &str) -> String {
    replacing(&replacing(text, "\r\n", "\r", HIDES_LINE_FEED), "\n", "\r", HIDES_LINE_FEED)
}

pub(crate) fn removing_paste_end(text: &str) -> String {
    replacing(text, "\u{1b}[201~", "", HIDES_MARKER)
}
