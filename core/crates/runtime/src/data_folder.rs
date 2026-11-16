//! Where the board and the core keep their state: the database, the core's socket and log,
//! the tool server's key. `AGENTBOARD_HOME` points it elsewhere, so a second instance (a build
//! under test) runs with its own data, agents and core.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The data folder of this process's environment.
pub fn url() -> PathBuf {
    match resolve(&std::env::vars().collect(), runs_under_tests()) {
        Resolution::Folder(folder) => folder,
        // Tests must never touch the user's data: a test core once swept their images.
        Resolution::Refuse(reason) => panic!("{reason}"),
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Resolution {
    Folder(PathBuf),
    Refuse(String),
}

/// The folder `environment` names; under tests, a refusal for the user's own folders (the
/// default one or a real install's, through a symlink or, on macOS, in another case too).
pub fn resolve(environment: &HashMap<String, String>, under_tests: bool) -> Resolution {
    let folder = folder(environment);
    if under_tests && is_real(&folder, environment) {
        return Resolution::Refuse(format!("AGENTBOARD_HOME must point to a temporary folder under tests, not {}", folder.display()));
    }
    Resolution::Folder(folder)
}

fn folder(environment: &HashMap<String, String>) -> PathBuf {
    match environment.get("AGENTBOARD_HOME").filter(|path| !path.is_empty()) {
        // As `expandingTildeInPath`, for the user's own home.
        Some(path) => match path.strip_prefix('~').filter(|rest| rest.is_empty() || rest.starts_with('/')) {
            Some(rest) => PathBuf::from(format!("{}{rest}", home(environment).display())),
            None => PathBuf::from(path),
        },
        None => real_folders(environment).remove(0),
    }
}

/// `HOME`, or the user's home in the password database when it isn't set.
pub fn home_directory() -> PathBuf {
    home(&std::env::vars().collect())
}

fn home(environment: &HashMap<String, String>) -> PathBuf {
    if let Some(home) = environment.get("HOME").filter(|home| !home.is_empty()) {
        return PathBuf::from(home);
    }
    // SAFETY: getpwuid returns null or a record valid until the next call; its directory is
    // copied out at once.
    unsafe {
        let record = libc::getpwuid(libc::getuid());
        if record.is_null() || (*record).pw_dir.is_null() {
            return PathBuf::from("/");
        }
        PathBuf::from(std::ffi::CStr::from_ptr((*record).pw_dir).to_string_lossy().into_owned())
    }
}

/// The user's folders: this build's default and, on macOS, the dev build's.
fn real_folders(environment: &HashMap<String, String>) -> Vec<PathBuf> {
    if cfg!(target_os = "macos") {
        let support = home(environment).join("Library/Application Support");
        return vec![support.join("AgentBoard"), support.join("AgentBoard Dev")];
    }
    let data = environment.get("XDG_DATA_HOME").filter(|path| path.starts_with('/')).map(PathBuf::from);
    vec![data.unwrap_or_else(|| home(environment).join(".local/share")).join("agentboard")]
}

/// Resolved, and on macOS without case: its volume is case-insensitive.
fn key(folder: &Path) -> String {
    let resolved = folder.canonicalize().unwrap_or_else(|_| folder.to_path_buf()).to_string_lossy().into_owned();
    if cfg!(target_os = "macos") {
        resolved.to_lowercase()
    } else {
        resolved
    }
}

fn is_real(folder: &Path, environment: &HashMap<String, String>) -> bool {
    real_folders(environment).iter().any(|real| key(real) == key(folder))
}

fn runs_under_tests() -> bool {
    cfg!(test) || std::env::var("AGENTBOARD_TEST").as_deref() == Ok("1")
}

/// Whether this instance runs with data of its own (a build under test, a harness): it must
/// then leave the user's shared state alone.
pub fn is_isolated(environment: &HashMap<String, String>) -> bool {
    !is_real(&folder(environment), environment)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect()
    }

    #[test]
    fn tests_never_resolve_the_users_folder() {
        let home = std::env::temp_dir().join(format!("abhome-{}", crate::Uuid::new()));
        std::fs::create_dir_all(&home).unwrap();
        let home_text = home.to_str().unwrap();
        let standard = match resolve(&environment(&[("HOME", home_text)]), false) {
            Resolution::Folder(folder) => folder,
            refused => panic!("{refused:?}"),
        };
        assert!(standard.starts_with(&home));
        std::fs::create_dir_all(&standard).unwrap();
        let link = home.join("link");
        std::os::unix::fs::symlink(&standard, &link).unwrap();
        let refused = |home_override: &str| matches!(resolve(&environment(&[("HOME", home_text), ("AGENTBOARD_HOME", home_override)]), true), Resolution::Refuse(_));

        assert!(matches!(resolve(&environment(&[("HOME", home_text)]), true), Resolution::Refuse(_)));
        assert!(refused(standard.to_str().unwrap()));
        assert!(refused(link.to_str().unwrap()));
        assert!(!refused(home.join("elsewhere").to_str().unwrap()));
        assert!(is_isolated(&environment(&[("HOME", home_text), ("AGENTBOARD_HOME", "/tmp/other")])));
        assert!(!is_isolated(&environment(&[("HOME", home_text)])));
        assert_eq!(resolve(&environment(&[("HOME", home_text), ("AGENTBOARD_HOME", "~/x")]), false), Resolution::Folder(home.join("x")));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn linux_follows_the_xdg_data_home() {
        let folder = |pairs: &[(&str, &str)]| resolve(&environment(pairs), false);
        assert_eq!(folder(&[("HOME", "/home/u")]), Resolution::Folder("/home/u/.local/share/agentboard".into()));
        assert_eq!(folder(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "/data")]), Resolution::Folder("/data/agentboard".into()));
    }
}
