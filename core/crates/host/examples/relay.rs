//! `relay <core socket>`: the host's relay line alone, against whatever serves that socket,
//! with the host's config from `AGENTBOARD_HOME`. For tests (Tests/AgentRuntimeTests/HostChannelTests.swift).

fn main() {
    let Some(socket) = std::env::args().nth(1) else {
        eprintln!("usage: relay <core socket>");
        std::process::exit(2);
    };
    host::serve_relay(std::path::Path::new(&socket));
}
