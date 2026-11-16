use serde::{Deserialize, Serialize};

use connections::{Rect, Size, Uuid};

use crate::board_protocol::{now, rect};
use crate::cards::{default_organization, unique_name};

/// A post-it on the board: one markdown text that the user and the agents connected to it read
/// and rewrite. The core keeps it, so agents use it while no board runs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PostItRecord {
    pub id: Uuid,
    pub worktree: String,
    /// How the post-it is titled and how connected agents address it; unique in its worktree.
    pub name: String,
    #[serde(with = "rect")]
    pub frame: Rect,
    /// Markdown.
    pub text: String,
    /// Who wrote the text last: an agent, or none for the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub editor: Option<Uuid>,
    /// That agent's name when it wrote, kept once it is gone.
    pub editor_name: String,
    /// When the text last changed (seconds since 2001); none while nothing was written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited: Option<f64>,
    /// The organization it was added in; none for post-its made before organizations, which
    /// belong to the default one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization: Option<Uuid>,
}

impl PostItRecord {
    pub const SIZE: Size = Size::new(340.0, 320.0);

    pub fn new(id: Uuid, worktree: impl Into<String>, name: impl Into<String>, frame: Rect) -> Self {
        Self { id, worktree: worktree.into(), name: name.into(), frame, text: String::new(), editor: None, editor_name: String::new(), edited: None, organization: None }
    }

    /// The organization the post-it belongs to, with older ones in the default one.
    pub fn organization_id(&self) -> Uuid {
        self.organization.unwrap_or(default_organization())
    }

    /// Replaces the text, as written by `editor` (none: the user) called `name`, now.
    pub fn write(&mut self, text: impl Into<String>, editor: Option<Uuid>, name: &str) {
        self.text = text.into();
        self.editor = editor;
        self.editor_name = if editor.is_none() { String::new() } else { name.to_string() };
        self.edited = Some(now());
    }

    /// `base`, or `base 2`, `base 3`… whichever no post-it in `others` is called.
    pub fn unique_name<'a>(base: &str, others: impl IntoIterator<Item = &'a PostItRecord>) -> String {
        unique_name(base, others.into_iter().map(|other| other.name.as_str()))
    }
}
