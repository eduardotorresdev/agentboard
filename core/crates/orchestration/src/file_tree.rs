use serde::{Deserialize, Serialize};

use connections::{Rect, Uuid};

use crate::board_protocol::rect;
use crate::cards::default_organization;

/// A file tree card: its worktree's files, listed by the board through the host (`run`). The
/// core keeps the card, so every board on the host shows it; what it sends travels along lines.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileTreeRecord {
    pub id: Uuid,
    pub worktree: String,
    pub name: String,
    #[serde(with = "rect")]
    pub frame: Rect,
    /// The organization it was added in; none means the default one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization: Option<Uuid>,
}

impl FileTreeRecord {
    pub fn organization_id(&self) -> Uuid {
        self.organization.unwrap_or(default_organization())
    }
}
