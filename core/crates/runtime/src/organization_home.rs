//! Where an organization's agents keep their Claude Code login. Each organization other than the
//! default one gets its own config folder (`CLAUDE_CONFIG_DIR`), so `/login` in one of its agents
//! signs in that organization only. Everything else in `~/.claude` (skills, commands, agents,
//! settings, transcripts…) is linked in, so it stays shared. The default organization uses
//! `~/.claude` itself.

use std::path::{Path, PathBuf};

use crate::{data_folder, Uuid};

/// The organization every install starts with, and the one cards made before organizations
/// belong to.
pub const DEFAULT_ID: Uuid = Uuid::from_bytes([0; 16]);

/// What stays per organization: the login.
const OWN_ENTRIES: [&str; 2] = [".credentials.json", ".claude.json"];

/// The organization's own folder in the data folder (its icon lives there too).
pub fn folder(id: Uuid) -> PathBuf {
    data_folder::url().join("organizations").join(id.lowercased())
}

/// The `CLAUDE_CONFIG_DIR` of the organization's agents, none for the default one.
pub fn claude_directory(id: Option<Uuid>) -> Option<PathBuf> {
    id.filter(|id| *id != DEFAULT_ID).map(|id| folder(id).join("claude"))
}

/// Creates the organization's config folder the first time, signed in as `~/.claude` is, and
/// links in whatever `~/.claude` gained since. Returns the folder, none for the default one.
pub fn prepare(id: Option<Uuid>) -> Option<PathBuf> {
    let directory = claude_directory(id)?;
    prepare_directory(&directory, &data_folder::home_directory());
    Some(directory)
}

fn prepare_directory(directory: &Path, home: &Path) {
    let is_new = !directory.exists();
    let _ = std::fs::create_dir_all(directory);
    link_shared(directory, &home.join(".claude"));
    if is_new {
        inherit_login(directory, home);
    }
}

/// Links each entry of `~/.claude` that isn't the login, leaving alone what the folder
/// already has (its own files win).
fn link_shared(directory: &Path, user_claude: &Path) {
    let Ok(entries) = std::fs::read_dir(user_claude) else { return };
    for name in entries.flatten().map(|entry| entry.file_name()) {
        if OWN_ENTRIES.iter().any(|own| name == *own) {
            continue;
        }
        let link = directory.join(&name);
        // Not `exists`, which follows links: a dangling one is still there.
        if link.symlink_metadata().is_err() {
            let _ = std::os::unix::fs::symlink(user_claude.join(&name), link);
        }
    }
}

/// Copies the user's Claude Code login into a new organization: the account file and the
/// credentials file when there is one. Anything that fails just leaves the organization signed
/// out: `/login` in one of its agents fixes it.
// shortcut: the macOS keychain item Claude Code reads for a custom config folder isn't copied
// (on Linux the login is these files); port `inheritKeychainLogin` when this core runs agents on a Mac.
fn inherit_login(directory: &Path, home: &Path) {
    let _ = std::fs::copy(home.join(".claude.json"), directory.join(".claude.json"));
    let _ = std::fs::copy(home.join(".claude/.credentials.json"), directory.join(".credentials.json"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_organization_shares_everything_but_the_login() {
        let home = std::env::temp_dir().join(format!("aborg-{}", Uuid::new()));
        let claude = home.join(".claude");
        std::fs::create_dir_all(claude.join("skills")).unwrap();
        std::fs::write(claude.join("settings.json"), "{}").unwrap();
        std::fs::write(claude.join(".credentials.json"), "secret").unwrap();
        std::fs::write(home.join(".claude.json"), "account").unwrap();
        let directory = home.join("data/organizations/x/claude");

        prepare_directory(&directory, &home);
        assert_eq!(std::fs::read_link(directory.join("skills")).unwrap(), claude.join("skills"));
        assert_eq!(std::fs::read_link(directory.join("settings.json")).unwrap(), claude.join("settings.json"));
        // The login is a copy: signing in here leaves the user's own alone.
        assert!(!directory.join(".credentials.json").symlink_metadata().unwrap().is_symlink());
        assert_eq!(std::fs::read_to_string(directory.join(".credentials.json")).unwrap(), "secret");
        assert_eq!(std::fs::read_to_string(directory.join(".claude.json")).unwrap(), "account");

        // Later: what `~/.claude` gained is linked, and a changed login isn't copied again.
        std::fs::write(directory.join(".credentials.json"), "own").unwrap();
        std::fs::write(claude.join("CLAUDE.md"), "").unwrap();
        prepare_directory(&directory, &home);
        assert!(directory.join("CLAUDE.md").symlink_metadata().unwrap().is_symlink());
        assert_eq!(std::fs::read_to_string(directory.join(".credentials.json")).unwrap(), "own");

        assert_eq!(claude_directory(None), None);
        assert_eq!(claude_directory(Some(DEFAULT_ID)), None);
        std::fs::remove_dir_all(&home).unwrap();
    }
}
