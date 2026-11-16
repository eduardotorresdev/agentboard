//! "The vault" in docs/hosts.md: what every host of the account should have, sealed so the
//! server can't read it, applied to this host's home by `agentboard vault pull`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use base64::{engine::general_purpose::STANDARD, Engine};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::ChaCha20Poly1305;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::account::{Api, Failed};
use crate::config::{self, Config};

const INFO: &[u8] = b"agentboard vault v1";
const BLOB: &[u8] = b"agentboard vault blob v1";
/// The most plain bytes in one chunk.
const CHUNK: usize = 1_000_000;
/// The most sealed bytes the server keeps for one chunk.
/// The most one manifest may inflate to.
const MANIFEST: usize = 16 * 1024 * 1024;
/// How many chunks one `chunks/get` asks for, and the most bytes its reply may hold.
const BATCH: usize = 200;
const BATCH_REPLY: u64 = 8 * 1024 * 1024;
const NONCE: usize = 12;
pub const NO_KEY: &str = "No vault key here yet: a board this host trusts hands it over when it connects.";

type Key = Zeroizing<[u8; 32]>;

fn cipher(key: &[u8; 32]) -> ChaCha20Poly1305 {
    let mut derived = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(None, key).expand(INFO, &mut *derived).expect("32 bytes");
    ChaCha20Poly1305::new_from_slice(&*derived).expect("32 bytes")
}

/// Boards seal; the host only opens (and its tests seal what it opens).
#[cfg(test)]
fn seal_with(key: &[u8; 32], nonce: &[u8; NONCE], plain: &[u8]) -> Vec<u8> {
    let sealed = cipher(key).encrypt(nonce.into(), plain).expect("in memory");
    [&nonce[..], &sealed].concat()
}

/// Its plain bytes, at most `limit` of them, or None when it wasn't sealed under `key`, was
/// altered, or inflates past `limit` (a zlib bomb). What is sealed is one byte saying how the
/// rest is packed: `0` as it is, `1` zlib.
fn open(key: &[u8; 32], sealed: &[u8], limit: usize) -> Option<Vec<u8>> {
    let (nonce, rest) = sealed.split_at_checked(NONCE)?;
    let packed = Zeroizing::new(cipher(key).decrypt(nonce.into(), rest).ok()?);
    let plain = match packed.split_first()? {
        (0, plain) => plain.to_vec(),
        (1, deflated) => {
            let mut plain = Vec::new();
            flate2::read::ZlibDecoder::new(deflated).take(limit as u64 + 1).read_to_end(&mut plain).ok()?;
            plain
        }
        _ => return None,
    };
    (plain.len() <= limit).then_some(plain)
}

/// A chunk's id: lowercase hex HMAC-SHA256 under the vault key, so it says nothing without it.
fn chunk_id(key: &[u8; 32], plain: &[u8]) -> String {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("any length");
    mac.update(BLOB);
    mac.update(plain);
    mac.finalize().into_bytes().iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_key(text: &str) -> Option<Key> {
    let mut key = Zeroizing::new([0u8; 32]);
    let text = text.trim();
    matches!(STANDARD.decode_slice(text, &mut *key), Ok(32) if text.len() == 44).then_some(key)
}

/// `vault.key`: the key as base64, one line.
fn load_key(folder: &Path) -> Result<Option<Key>, String> {
    match fs::read_to_string(folder.join("vault.key")).map(Zeroizing::new) {
        Ok(text) => decode_key(&text).map(Some).ok_or_else(|| "vault.key holds no valid key".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("could not read vault.key: {error}")),
    }
}

/// Keeps `key` unless another is held: a key is never replaced.
fn store_key(folder: &Path, key: &[u8; 32]) -> Result<(), &'static str> {
    if let Some(held) = load_key(folder).map_err(|_| "unreadable_key")? {
        return if *held == *key { Ok(()) } else { Err("different_key") };
    }
    let aside = folder.join("vault.key.new");
    let _ = fs::remove_file(&aside);
    let written = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&aside).and_then(|mut file| {
        file.write_all(Zeroizing::new(format!("{}\n", STANDARD.encode(key))).as_bytes())?;
        file.sync_all()
    });
    // A link, not a rename: two boards setting keys at once can't replace each other's.
    let linked = written.and_then(|_| fs::hard_link(&aside, folder.join("vault.key")));
    let _ = fs::remove_file(&aside);
    match linked {
        Ok(()) => Ok(()),
        Err(_) => match load_key(folder) {
            Ok(Some(held)) if *held == *key => Ok(()),
            Ok(Some(_)) => Err("different_key"),
            _ => Err("could_not_write"),
        },
    }
}

/// A channel carrying `vault`: one JSON line in, one out.
pub fn answer(folder: &Path, request: &[u8]) -> String {
    let request: Value = serde_json::from_slice(request).unwrap_or_default();
    let reply = if request.get("get").is_some() {
        match load_key(folder) {
            Ok(Some(key)) => json!({ "key": STANDARD.encode(*key) }),
            Ok(None) => json!({ "error": "no_key" }),
            Err(_) => json!({ "error": "unreadable_key" }),
        }
    } else if let Some(key) = request["set"]["key"].as_str().and_then(decode_key) {
        match store_key(folder, &key) {
            Ok(()) => json!({ "ok": true }),
            Err(error) => json!({ "error": error }),
        }
    } else {
        json!({ "error": "invalid_request" })
    };
    format!("{reply}\n")
}

#[derive(Deserialize)]
struct Manifest {
    #[serde(default)]
    files: Vec<Entry>,
    #[serde(default)]
    mcp: Map<String, Value>,
    #[serde(default)]
    pins: BTreeMap<String, String>,
    github: Option<Github>,
    git: Option<Git>,
    #[serde(default)]
    hosts: BTreeMap<String, PerHost>,
}

#[derive(Deserialize)]
struct Entry {
    path: String,
    mode: u32,
    size: u64,
    chunks: Vec<String>,
}

#[derive(Deserialize)]
struct Github {
    token: String,
}

#[derive(Deserialize)]
struct Git {
    name: String,
    email: String,
}

#[derive(Deserialize, Default)]
struct PerHost {
    #[serde(default)]
    mcp: Map<String, Value>,
    #[serde(default)]
    without: Vec<String>,
}

impl Manifest {
    /// The account's servers, minus what this host leaves out, then its own over them.
    fn servers(&self, host: &str) -> Map<String, Value> {
        let host = uuid::Uuid::parse_str(host).ok();
        let mine = self.hosts.iter().find(|(id, _)| host.is_some() && uuid::Uuid::parse_str(id).ok() == host).map(|(_, own)| own);
        let mut servers = self.mcp.clone();
        if let Some(own) = mine {
            own.without.iter().for_each(|name| drop(servers.remove(name)));
            servers.extend(own.mcp.clone());
        }
        servers
    }
}

#[derive(Default, Debug, PartialEq)]
pub struct Report {
    pub version: u64,
    /// Files written this time (the ones already as the vault has them aren't).
    pub files: usize,
    pub removed: usize,
    pub servers: Vec<String>,
    /// (server, command) of each server whose program isn't on this host.
    pub lacking: Vec<(String, String)>,
    pub github: bool,
}

impl Report {
    pub fn line(&self) -> String {
        let lacking: Vec<Value> = self.lacking.iter().map(|(server, command)| json!({ "server": server, "command": command })).collect();
        json!({ "version": self.version, "files": self.files, "removed": self.removed, "servers": self.servers, "lacking": lacking, "github": self.github }).to_string()
    }
}

/// Where programs are looked for: the user's own first, as the service's PATH has it.
fn search_path(home: &Path) -> String {
    format!("{}/.local/bin:{}", home.display(), std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".into()))
}

fn refused(path: &str) -> String {
    format!("the vault names a path this host won't write: {path:?}")
}

/// Where `relative` lands: under `<home>/.claude/`, never through a link (`.claude` itself
/// included) or `..`, and not onto a folder.
fn target(home: &Path, relative: &str) -> Result<PathBuf, String> {
    let path = Path::new(relative);
    let mut parts = path.components();
    let under_claude = parts.next() == Some(Component::Normal(".claude".as_ref())) && parts.clone().next().is_some() && parts.all(|part| matches!(part, Component::Normal(_)));
    if !under_claude {
        return Err(refused(relative));
    }
    let full = home.join(path);
    let mut at = home.to_path_buf();
    for part in path.components() {
        at.push(part);
        match fs::symlink_metadata(&at) {
            Ok(meta) if meta.file_type().is_symlink() || (at != full && !meta.is_dir()) || (at == full && meta.is_dir()) => return Err(refused(relative)),
            Ok(_) => {}
            // Nothing below a missing folder exists either.
            Err(_) => break,
        }
    }
    Ok(full)
}

fn write_atomically(path: &Path, bytes: &[u8], mode: u32) -> Result<(), String> {
    let failed = |error: std::io::Error| format!("could not write {}: {error}", path.display());
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let aside = path.with_file_name(format!(".{name}.vault-new"));
    let _ = fs::remove_file(&aside);
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(mode).open(&aside).map_err(failed)?;
    let done = file.write_all(bytes).and_then(|_| file.sync_all()).and_then(|_| fs::set_permissions(&aside, fs::Permissions::from_mode(mode))).and_then(|_| fs::rename(&aside, path));
    if done.is_err() {
        let _ = fs::remove_file(&aside);
    }
    done.map_err(failed)
}

/// Writes one file of the manifest; false when it already held those bytes.
fn write_file(home: &Path, entry: &Entry, key: &[u8; 32], api: &Api, token: &str) -> Result<bool, String> {
    let path = target(home, &entry.path)?;
    let mode = entry.mode & 0o777;
    // Already as the vault has it: nothing to fetch.
    if let Ok(bytes) = fs::read(&path).map(Zeroizing::new) {
        if bytes.len() as u64 == entry.size && bytes.chunks(CHUNK).map(|chunk| chunk_id(key, chunk)).eq(entry.chunks.iter().cloned()) {
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).map_err(|error| format!("{}: {error}", path.display()))?;
            return Ok(false);
        }
    }
    let chunks = fetch_chunks(&entry.chunks, key, api, token).map_err(|error| format!("{}: {error}", entry.path))?;
    let mut plain = Zeroizing::new(Vec::new());
    for id in &entry.chunks {
        plain.extend_from_slice(&chunks[id]);
    }
    if plain.len() as u64 != entry.size {
        return Err(format!("{} came out the wrong size", entry.path));
    }
    fs::create_dir_all(path.parent().expect("under .claude")).map_err(|error| format!("{}: {error}", entry.path))?;
    // Checked again now that its folders exist: none of them may have become a link meanwhile.
    target(home, &entry.path)?;
    write_atomically(&path, &plain, mode)?;
    Ok(true)
}

/// The chunks named, opened and checked, many per request: a reply holds what fits in 8 MiB,
/// so what didn't come is asked for again.
fn fetch_chunks(ids: &[String], key: &[u8; 32], api: &Api, token: &str) -> Result<HashMap<String, Zeroizing<Vec<u8>>>, String> {
    let mut chunks = HashMap::new();
    loop {
        let wanted: Vec<&String> = ids.iter().filter(|id| !chunks.contains_key(*id)).collect::<HashSet<_>>().into_iter().take(BATCH).collect();
        if wanted.is_empty() {
            return Ok(chunks);
        }
        let reply = api.post_bytes("/v1/vault/chunks/get", token, json!({ "ids": wanted }), BATCH_REPLY).map_err(|failed| failed.to_string())?;
        let mut rest = &reply[..];
        let before = chunks.len();
        // Each one: id (64 ASCII hex) ‖ length (u32 big-endian) ‖ sealed bytes.
        while !rest.is_empty() {
            let (id, length, after) = rest.split_at_checked(68).map(|(head, after)| (&head[..64], u32::from_be_bytes(head[64..].try_into().unwrap()) as usize, after)).ok_or("the account server's chunks made no sense")?;
            let (sealed, after) = after.split_at_checked(length).ok_or("the account server's chunks made no sense")?;
            let id = String::from_utf8_lossy(id).into_owned();
            if !wanted.contains(&&id) {
                return Err("the account server sent a chunk that wasn't asked for".into());
            }
            let chunk = Zeroizing::new(open(key, sealed, CHUNK).ok_or("a chunk doesn't open with this host's key")?);
            if chunk_id(key, &chunk) != id {
                return Err("a chunk isn't the one it was named for".into());
            }
            chunks.insert(id, chunk);
            rest = after;
        }
        if chunks.len() == before {
            return Err("the account server lacks a chunk the vault names".into());
        }
    }
}

/// Removes a file an earlier version wrote, and the folders that leaves empty up to `.claude`.
fn remove_file(home: &Path, relative: &str) -> bool {
    let Ok(path) = target(home, relative) else { return false };
    if !fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file()) || fs::remove_file(&path).is_err() {
        return false;
    }
    let claude = home.join(".claude");
    let mut folder = path.parent();
    while let Some(at) = folder.filter(|at| *at != claude && at.starts_with(&claude)) {
        // Fails on a folder that still holds something, which ends the climb.
        if fs::remove_dir(at).is_err() {
            break;
        }
        folder = at.parent();
    }
    true
}

fn read_list(folder: &Path, name: &str) -> Vec<String> {
    fs::read(folder.join(name)).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

fn save_list(folder: &Path, name: &str, list: &[String]) -> Result<(), String> {
    write_atomically(&folder.join(name), &serde_json::to_vec(list).expect("strings"), 0o600)
}

/// `mcpServers` in `<home>/.claude.json`: the names the previous version put there go, this
/// version's come in; every other key and server stays.
fn merge_servers(home: &Path, previous: &[String], servers: &Map<String, Value>) -> Result<(), String> {
    if previous.is_empty() && servers.is_empty() {
        return Ok(());
    }
    let path = home.join(".claude.json");
    let mut config: Value = match fs::read(&path) {
        Ok(_) if fs::symlink_metadata(&path).is_ok_and(|meta| meta.file_type().is_symlink()) => return Err(format!("{} is a link: left as it is", path.display())),
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| format!("{} is not valid JSON: left as it is", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => json!({}),
        Err(error) => return Err(format!("could not read {}: {error}", path.display())),
    };
    let not_object = || format!("{} doesn't hold an object of servers: left as it is", path.display());
    let mine = config.as_object_mut().ok_or_else(not_object)?.entry("mcpServers").or_insert_with(|| json!({})).as_object_mut().ok_or_else(not_object)?;
    for name in previous {
        mine.remove(name);
    }
    mine.extend(servers.clone());
    write_atomically(&path, &serde_json::to_vec_pretty(&config).expect("JSON"), 0o600)
}

/// `<data folder>/synced-pins/<tool>.txt`, one per pin sent; the folder is the vault's alone.
fn write_pins(folder: &Path, pins: &BTreeMap<String, String>) -> Result<(), String> {
    let pins_folder = folder.join("synced-pins");
    fs::create_dir_all(&pins_folder).map_err(|error| format!("{}: {error}", pins_folder.display()))?;
    for (tool, text) in pins {
        write_atomically(&pins_folder.join(format!("{tool}.txt")), text.as_bytes(), 0o600)?;
    }
    for entry in fs::read_dir(&pins_folder).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.strip_suffix(".txt").is_some_and(|tool| !pins.contains_key(tool)) {
            let _ = fs::remove_file(entry.path());
        }
    }
    Ok(())
}

fn run(program: &str, arguments: &[&str], input: Option<&str>, home: &Path, path: &str) -> Option<std::process::Output> {
    // PATH set on the command is also where the program is looked for.
    let mut command = Command::new(program);
    command.args(arguments).env("PATH", path).env("HOME", home).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn().ok()?;
    if let Some(input) = input {
        let _ = child.stdin.take()?.write_all(input.as_bytes());
    }
    child.wait_with_output().ok()
}

fn succeeds(output: Option<std::process::Output>) -> bool {
    output.is_some_and(|output| output.status.success())
}

fn sign_in_github(token: &str, home: &Path, path: &str) -> bool {
    crate::setup::on_path("gh", path)
        && succeeds(run("gh", &["auth", "login", "--hostname", "github.com", "--with-token"], Some(token), home, path))
        && succeeds(run("gh", &["auth", "setup-git"], None, home, path))
}

/// The vault's git identity, for what the host has none of.
fn set_git_identity(git: &Git, home: &Path, path: &str) {
    if !crate::setup::on_path("git", path) {
        return;
    }
    for (setting, value) in [("user.name", &git.name), ("user.email", &git.email)] {
        let set = run("git", &["config", "--global", "--get", setting], None, home, path).is_some_and(|output| output.status.success() && !output.stdout.trim_ascii().is_empty());
        if !set && !value.is_empty() {
            let _ = run("git", &["config", "--global", setting, value], None, home, path);
        }
    }
}

/// Applies the account's vault to `home`, once per version. `host` is this host's id.
pub fn pull(folder: &Path, home: &Path, host: &str, api: &Api, token: &str) -> Result<Report, String> {
    let key = load_key(folder)?.ok_or(NO_KEY)?;
    let vault = match api.call("GET", "/v1/vault", Some(token), None) {
        Ok(vault) => vault,
        Err(Failed { status: 404, .. }) => return Ok(Report::default()),
        Err(failed) => return Err(failed.to_string()),
    };
    let nonsense = "the account server's vault made no sense";
    let version = vault["version"].as_u64().ok_or(nonsense)?;
    let sealed = STANDARD.decode(vault["manifest"].as_str().ok_or(nonsense)?).map_err(|_| nonsense)?;
    let plain = Zeroizing::new(open(&key, &sealed, MANIFEST).ok_or("the vault doesn't open with this host's key")?);
    let manifest: Manifest = serde_json::from_slice(&plain).map_err(|error| format!("the vault's manifest is not valid: {error}"))?;

    let path = search_path(home);
    let servers = manifest.servers(host);
    let lacking = servers
        .iter()
        .filter_map(|(name, server)| Some((name.clone(), server["command"].as_str()?.to_string())))
        .filter(|(_, command)| !command.contains('/') && !crate::setup::on_path(command, &path))
        .collect();
    let mut report = Report { version, servers: servers.keys().cloned().collect(), lacking, ..Report::default() };
    if fs::read_to_string(folder.join("vault.applied")).ok().and_then(|text| text.trim().parse().ok()) == Some(version) {
        return Ok(report);
    }

    // Every name checked before anything is written.
    for entry in &manifest.files {
        target(home, &entry.path)?;
    }
    if let Some(tool) = manifest.pins.keys().find(|tool| tool.is_empty() || tool.len() > 64 || tool.starts_with('.') || !tool.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))) {
        return Err(format!("the vault names a pin this host won't write: {tool:?}"));
    }

    for entry in &manifest.files {
        report.files += write_file(home, entry, &key, api, token)? as usize;
    }
    let kept: HashSet<&str> = manifest.files.iter().map(|entry| entry.path.as_str()).collect();
    for previous in read_list(folder, "vault.files").iter().filter(|path| !kept.contains(path.as_str())) {
        report.removed += remove_file(home, previous) as usize;
    }
    save_list(folder, "vault.files", &manifest.files.iter().map(|entry| entry.path.clone()).collect::<Vec<_>>())?;

    merge_servers(home, &read_list(folder, "vault.mcp"), &servers)?;
    save_list(folder, "vault.mcp", &report.servers)?;
    write_pins(folder, &manifest.pins)?;
    report.github = manifest.github.as_ref().is_some_and(|github| sign_in_github(&github.token, home, &path));
    if let Some(git) = &manifest.git {
        set_git_identity(git, home, &path);
    }
    write_atomically(&folder.join("vault.applied"), format!("{version}\n").as_bytes(), 0o600)?;
    Ok(report)
}

fn signed_in() -> Result<(PathBuf, Config, Zeroizing<String>), String> {
    let folder = config::data_folder();
    let config = Config::load(&folder)?;
    let token = config.token.clone().map(Zeroizing::new).ok_or("Not signed in: run `agentboard login`.")?;
    Ok((folder, config, token))
}

fn pull_here() -> Result<Report, String> {
    let (folder, config, token) = signed_in()?;
    let home = std::env::home_dir().ok_or("no home folder")?;
    pull(&folder, &home, &config.id, &Api::new(&config::server()), &token)
}

/// `agentboard vault pull`: the report, as one JSON line.
pub fn pull_command() -> Result<(), String> {
    println!("{}", pull_here()?.line());
    Ok(())
}

/// What the service runs once as it starts: never fatal.
pub fn pull_at_start() {
    std::thread::spawn(|| {
        if let Err(error) = pull_here() {
            eprintln!("vault: {error}");
        }
    });
}

/// `agentboard vault status`: never the key itself.
pub fn status() -> Result<(), String> {
    let folder = config::data_folder();
    let applied = fs::read_to_string(folder.join("vault.applied")).ok().map(|text| text.trim().to_string());
    println!("Applied: {}", applied.map_or("none yet".into(), |version| format!("version {version}")));
    println!("Key:     {}", if load_key(&folder)?.is_some() { "held" } else { "not held yet" });
    Ok(())
}

/// What `agentboard logout` forgets; the files the vault wrote stay.
pub fn forget(folder: &Path) {
    for name in ["vault.key", "vault.applied"] {
        let _ = fs::remove_file(folder.join(name));
    }
}

/// Reads at most `limit` bytes of a reply: a lying server can't fill memory.
pub(crate) fn read_limited(reader: impl Read, limit: u64) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(std::io::Error::other("reply too large"));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{read_request, temporary};
    use std::net::TcpListener;
    use std::os::unix::fs::symlink;
    use std::sync::{Arc, Mutex};

    const KEY: [u8; 32] = [7; 32];
    const HOST: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// The sealed form of `plain`: zlib (level 6, flate2's default) or as it is.
    fn pack(key: &[u8; 32], nonce: &[u8; NONCE], plain: &[u8], zlib: bool) -> Vec<u8> {
        let packed = if zlib {
            let mut encoder = flate2::write::ZlibEncoder::new(vec![1u8], flate2::Compression::default());
            encoder.write_all(plain).unwrap();
            encoder.finish().unwrap()
        } else {
            [&[0u8][..], plain].concat()
        };
        seal_with(key, nonce, &packed)
    }

    /// The account server's vault calls: the vault, and chunks many per request with replies
    /// cut at `REPLY` bytes; counts the chunks handed out.
    struct Server {
        url: String,
        routes: Arc<Mutex<HashMap<String, (u16, Vec<u8>)>>>,
        chunks: Arc<Mutex<HashMap<String, Vec<u8>>>>,
        fetched: Arc<Mutex<usize>>,
    }

    /// Small, so one file of two chunks needs two replies.
    const REPLY: usize = 1_000_000;

    impl Server {
        fn new() -> Server {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let routes: Arc<Mutex<HashMap<String, (u16, Vec<u8>)>>> = Arc::default();
            let fetched = Arc::new(Mutex::new(0));
            let chunks: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
            let (served, counted, held) = (routes.clone(), fetched.clone(), chunks.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let mut stream = stream.unwrap();
                    let request = read_request(&mut stream);
                    assert!(request.contains("Authorization: Bearer tok") || request.contains("authorization: Bearer tok"));
                    let path = request.split(' ').nth(1).unwrap().to_string();
                    let (status, body) = if path == "/v1/vault/chunks/get" {
                        let asked: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
                        let mut body = Vec::new();
                        for id in asked["ids"].as_array().unwrap().iter().map(|id| id.as_str().unwrap()) {
                            let Some(sealed) = held.lock().unwrap().get(id).cloned() else { continue };
                            if !body.is_empty() && body.len() + 68 + sealed.len() > REPLY {
                                break;
                            }
                            body.extend([id.as_bytes(), &(sealed.len() as u32).to_be_bytes(), &sealed].concat());
                            *counted.lock().unwrap() += 1;
                        }
                        (200, body)
                    } else {
                        served.lock().unwrap().get(&path).cloned().unwrap_or((404, br#"{"error":"not_found"}"#.to_vec()))
                    };
                    let head = format!("HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                    let _ = stream.write_all(&[head.as_bytes(), &body].concat());
                }
            });
            Server { url, routes, chunks, fetched }
        }

        /// Puts `files` (path, mode, bytes) and the rest of a manifest in the vault at `version`.
        fn publish(&self, key: &[u8; 32], version: u64, files: &[(&str, u32, &[u8])], rest: Value) {
            let mut routes = self.routes.lock().unwrap();
            let mut entries = Vec::new();
            for (path, mode, bytes) in files {
                // Compressed and not, by turns: a host takes both.
                let chunks: Vec<String> = bytes.chunks(CHUNK).enumerate().map(|(at, chunk)| {
                    let id = chunk_id(key, chunk);
                    self.chunks.lock().unwrap().insert(id.clone(), pack(key, &[1; 12], chunk, at % 2 == 0));
                    id
                }).collect();
                entries.push(json!({ "path": path, "mode": mode, "size": bytes.len(), "chunks": chunks }));
            }
            let mut manifest = json!({ "files": entries, "updated": 1, "by": "test" });
            manifest.as_object_mut().unwrap().extend(rest.as_object().unwrap().clone());
            let sealed = pack(key, &[2; 12], manifest.to_string().as_bytes(), true);
            routes.insert("/v1/vault".into(), (200, json!({ "version": version, "manifest": STANDARD.encode(sealed) }).to_string().into_bytes()));
        }

        fn pull(&self, folder: &Path, home: &Path) -> Result<Report, String> {
            pull(folder, home, HOST, &Api::new(&self.url), "tok")
        }
    }

    fn place() -> (PathBuf, PathBuf) {
        let root = temporary("vault");
        let (folder, home) = (root.join("data"), root.join("home"));
        fs::create_dir_all(&folder).unwrap();
        fs::create_dir_all(&home).unwrap();
        fs::write(folder.join("vault.key"), format!("{}\n", STANDARD.encode(KEY))).unwrap();
        (folder, home)
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    /// Fixed inputs, shared with the board's tests through `core/fixtures/vault.json`.
    #[test]
    fn vault_vectors() {
        let key: [u8; 32] = std::array::from_fn(|at| at as u8);
        let chunk = b"agentboard vault test chunk\n";
        let (chunk_nonce, manifest_nonce): ([u8; 12], [u8; 12]) = (std::array::from_fn(|at| 0x40 + at as u8), std::array::from_fn(|at| 0x50 + at as u8));
        let id = chunk_id(&key, chunk);
        let manifest = format!(
            r#"{{"files":[{{"path":".claude/CLAUDE.md","mode":420,"size":{},"chunks":["{id}"]}}],"mcp":{{"docs":{{"command":"npx","args":["-y","docs-mcp"]}}}},"pins":{{"claude":"2.0.1"}},"git":{{"name":"Octo Cat","email":"octo@example.com"}},"hosts":{{"{HOST}":{{"mcp":{{"local":{{"command":"local-mcp"}}}},"without":["docs"]}}}},"updated":1700000000,"by":"4604 7895 a6f2 8626 01ab"}}"#,
            chunk.len()
        );
        let mut sealing = [0u8; 32];
        Hkdf::<Sha256>::new(None, &key).expand(INFO, &mut sealing).unwrap();
        let sealed_chunk = pack(&key, &chunk_nonce, chunk, false);
        let sealed_manifest = pack(&key, &manifest_nonce, manifest.as_bytes(), false);
        // Compressed (zlib level 6): the board needs only to open these, not to make the same bytes.
        let repeated = chunk.repeat(8);
        let zlib_chunk = pack(&key, &chunk_nonce, &repeated, true);
        let zlib_manifest = pack(&key, &manifest_nonce, manifest.as_bytes(), true);
        let fixture = json!({
            "key": hex(&key),
            "sealing_key": hex(&sealing),
            "chunk": hex(chunk),
            "chunk_id": id,
            "chunk_nonce": hex(&chunk_nonce),
            "sealed_chunk": hex(&sealed_chunk),
            "manifest": manifest,
            "manifest_nonce": hex(&manifest_nonce),
            "sealed_manifest": STANDARD.encode(&sealed_manifest),
            "zlib_chunk": hex(&repeated),
            "zlib_chunk_id": chunk_id(&key, &repeated),
            "sealed_zlib_chunk": hex(&zlib_chunk),
            "sealed_zlib_manifest": STANDARD.encode(&zlib_manifest),
        });
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/vault.json");
        if std::env::var_os("AGENTBOARD_WRITE_FIXTURES").is_some() {
            fs::write(path, serde_json::to_string_pretty(&fixture).unwrap() + "\n").unwrap();
        }
        let stored: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(stored, fixture, "run with AGENTBOARD_WRITE_FIXTURES=1 to rewrite it");
        assert_eq!(open(&key, &sealed_chunk, CHUNK).unwrap(), chunk);
        assert_eq!(open(&key, &sealed_manifest, MANIFEST).unwrap(), manifest.as_bytes());
        assert_eq!(open(&key, &zlib_chunk, CHUNK).unwrap(), repeated);
        assert_eq!(open(&key, &zlib_manifest, MANIFEST).unwrap(), manifest.as_bytes());
        assert!(zlib_chunk.len() < repeated.len());
        assert_eq!(open(&[9; 32], &sealed_chunk, CHUNK), None);
        let mut altered = sealed_chunk.clone();
        altered[20] ^= 1;
        assert_eq!(open(&key, &altered, CHUNK), None);
        // An unknown packing, or one that inflates past the limit, opens to nothing.
        assert_eq!(open(&key, &seal_with(&key, &chunk_nonce, b"\x02abc"), CHUNK), None);
        assert_eq!(open(&key, &pack(&key, &chunk_nonce, &[0; CHUNK + 1], true), CHUNK), None);
        assert_eq!(open(&key, &pack(&key, &chunk_nonce, &[0; CHUNK], true), CHUNK).map(|plain| plain.len()), Some(CHUNK));
        assert_ne!(chunk_id(&[9; 32], chunk), id);
    }

    #[test]
    fn pulls_files_once_per_version_and_removes_only_its_own() {
        let (folder, home) = place();
        let server = Server::new();
        let big: Vec<u8> = (0..1_200_000u32).map(|at| at as u8).collect();
        server.publish(&KEY, 1, &[(".claude/CLAUDE.md", 0o644, b"hello"), (".claude/skills/x/SKILL.md", 0o600, b"skill"), (".claude/bin/run", 0o755, &big)], json!({}));
        let report = server.pull(&folder, &home).unwrap();
        assert_eq!((report.version, report.files, report.removed), (1, 3, 0));
        assert_eq!(fs::read(home.join(".claude/CLAUDE.md")).unwrap(), b"hello");
        assert_eq!(fs::read(home.join(".claude/bin/run")).unwrap(), big);
        assert_eq!((mode(&home.join(".claude/CLAUDE.md")), mode(&home.join(".claude/skills/x/SKILL.md")), mode(&home.join(".claude/bin/run"))), (0o644, 0o600, 0o755));
        assert_eq!(*server.fetched.lock().unwrap(), 4);
        fs::write(home.join(".claude/settings.json"), "host's own").unwrap();

        // The same version again: nothing fetched, nothing written.
        fs::write(home.join(".claude/CLAUDE.md"), "edited here").unwrap();
        assert_eq!(server.pull(&folder, &home).unwrap().files, 0);
        assert_eq!(fs::read(home.join(".claude/CLAUDE.md")).unwrap(), b"edited here");
        assert_eq!(*server.fetched.lock().unwrap(), 4);

        // A new one drops the skill: it goes with its folders; unchanged files aren't fetched.
        server.publish(&KEY, 2, &[(".claude/CLAUDE.md", 0o644, b"hello again"), (".claude/bin/run", 0o700, &big)], json!({}));
        let report = server.pull(&folder, &home).unwrap();
        assert_eq!((report.version, report.files, report.removed), (2, 1, 1));
        assert_eq!(*server.fetched.lock().unwrap(), 5);
        assert_eq!(mode(&home.join(".claude/bin/run")), 0o700);
        assert!(!home.join(".claude/skills").exists());
        assert_eq!(fs::read_to_string(home.join(".claude/settings.json")).unwrap(), "host's own");
        assert!(report.line().starts_with('{') && !report.line().contains('\n'));
    }

    #[test]
    fn refuses_paths_outside_claude_and_through_links() {
        let (folder, home) = place();
        let server = Server::new();
        let outside = home.join("outside");
        fs::create_dir_all(&outside).unwrap();
        fs::create_dir_all(home.join(".claude")).unwrap();
        symlink(&outside, home.join(".claude/linked")).unwrap();
        for path in ["../x", ".claude/../x", "/etc/passwd", ".claude", "x/.claude/y", ".claude/linked/x"] {
            server.publish(&KEY, 1, &[(".claude/fine.md", 0o644, b"fine"), (path, 0o644, b"bad")], json!({}));
            let error = server.pull(&folder, &home).unwrap_err();
            assert!(error.contains("won't write"), "{path}: {error}");
            assert!(!home.join(".claude/fine.md").exists() && !folder.join("vault.applied").exists(), "{path}");
        }
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
        // `.claude` itself a link: refused as well.
        let (folder, home) = place();
        symlink(&outside, home.join(".claude")).unwrap();
        server.publish(&KEY, 1, &[(".claude/fine.md", 0o644, b"fine")], json!({}));
        assert!(server.pull(&folder, &home).is_err());
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
    }

    #[test]
    fn merges_servers_keeping_the_hosts_own_and_applies_per_host_sections() {
        let (folder, home) = place();
        let server = Server::new();
        fs::write(home.join(".claude.json"), r#"{"theme":"dark","projects":{"a":1},"mcpServers":{"mine":{"command":"mine"},"shared":{"command":"old"}}}"#).unwrap();
        let other = "11111111-2222-4333-8444-555555555555";
        server.publish(&KEY, 1, &[], json!({
            "mcp": { "shared": { "command": "sh" }, "docs": { "command": "npx" }, "gone": { "command": "definitely-not-a-program-x" } },
            "hosts": {
                HOST.to_uppercase(): { "mcp": { "local": { "command": "local-only-program-x" }, "docs": { "command": "/opt/docs" } }, "without": ["gone"] },
                other: { "mcp": { "theirs": { "command": "sh" } } },
            },
            "pins": { "claude": "2.0.1", "codex": "0.5" },
        }));
        let report = server.pull(&folder, &home).unwrap();
        assert_eq!(report.servers, ["docs", "local", "shared"]);
        assert_eq!(report.lacking, [("local".to_string(), "local-only-program-x".to_string())]);
        let config: Value = serde_json::from_slice(&fs::read(home.join(".claude.json")).unwrap()).unwrap();
        assert_eq!(config["theme"], "dark");
        assert_eq!(config["projects"], json!({ "a": 1 }));
        assert_eq!(config["mcpServers"], json!({ "mine": { "command": "mine" }, "shared": { "command": "sh" }, "docs": { "command": "/opt/docs" }, "local": { "command": "local-only-program-x" } }));
        assert_eq!(mode(&home.join(".claude.json")), 0o600);
        assert_eq!(fs::read_to_string(folder.join("synced-pins/codex.txt")).unwrap(), "0.5");

        // The next version takes back what this one put there, and nothing of the host's.
        server.publish(&KEY, 2, &[], json!({ "mcp": { "docs": { "command": "npx" } }, "pins": { "claude": "2.0.2" } }));
        server.pull(&folder, &home).unwrap();
        let config: Value = serde_json::from_slice(&fs::read(home.join(".claude.json")).unwrap()).unwrap();
        assert_eq!(config["mcpServers"], json!({ "mine": { "command": "mine" }, "docs": { "command": "npx" } }));
        assert!(!folder.join("synced-pins/codex.txt").exists());
        assert_eq!(fs::read_to_string(folder.join("synced-pins/claude.txt")).unwrap(), "2.0.2");

        // Absent, the file is made.
        let (folder, home) = place();
        server.pull(&folder, &home).unwrap();
        assert!(fs::read_to_string(home.join(".claude.json")).unwrap().contains("npx"));
    }

    #[test]
    fn refuses_a_chunk_that_inflates_past_its_size() {
        let (folder, home) = place();
        let server = Server::new();
        server.publish(&KEY, 1, &[(".claude/CLAUDE.md", 0o644, b"x")], json!({}));
        // The id names one byte; what is sent inflates to 50 MB of zeros.
        let id = chunk_id(&KEY, b"x");
        server.chunks.lock().unwrap().insert(id, pack(&KEY, &[1; 12], &vec![0; 50_000_000], true));
        let error = server.pull(&folder, &home).unwrap_err();
        assert!(error.contains("doesn't open"), "{error}");
        assert!(!home.join(".claude").exists() && !folder.join("vault.applied").exists());
    }

    #[test]
    fn a_wrong_key_or_none_changes_nothing() {
        let (folder, home) = place();
        let server = Server::new();
        server.publish(&[9; 32], 1, &[(".claude/CLAUDE.md", 0o644, b"hello")], json!({ "mcp": { "x": { "command": "sh" } } }));
        let error = server.pull(&folder, &home).unwrap_err();
        assert!(error.contains("key") && !error.contains(&STANDARD.encode(KEY)), "{error}");
        assert_eq!(fs::read_dir(&home).unwrap().count(), 0);
        assert!(!folder.join("vault.applied").exists());
        fs::remove_file(folder.join("vault.key")).unwrap();
        assert_eq!(server.pull(&folder, &home).unwrap_err(), NO_KEY);
        // No vault on the account yet: nothing to do.
        let (folder, home) = place();
        assert_eq!(Server::new().pull(&folder, &home), Ok(Report::default()));
    }

    #[test]
    fn hands_the_key_to_a_trusted_board_and_never_replaces_it() {
        let folder = temporary("vault-key");
        let ask = |request: &str| serde_json::from_str::<Value>(&answer(&folder, request.as_bytes())).unwrap();
        assert_eq!(ask(r#"{"get":{}}"#), json!({ "error": "no_key" }));
        for bad in ["", "{}", r#"{"set":{}}"#, r#"{"set":{"key":"AAAA"}}"#] {
            assert_eq!(ask(bad), json!({ "error": "invalid_request" }), "{bad}");
        }
        let (one, two) = (STANDARD.encode([1u8; 32]), STANDARD.encode([2u8; 32]));
        assert_eq!(ask(&format!(r#"{{"set":{{"key":"{one}"}}}}"#)), json!({ "ok": true }));
        assert_eq!(ask(&format!(r#"{{"set":{{"key":"{one}"}}}}"#)), json!({ "ok": true }));
        assert_eq!(ask(&format!(r#"{{"set":{{"key":"{two}"}}}}"#)), json!({ "error": "different_key" }));
        assert_eq!(ask(r#"{"get":{}}"#), json!({ "key": one }));
        assert_eq!(mode(&folder.join("vault.key")), 0o600);
        forget(&folder);
        assert_eq!(ask(r#"{"get":{}}"#), json!({ "error": "no_key" }));
    }
}
