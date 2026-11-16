use unicode_properties::{GeneralCategory, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

/// Text a person or an agent typed that the UI shows as a name or title (worktree titles, card
/// names): one line of visible text, so it can't hide, reorder or blank what's around it, while
/// emoji sequences and scripts that join letters keep working.
pub struct DisplayText;

impl DisplayText {
    pub(crate) const MAX_SCALARS_PER_CHARACTER: usize = 16;

    /// Works character by character (grapheme clusters):
    /// - line breaks and tabs become one space; other control characters go;
    /// - bidi overrides, embeddings, isolates and marks go wherever they are;
    /// - other format characters (ZWJ, ZWNJ, tags, U+0600…) stay inside a character that has
    ///   something else, and go when they stand alone (a lone U+2060, U+FEFF, soft hyphen);
    /// - characters that draw nothing or a placeholder (unassigned, private use, U+FFFC,
    ///   U+1D159, Hangul fillers, the blank braille pattern) go, as does any single character
    ///   over `MAX_SCALARS_PER_CHARACTER` scalars (stacked combining marks), without ending the text.
    ///
    /// The result keeps whole characters within `max_length` characters and `max_bytes` UTF-8
    /// bytes. None when nothing visible is left.
    pub fn clean(text: &str, max_length: usize, max_bytes: usize) -> Option<String> {
        let mut result = String::new();
        let mut pending_space = false;
        for character in text.graphemes(true) {
            if character.chars().all(|scalar| scalar.is_whitespace() || is_line_control(scalar)) {
                pending_space = !result.is_empty();
                continue;
            }
            let Some(kept) = keep(character) else { continue };
            let piece = if pending_space { format!(" {kept}") } else { kept };
            if count(&result) + count(&piece) > max_length || result.len() + piece.len() > max_bytes {
                break;
            }
            result += &piece;
            pending_space = false;
        }
        result.chars().any(is_visible).then_some(result)
    }
}

/// Characters, as Swift counts them.
fn count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// The character without bidi controls, or none when it should go altogether.
fn keep(character: &str) -> Option<String> {
    let scalars: Vec<char> = character.chars().filter(|scalar| !BIDI.contains(&(*scalar as u32))).collect();
    if scalars.is_empty() || scalars.len() > DisplayText::MAX_SCALARS_PER_CHARACTER {
        return None;
    }
    let draws_nothing = |scalar: &char| {
        BLANK.contains(&(*scalar as u32))
            || matches!(
                scalar.general_category(),
                GeneralCategory::Unassigned | GeneralCategory::PrivateUse | GeneralCategory::Surrogate | GeneralCategory::Control
            )
    };
    if scalars.iter().any(draws_nothing) {
        return None;
    }
    // A character made only of format characters draws nothing: unless it prefixes a number
    // (U+0600–0605, U+06DD, U+070F, U+08E2, U+110BD), which shows as a sign.
    if scalars.iter().all(|scalar| scalar.general_category() == GeneralCategory::Format)
        && !scalars.iter().any(|scalar| NUMBER_SIGNS.contains(&(*scalar as u32)))
    {
        return None;
    }
    Some(scalars.into_iter().collect())
}

fn is_line_control(scalar: char) -> bool {
    [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(&(scalar as u32))
}

fn is_visible(scalar: char) -> bool {
    match scalar.general_category() {
        GeneralCategory::SpaceSeparator
        | GeneralCategory::NonspacingMark
        | GeneralCategory::EnclosingMark
        | GeneralCategory::SpacingMark
        | GeneralCategory::Control
        | GeneralCategory::Format => NUMBER_SIGNS.contains(&(scalar as u32)),
        _ => !scalar.is_whitespace(),
    }
}

const BIDI: [u32; 12] = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069];
const BLANK: [u32; 8] = [0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0, 0xFFFC, 0xFFFD, 0x1D159];
const NUMBER_SIGNS: [u32; 10] = [0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F, 0x08E2, 0x110BD];
