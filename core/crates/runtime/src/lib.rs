//! The core's runtime: the protocol boards speak, PTYs, sessions and the server that serves
//! them. A port of `Sources/AgentRuntime`, file by file (the board's side, `CoreClient` and the
//! mirror half of `AgentSession`, and the handoff between cores stay in Swift).
//!
//! # Threads
//!
//! Plain threads and channels, as the Swift core is queues:
//!
//! - **The main loop** (`CoreServer::run`, Swift's main queue) owns the server's state and the
//!   service. Everything else reaches it as a message: boards' frames, sessions' statuses, and
//!   closures posted through a `CoreHandle` (`post`, and `post_after` for timers). A closure
//!   gets `&mut` the service and the server, so neither needs a lock. The service
//!   (`CoreService`) is called there too, with the server to act on.
//! - **Each session** has a thread (`PseudoTerminal`) that waits on its PTY: it parses output
//!   into the session's terminal and, in the same critical section, hands the bytes to every
//!   board mirroring it. Attaching takes the snapshot and subscribes inside that section too,
//!   so a mirror never misses or repeats a byte.
//! - **Each board** has a reader thread (frames to the main loop) and a writer thread that only
//!   wakes for what the socket couldn't take at once (`CoreSocket`).
//!
//! Nothing polls on a timer or sleeps: threads block on descriptors, channels and deadlines.

mod agent_provider;
mod agent_session;
pub mod core_protocol;
mod core_server;
pub mod core_socket;
pub mod data_folder;
mod host_stats;
pub mod organization_home;
mod pseudo_terminal;
mod uuid;

pub use crate::uuid::Uuid;
pub use agent_provider::*;
pub use agent_session::{AgentSession, State};
pub use core_protocol::{CoreEvent, CoreRequest, Data, FrameKind, HostStats, LaunchSpec, SessionStatus, Versions};
pub use core_server::{CoreBoard, CoreHandle, CoreServer, CoreService};
pub use core_socket::{CoreSocket, FrameParser};
pub use host_stats::HostSampler;
pub use pseudo_terminal::{isolate_programs, PseudoTerminal};

/// An OS error as `strerror` words it, without Rust's "(os error N)".
pub(crate) fn error_text(error: &std::io::Error) -> String {
    let text = error.to_string();
    text.split(" (os error").next().unwrap_or(&text).to_string()
}
