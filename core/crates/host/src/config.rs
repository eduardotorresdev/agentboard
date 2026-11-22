//! This host's identity and account, kept in `host.json` in the data folder.

use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

pub const DEPLOYED: &str = "https://agentboard.eduardotorres.dev";

#[derive(Serialize, Deserialize)]
pub struct Config {
    /// A UUID made once; the account server knows the host by it.
    pub id: String,
    /// The Ed25519 identity key's seed, base64.
    key: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login: Option<String>,
}

impl Drop for Config {
    fn drop(&mut self) {
        self.key.zeroize();
        self.token.zeroize();
    }
}

impl Config {
    /// The config in `folder`, made (and saved) the first time.
    pub fn load(folder: &Path) -> Result<Config, String> {
        let path = folder.join("host.json");
        match fs::read(&path) {
            Ok(bytes) => {
                let bytes = Zeroizing::new(bytes);
                let config: Config = serde_json::from_slice(&bytes).map_err(|error| format!("{} is not valid: {error}", path.display()))?;
                config.identity()?;
                Ok(config)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let mut seed = Zeroizing::new([0u8; 32]);
                getrandom::getrandom(&mut *seed).map_err(|error| format!("no random bytes: {error}"))?;
                let config = Config { id: uuid::Uuid::new_v4().to_string(), key: STANDARD.encode(*seed), name: hostname(), token: None, login: None };
                config.save(folder)?;
                Ok(config)
            }
            Err(error) => Err(format!("could not read {}: {error}", path.display())),
        }
    }

    pub fn save(&self, folder: &Path) -> Result<(), String> {
        let failed = |error: std::io::Error| format!("could not write host.json in {}: {error}", folder.display());
        fs::DirBuilder::new().recursive(true).mode(0o700).create(folder).map_err(failed)?;
        fs::set_permissions(folder, fs::Permissions::from_mode(0o700)).map_err(failed)?;
        // Written aside and renamed: a crash never leaves half an identity.
        let aside = folder.join("host.json.new");
        let _ = fs::remove_file(&aside);
        let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&aside).map_err(failed)?;
        let text = Zeroizing::new(serde_json::to_vec_pretty(self).map_err(|error| error.to_string())?);
        file.write_all(&text).and_then(|_| file.sync_all()).map_err(failed)?;
        fs::rename(&aside, folder.join("host.json")).map_err(failed)
    }

    pub fn identity(&self) -> Result<SigningKey, String> {
        let mut seed = Zeroizing::new([0u8; 32]);
        match STANDARD.decode_slice(&self.key, &mut *seed) {
            Ok(32) if self.key.len() == 44 => Ok(SigningKey::from_bytes(&seed)),
            _ => Err("host.json holds no valid identity key".into()),
        }
    }

    /// What the host registers: the identity key's public half, base64.
    pub fn public_key(&self) -> Result<String, String> {
        Ok(STANDARD.encode(self.identity()?.verifying_key().as_bytes()))
    }
}

/// The data folder, by the core's rules (`runtime::data_folder`).
pub fn data_folder() -> PathBuf {
    let home = std::env::home_dir().unwrap_or_else(|| "/".into());
    if let Some(path) = std::env::var("AGENTBOARD_HOME").ok().filter(|path| !path.is_empty()) {
        return match path.strip_prefix('~').filter(|rest| rest.is_empty() || rest.starts_with('/')) {
            Some(rest) => PathBuf::from(format!("{}{rest}", home.display())),
            None => path.into(),
        };
    }
    if cfg!(target_os = "macos") {
        return home.join("Library/Application Support/AgentBoard");
    }
    let data = std::env::var("XDG_DATA_HOME").ok().filter(|path| path.starts_with('/')).map(PathBuf::from);
    data.unwrap_or_else(|| home.join(".local/share")).join("agentboard")
}

pub fn server() -> String {
    let url = std::env::var("AGENTBOARD_SERVER").ok().filter(|url| !url.is_empty()).unwrap_or_else(|| DEPLOYED.into());
    url.trim_end_matches('/').to_string()
}

/// The machine's name, within what the server takes for a host's (1 to 64 characters, no
/// control characters, not blank at either end).
fn hostname() -> String {
    let mut bytes = [0u8; 256];
    // SAFETY: gethostname writes at most the given length; the last byte stays 0.
    unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len() - 1) };
    let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(0);
    let name: String = String::from_utf8_lossy(&bytes[..end]).chars().filter(|c| !c.is_control()).take(64).collect();
    let name = name.trim();
    if name.is_empty() { "host".into() } else { name.into() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_is_made_once_and_kept_private() {
        let folder = crate::test_support::temporary("config").join("nested");
        let made = Config::load(&folder).unwrap();
        assert!(uuid::Uuid::parse_str(&made.id).is_ok_and(|id| id.get_version_num() == 4));
        assert!(!made.name.is_empty() && made.token.is_none());
        assert_eq!(made.public_key().unwrap().len(), 44);
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&folder), 0o700);
        assert_eq!(mode(&folder.join("host.json")), 0o600);

        let mut again = Config::load(&folder).unwrap();
        assert_eq!((again.id.as_str(), again.public_key().unwrap()), (made.id.as_str(), made.public_key().unwrap()));
        again.token = Some("secret".into());
        // A folder and file someone loosened are tightened on the next save.
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(folder.join("host.json"), fs::Permissions::from_mode(0o644)).unwrap();
        again.save(&folder).unwrap();
        assert_eq!(mode(&folder), 0o700);
        assert_eq!(mode(&folder.join("host.json")), 0o600);
        assert_eq!(Config::load(&folder).unwrap().token.as_deref(), Some("secret"));
    }

    #[test]
    fn a_damaged_identity_is_refused_not_replaced() {
        let folder = crate::test_support::temporary("config-bad");
        fs::write(folder.join("host.json"), r#"{"id":"x","key":"AAAA","name":"n"}"#).unwrap();
        assert!(Config::load(&folder).is_err());
    }
}
