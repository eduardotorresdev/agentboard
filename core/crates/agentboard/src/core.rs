//! `agentboard core`: runs the agents' programs on behalf of the board, and keeps the cards, the
//! lines between them and the agents' tools, so all of it survives the board quitting. Serves
//! boards on its socket until told to exit or idle. Logs to stderr, which whoever launches it
//! points at `core.log`. `--socket-path` prints where the core serves.

use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;

use orchestration::{Options, Orchestrator};
use runtime::{core_protocol, data_folder, CoreServer};

pub const USAGE: &str = "usage: agentboard <command>
  login        sign this machine in to your account, as a host
  logout       sign it out and forget it
  setup        install what agents need here (git, Node, Docker, Chromium, the agent CLIs)
  service      run the host in the background from now on (service remove: stop doing so)
  status       who is signed in, and whether the host is up
  boards       the computers this host trusts, and the ones waiting to be
  trust <fingerprint or key>    let that computer use this host
  untrust <fingerprint or key>  stop letting it
  host         run the host here, in the foreground
  core [--socket <path>] [--socket-path]
  data-folder  print where the host keeps its data";

/// The time as ISO 8601 with milliseconds, in UTC.
fn timestamp() -> String {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let seconds = now.as_secs() as libc::time_t;
    // SAFETY: gmtime_r writes only into `time`, which is plain data.
    let time = unsafe {
        let mut time: libc::tm = std::mem::zeroed();
        libc::gmtime_r(&seconds, &mut time);
        time
    };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z", time.tm_year + 1900, time.tm_mon + 1, time.tm_mday, time.tm_hour, time.tm_min, time.tm_sec, now.subsec_millis())
}

fn log(message: &str) {
    eprintln!("{} core[{}] {message}", timestamp(), std::process::id());
}

/// `agentboard host`: the core as a host's service. It also keeps the line to the account
/// server, and never exits for being idle: boards come and go over the relay.
pub fn host() {
    let socket_path = core_protocol::socket_path();
    std::thread::spawn({
        let socket_path = socket_path.clone();
        move || host::serve_relay(Path::new(&socket_path))
    });
    serve(socket_path, 1e9);
}

pub fn run(arguments: &[String]) {
    let socket_path = match arguments {
        [] => core_protocol::socket_path(),
        [flag] if flag == "--socket-path" => {
            println!("{}", core_protocol::socket_path());
            return;
        }
        [flag, path] if flag == "--socket" => {
            // A core on a socket of its own is another instance: it never shares the default
            // one's cards, key and tool port.
            if *path != core_protocol::socket_path() && std::env::var_os("AGENTBOARD_HOME").is_none_or(|home| home.is_empty()) {
                std::env::set_var("AGENTBOARD_HOME", format!("{path}.data"));
            }
            path.clone()
        }
        _ => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    };
    serve(socket_path, 60.0);
}

fn serve(socket_path: String, idle_timeout: f64) {
    if let Some(folder) = Path::new(&socket_path).parent() {
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder);
    }
    // One core per socket: a second one (two boards launching at once) leaves quietly instead
    // of taking the socket file from the first. The lock is held until the process ends.
    let lock = std::fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(format!("{socket_path}.lock"));
    // SAFETY: flock only takes a descriptor, open for as long as `lock` lives.
    if !lock.as_ref().is_ok_and(|lock| unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0) {
        log(&format!("another core already serves {socket_path}"));
        return;
    }
    // shortcut: no `--take-over`; a newer build replaces this core only by ending its programs. Port `CoreHandoff` when cores are upgraded in place.
    let mut server = CoreServer::<Orchestrator>::new(socket_path.as_str(), idle_timeout);
    server.on_log = Box::new(log);
    if let Err(error) = server.start() {
        log(&format!("could not listen on {socket_path}: {error}"));
        std::process::exit(1);
    }
    // What a board runs about a project runs in that project's sandbox (see `sandbox.rs`).
    server.run_sandbox = Some(std::sync::Arc::new(|about, executable, arguments, directory| {
        orchestration::wrap_command(about, executable, arguments, directory, &data_folder::url())
    }));
    let orchestrator = Orchestrator::new(server.handle(), Options::new(data_folder::url()));
    log(&format!("listening on {socket_path}"));
    server.run(orchestrator);
    log("exiting");
    let _ = std::fs::remove_file(&socket_path);
}
