//! The board's connections: which elements are joined by lines, messages along them, and the
//! tools agents call over MCP. A port of `Sources/Connections`, file by file.

mod board_layout;
mod board_names;
mod connection_graph;
mod display_text;
mod geometry;
mod message_bus;
mod messaging_tools;
mod radial_layout;
mod rope;
mod tool_catalog;
mod tool_server;
mod uuid;

pub use crate::uuid::Uuid;
pub use board_layout::*;
pub use board_names::*;
pub use connection_graph::*;
pub use display_text::*;
pub use geometry::*;
pub use message_bus::*;
pub use messaging_tools::*;
pub use radial_layout::*;
pub use rope::*;
pub use tool_catalog::*;
pub use tool_server::*;
