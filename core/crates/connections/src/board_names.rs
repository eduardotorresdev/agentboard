use std::fmt;

use serde_json::Value;

use crate::{DisplayText, Element, Uuid};

/// Names of board elements and worktree titles: what agents and the user call things. They reach
/// agents' prompts and tool listings, so they are cut to one line of visible text.
pub struct BoardName;

impl BoardName {
    pub const MAX_LENGTH: usize = 60;
    pub const MAX_BYTES: usize = 240;

    /// One line of visible text within the caps; none when nothing visible is left (see `DisplayText`).
    pub fn clean(name: &str) -> Option<String> {
        DisplayText::clean(name, Self::MAX_LENGTH, Self::MAX_BYTES)
    }

    /// `name` cleaned, or why it can't be one: empty, or an id, which would shadow the element
    /// that has it.
    pub fn validated(name: &str) -> Result<String, NameError> {
        let clean = Self::clean(name).ok_or(NameError::Empty)?;
        if Uuid::parse(&clean).is_some() {
            return Err(NameError::LooksLikeId);
        }
        Ok(clean)
    }

    /// A tool's optional `name` argument: none when none was given (or nothing visible), so a
    /// default applies; a failure for an id.
    pub fn argument(value: Option<&Value>) -> Result<Option<String>, NameError> {
        match value.and_then(Value::as_str).and_then(Self::clean) {
            Some(clean) => Self::validated(&clean).map(Some),
            None => Ok(None),
        }
    }

    /// `name` as a valid name, else `fallback`: what a name from outside becomes on its way in.
    pub fn named(name: &str, fallback: &str) -> String {
        Self::validated(name).unwrap_or_else(|_| fallback.to_string())
    }

    /// For listings: cleaned, quoted, so a name can't pass for list syntax.
    pub fn quoted(name: &str) -> String {
        let clean = Self::clean(name).unwrap_or_else(|| "?".to_string());
        format!("“{}”", clean.replace(['“', '”'], "\""))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameError {
    Empty,
    LooksLikeId,
}

impl fmt::Display for NameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            NameError::Empty => "The name has no visible text.",
            NameError::LooksLikeId => "A name can't be an id.",
        })
    }
}

impl std::error::Error for NameError {}

/// `CharacterSet.whitespaces`: spaces and tabs, not line breaks.
pub(crate) fn is_inline_space(scalar: char) -> bool {
    scalar.is_whitespace() && !matches!(scalar, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The element `address` names among `elements`: by id first, so a name can't hijack an id, then
/// by name, case-insensitively.
pub fn find_element_by<'a, E>(address: &str, elements: &'a [E], id: impl Fn(&E) -> Uuid, name: impl Fn(&E) -> &str) -> Option<&'a E> {
    let given = address.trim_matches(is_inline_space);
    let unquoted = given.trim_matches(['“', '”', '"']);
    if let Some(found) = Uuid::parse(unquoted).and_then(|uuid| elements.iter().find(|element| id(element) == uuid)) {
        return Some(found);
    }
    // Up then down folds case as Foundation's comparison does ("straße" is "STRASSE").
    let fold = |text: &str| text.to_uppercase().to_lowercase();
    let same = |wanted: &str| elements.iter().find(|element| fold(name(element)) == fold(wanted));
    // The name as given (it may hold quotes of its own), then without the quotes listings add.
    same(given).or_else(|| same(unquoted))
}

pub fn find_element<'a>(address: &str, elements: &'a [Element]) -> Option<&'a Element> {
    find_element_by(address, elements, |element| element.id, |element| &element.name)
}
