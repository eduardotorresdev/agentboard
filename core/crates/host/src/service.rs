//! The host as a systemd user service, and `agentboard status`.

use std::path::PathBuf;
use std::process::Command;

use crate::config::{self, Config};

const UNIT: &str = "agentboard.service";
const LINUX_ONLY: &str = "Hosts are Linux-only for now: nothing to do on this machine.";

fn unit(executable: &str) -> String {
    // KillMode stays systemd's default (control-group), not `process`: the core owns its
    // agents' terminals, so they can't outlive it usefully (they get a hangup when it dies and
    // a new core can't adopt them). Stopping the whole group leaves no orphan a board can't see.
    //
    // PATH: a user service doesn't read the login shell's profile, and agents are found there.
    format!(
        "[Unit]\nDescription=AgentBoard host\n\n[Service]\nExecStart=\"{}\" host\nRestart=always\nRestartSec=2\n\
         Environment=PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n\n[Install]\nWantedBy=default.target\n",
        executable.replace('%', "%%").replace('\\', "\\\\").replace('"', "\\\"")
    )
}

fn unit_path() -> PathBuf {
    std::env::home_dir().unwrap_or_default().join(".config/systemd/user").join(UNIT)
}

fn systemctl(arguments: &[&str]) -> Result<(), String> {
    let mut command = Command::new("systemctl");
    command.arg("--user").args(arguments);
    // Unset in sessions that didn't come through a login (`su`, some SSH setups).
    if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
        // SAFETY: getuid has no preconditions.
        command.env("XDG_RUNTIME_DIR", format!("/run/user/{}", unsafe { libc::getuid() }));
    }
    match command.status() {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(format!("`systemctl --user {}` failed ({status})", arguments.join(" "))),
        Err(error) => Err(format!("could not run systemctl: {error}")),
    }
}

/// Installs and starts the user service that runs `<this executable> core`, kept running
/// after the user logs out.
pub fn install_service() -> Result<(), String> {
    if !cfg!(target_os = "linux") {
        println!("{LINUX_ONLY}");
        return Ok(());
    }
    let executable = std::env::current_exe().map_err(|error| format!("could not find this program's path: {error}"))?;
    let path = unit_path();
    std::fs::create_dir_all(path.parent().unwrap()).and_then(|_| std::fs::write(&path, unit(&executable.to_string_lossy()))).map_err(|error| format!("could not write {}: {error}", path.display()))?;
    // Lingering first: it starts the user's service manager when no session has.
    if !Command::new("loginctl").arg("enable-linger").status().is_ok_and(|status| status.success()) {
        eprintln!("warning: `loginctl enable-linger` failed: the host stops when you log out");
    }
    systemctl(&["daemon-reload"])?;
    systemctl(&["enable", UNIT])?;
    // Restart, not start: an install over a running service must run the new program.
    systemctl(&["restart", UNIT])?;
    println!("The host runs as the user service {UNIT}.");
    Ok(())
}

/// Stops and removes the service. Lingering is left as it is: other services of the user
/// may count on it.
pub fn uninstall_service() -> Result<(), String> {
    if !cfg!(target_os = "linux") {
        println!("{LINUX_ONLY}");
        return Ok(());
    }
    if unit_path().exists() {
        let _ = systemctl(&["disable", "--now", UNIT]);
        std::fs::remove_file(unit_path()).map_err(|error| format!("could not remove {}: {error}", unit_path().display()))?;
        systemctl(&["daemon-reload"])?;
    }
    println!("The host's service is removed.");
    Ok(())
}

/// Whether the daemon's last word on its line was "up", and it is still running to mean it.
fn relay_is_up(status: &str) -> bool {
    let mut words = status.split_whitespace();
    // SAFETY: signal 0 sends nothing: it only asks whether the process exists.
    words.next() == Some("up") && words.next().and_then(|id| id.parse::<i32>().ok()).is_some_and(|id| id > 0 && unsafe { libc::kill(id, 0) } == 0)
}

/// `agentboard status`.
pub fn status() -> Result<(), String> {
    let folder = config::data_folder();
    let config = Config::load(&folder)?;
    println!("Account: {}", config.login.as_deref().filter(|_| config.token.is_some()).unwrap_or("not signed in (run `agentboard login`)"));
    println!("Host:    {} ({})", config.name, config.id);
    // What a board shows before it trusts a changed identity: the same ten bytes, to compare.
    if let Ok(identity) = config.identity() {
        println!("Identity: {}", crate::boards::fingerprint(identity.verifying_key().as_bytes()));
    }
    println!("Boards:  {} trusted (`agentboard boards` lists them)", crate::boards::load(&folder)?.trusted.len());
    let running = cfg!(target_os = "linux") && systemctl(&["is-active", "--quiet", UNIT]).is_ok();
    println!("Service: {}", if running { "running" } else { "not running" });
    let up = std::fs::read_to_string(crate::relay::status_file(&folder)).is_ok_and(|status| relay_is_up(&status));
    println!("Relay:   {}", if up { "connected to the account" } else { "not connected" });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_runs_the_core_and_restarts_it() {
        let unit = unit("/home/u/.local/bin/agent board");
        assert!(unit.contains("ExecStart=\"/home/u/.local/bin/agent board\" host\n"));
        assert!(unit.contains("Restart=always\n") && unit.contains("WantedBy=default.target\n") && !unit.contains("KillMode"));
    }

    #[test]
    fn relay_is_up_only_while_its_daemon_lives() {
        assert!(relay_is_up(&format!("up {}\n", std::process::id())));
        assert!(!relay_is_up(&format!("down {}\n", std::process::id())));
        // Far above any real process id.
        assert!(!relay_is_up("up 2000000000\n"));
        assert!(!relay_is_up("") && !relay_is_up("up") && !relay_is_up("up 0") && !relay_is_up("up -1"));
    }
}
