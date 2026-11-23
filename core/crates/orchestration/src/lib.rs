//! What the core keeps while no board runs: the cards, the lines between elements, the agents'
//! tools and the runners. A port of `Sources/Orchestration`, file by file (the board's side,
//! `CoreLink` and `InProcessCore`, stays in Swift).
//!
//! # Threads
//!
//! The `Orchestrator` is the `CoreServer`'s service: it lives on the main loop and is only
//! ever touched there, so none of its state is locked. Everything else reaches it as a closure
//! posted through the server's `CoreHandle`:
//!
//! - **Tool calls**: the tool server's threads hand each request to the loop and block for the
//!   reply. A tool that takes its time (a runner settling, a call relayed to the board) keeps
//!   the reply and answers from a later turn of the loop.
//! - **Timers** (the Enter after a paste, the idle check, the runner monitor) are the loop's
//!   (`post_after`).
//! - **Slow work** (the login shell's PATH, measuring runners' processes, ffmpeg) runs on a
//!   thread of its own and posts what it found.

mod attention;
mod board_protocol;
mod browser_relay;
mod card_database;
mod card_tools;
mod decision;
mod decision_tools;
mod cards;
mod image_card;
mod image_tools;
mod l10n;
mod orchestrator;
mod orchestrator_media;
mod orchestrator_runners;
mod post_it;
pub mod projects;
mod post_it_tools;
mod process_inspector;
mod project_relay;
mod runner_tools;
mod simulator_relay;
mod sandbox;
mod transcript_context;
mod video_files;
mod worktree_tools;

pub use attention::{AgentQuestion, AttentionRequest, QuestionOption, Reason};
pub use board_protocol::{now, only, BoardEvent, BoardRequest, BoardState, RunnerReport, Unlabelled, WireToolResult};
pub use card_database::CardDatabase;
pub use decision::{Answer, Ask, Card as DecisionCard, Decision, Evidence, Pin, State as DecisionState, Variant};
pub use cards::{default_organization, AgentRecord, ElementInfo, RunnerSpec};
pub use image_card::{Failure, ImageFiles, ImageRecord, Inspected, Kind, Stored};
pub use orchestrator::{login_shell_path, Options, Orchestrator, TerminalLine, Turn};
pub use post_it::PostItRecord;
pub use sandbox::wrap_command;
pub use process_inspector::{ListeningPort, ProcessInspector, RunnerStats, Sample};
pub use transcript_context::TranscriptContext;
pub use video_files::VideoTools;
