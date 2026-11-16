use serde::{Deserialize, Serialize};

use connections::{Rect, Size, Uuid};
use runtime::AgentProvider;

use crate::board_protocol::{rect, to_runtime};

/// A persisted terminal card: an agent, or a runner (a command the board keeps running, such as
/// a dev server). Which worktree it belongs to and where it sits on the canvas.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AgentRecord {
    pub id: Uuid,
    pub worktree: String,
    /// `AgentProvider::id` of the agent this card runs; `AgentRecord::RUNNER_PROVIDER_ID` for runners.
    #[serde(rename = "providerID")]
    pub provider_id: String,
    /// How the card is titled and how connected agents address it; unique in its worktree.
    pub name: String,
    #[serde(with = "rect")]
    pub frame: Rect,
    /// What the card runs when it is a runner; none for agents.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<RunnerSpec>,
    /// The organization the card was added in; none for cards made before organizations, which
    /// belong to the default one. Agents run signed in as it (see `organization_home`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization: Option<Uuid>,
    /// Coordinates the agents connected to it: their finished turns go to it, not to Needs you.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orchestrates: Option<bool>,
    /// The agent's current conversation, when it moved off the one named after the card
    /// (`/clear` starts another). None means the card's own id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<Uuid>,
}

impl AgentRecord {
    pub const RUNNER_PROVIDER_ID: &'static str = "runner";
    pub const RUNNER_SIZE: Size = Size::new(600.0, 340.0);

    pub fn new(id: Uuid, worktree: impl Into<String>, provider_id: impl Into<String>, name: impl Into<String>, frame: Rect) -> Self {
        Self { id, worktree: worktree.into(), provider_id: provider_id.into(), name: name.into(), frame, runner: None, organization: None, orchestrates: None, conversation: None }
    }

    pub fn is_orchestrator(&self) -> bool {
        self.orchestrates == Some(true) && self.runner.is_none()
    }

    /// The organization the card belongs to, with older cards in the default one.
    pub fn organization_id(&self) -> Uuid {
        self.organization.unwrap_or(default_organization())
    }

    pub fn provider(&self) -> Option<&'static dyn AgentProvider> {
        runtime::AgentCatalog::provider(&self.provider_id)
    }

    /// `base`, or `base 2`, `base 3`… whichever no card in `others` is called.
    pub fn unique_name<'a>(base: &str, others: impl IntoIterator<Item = &'a AgentRecord>) -> String {
        unique_name(base, others.into_iter().map(|other| other.name.as_str()))
    }

    /// A card name from a command: the script of `npm run dev` (dev), else the program's name;
    /// `terminal` for a runner without a command, which is a plain shell.
    pub fn runner_name(command: &str) -> String {
        let words: Vec<&str> = command.split(' ').filter(|word| !word.is_empty() && !word.contains('=')).collect();
        let Some(first) = words.first().map(|word| word.trim_end_matches('/').rsplit('/').next().unwrap_or(word)) else { return "terminal".into() };
        if ["npm", "pnpm", "yarn", "bun", "deno"].contains(&first) && words.len() > 1 {
            let rest: Vec<&str> = words[1..].iter().copied().filter(|word| !word.starts_with('-')).collect();
            let script = if rest.first() == Some(&"run") { rest.get(1) } else { rest.first() };
            return script.copied().unwrap_or(first).to_string();
        }
        first.to_string()
    }
}

/// `organization_home::DEFAULT_ID`, as this crate's id type.
pub fn default_organization() -> Uuid {
    Uuid::from_bytes(*runtime::organization_home::DEFAULT_ID.as_bytes())
}

/// `base`, or `base 2`, `base 3`… whichever none of `taken` is, whatever the case.
pub(crate) fn unique_name<'a>(base: &str, taken: impl Iterator<Item = &'a str>) -> String {
    let taken: std::collections::HashSet<String> = taken.map(str::to_lowercase).collect();
    if !taken.contains(&base.to_lowercase()) {
        return base.to_string();
    }
    let mut number = 2;
    while taken.contains(&format!("{base} {number}").to_lowercase()) {
        number += 1;
    }
    format!("{base} {number}")
}

/// What a runner card runs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunnerSpec {
    /// A shell command line, run with the user's login shell. Empty: the shell itself, to use
    /// as an ordinary terminal.
    pub command: String,
    /// The folder it runs in: the worktree or a folder inside it.
    pub directory: String,
    /// The agent that started it, which may also close it; none when the developer added it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<Uuid>,
}

impl RunnerSpec {
    /// Whether it runs no command: the login shell, interactive.
    pub fn is_shell(&self) -> bool {
        self.command.trim().is_empty()
    }
}

/// A board element that isn't a terminal card (a browser…), as the board tells the core about
/// it: lines reach it, and agents see it in `list_peers`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ElementInfo {
    pub id: Uuid,
    pub name: String,
    /// `ElementKind`'s text.
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub worktree: String,
    #[serde(with = "rect")]
    pub frame: Rect,
    /// The organization it belongs to; none from a board that predates organizations here, which
    /// puts it on the worktree's board in every organization.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization: Option<Uuid>,
}

/// The organization's Claude Code config folder, prepared (see `organization_home::prepare`).
pub(crate) fn prepare_organization(organization: Option<Uuid>) -> Option<std::path::PathBuf> {
    runtime::organization_home::prepare(organization.map(to_runtime))
}
