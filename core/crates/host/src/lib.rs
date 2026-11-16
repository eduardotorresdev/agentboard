//! The host side of remote hosts (docs/hosts.md): the account, the relay line to the account
//! server, the sealed channels that bridge a board to this machine's core, and what a fresh
//! machine needs to run agents. One function per `agentboard` subcommand.

mod account;
mod boards;
mod channel;
mod config;
mod direct;
mod relay;
mod service;
mod setup;
mod wire;
#[cfg(test)]
mod test_support;

pub use account::{login, logout};
pub use boards::{first_board, show as boards, trust_named as trust, untrust_named as untrust};
pub use relay::serve_relay;
pub use service::{install_service, status, uninstall_service};
pub use setup::setup;
