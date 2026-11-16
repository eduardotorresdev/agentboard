//! A terminal emulator without a screen: the Rust port of the Swift `TerminalCore`
//! (`Sources/TerminalCore`), file for file. A host feeds it what a program writes to its PTY
//! and keeps the state; the Mac board draws it from [`Terminal::snapshot`], whose bytes are
//! exactly what the Swift `Terminal.snapshot()` produces for the same input at the same size
//! (`core/fixtures/terminal`, written by the Swift test `SnapshotFixtures`, pins that down).
//!
//! What the other crates use:
//!
//! - [`Terminal::new`]`(cols, rows)` (5000 lines of history) or [`Terminal::with_scrollback`].
//! - [`Terminal::feed`] with the program's output; then [`Terminal::take_output`] for the bytes
//!   to write back to the program (answers to its queries) and [`Terminal::take_events`] for
//!   bells, title changes and notifications (OSC 9 and 777).
//! - [`Terminal::resize`], [`Terminal::cols`], [`Terminal::rows`].
//! - [`Terminal::snapshot`] and [`Terminal::restore`].
//! - [`Terminal::modes`], [`Terminal::is_synchronizing`], [`Terminal::is_alternate_screen`],
//!   [`Terminal::title`], [`Terminal::working_directory`], [`Terminal::cursor`].
//! - [`Terminal::encode_paste`], [`Terminal::encode`] (keys), [`Terminal::encode_focus`],
//!   [`Terminal::encode_mouse`]: user input as the program asked to receive it.
//! - [`Terminal::recent_text`] (what runner logs read) and [`Terminal::screen_text`].
//!
//! Not thread-safe: one owner at a time.

mod cell;
mod character_width;
mod grid;
mod input;
mod parser;
mod rendering;
mod scrollback;
mod snapshot;
mod swift_string;
mod terminal;
mod terminal_control;
mod unicode_tables;

pub use cell::{Cell, CellAttributes, CellWidth, ColorKind, TerminalColor};
pub use input::{KeyModifiers, MouseEvent, MouseEventKind, TerminalKey};
pub use rendering::CursorState;
pub use scrollback::Scrollback;
pub use terminal::{CursorShape, MouseEncoding, MouseTracking, Terminal, TerminalEvents, TerminalModes};

#[cfg(test)]
mod tests;
