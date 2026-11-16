//! "Board identity" in docs/hosts.md: the boards this host trusts and the ones waiting to be,
//! kept in `boards.json` in the data folder, and the `boards`, `trust` and `untrust`
//! subcommands. Every admission reads the file again, so the daemon and the commands agree.

use std::fs;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;

use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::config;

/// The most boards kept waiting: anybody the account server lets through can add one.
const MOST_PENDING: usize = 8;
/// One new waiting board is recorded per this many seconds.
const EVERY: u64 = 10;
/// A board that waits tries again every 30 seconds: one silent this long has gone, and its
/// place (and its row in every trusted board's menu) with it.
const STALE: u64 = 5 * 60;
/// How long `login` waits for a board, and how long the first to connect is trusted unasked.
pub const FIRST_USE: u64 = 15 * 60;
pub const WHERE: &str = "The same fingerprint shows in that computer's account menu.";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Trusted {
    pub key: String,
    pub name: String,
    pub added: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Pending {
    pub key: String,
    pub name: String,
    pub first_seen: u64,
    pub last_seen: u64,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct List {
    #[serde(default)]
    pub trusted: Vec<Trusted>,
    #[serde(default)]
    pub pending: Vec<Pending>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_use_until: Option<u64>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    Trusted,
    /// With how many boards this host trusts.
    Pending(usize),
}

pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |time| time.as_secs())
}

/// What people compare: the first 10 bytes of the key's SHA-256, in five groups of four.
pub fn fingerprint(key: &[u8]) -> String {
    let groups: Vec<String> = Sha256::digest(key)[..10].chunks(2).map(|pair| format!("{:02x}{:02x}", pair[0], pair[1])).collect();
    groups.join(" ")
}

/// The fingerprint of a key as the list stores it.
fn stored_fingerprint(key: &str) -> String {
    fingerprint(&STANDARD.decode(key).unwrap_or_default())
}

/// A name as it is stored and shown: whoever sends a proof picks it, so nothing in it may
/// move a terminal's cursor or reorder the line it is printed on.
fn sanitized(name: &[u8]) -> String {
    let hidden = |c: char| c.is_control() || matches!(c, '\u{200b}'..='\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}');
    let mut name: String = String::from_utf8_lossy(name).chars().filter(|c| !hidden(*c)).collect();
    while name.len() > 64 {
        name.pop();
    }
    name
}

pub fn load(folder: &Path) -> Result<List, String> {
    let path = folder.join("boards.json");
    match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| format!("{} is not valid: {error}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(List::default()),
        Err(error) => Err(format!("could not read {}: {error}", path.display())),
    }
}

/// Held from reading the list to writing it back: the daemon's threads and the commands
/// change it at once, and an `untrust` must never be undone by a stale copy.
fn lock(folder: &Path) -> Result<fs::File, String> {
    let failed = |error: std::io::Error| format!("could not lock the boards list in {}: {error}", folder.display());
    fs::DirBuilder::new().recursive(true).mode(0o700).create(folder).map_err(failed)?;
    let file = fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(folder.join("boards.lock")).map_err(failed)?;
    // SAFETY: flock only takes a descriptor, open for as long as `file` lives.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(failed(std::io::Error::last_os_error()));
    }
    Ok(file)
}

fn save(folder: &Path, list: &List) -> Result<(), String> {
    let failed = |error: std::io::Error| format!("could not write boards.json in {}: {error}", folder.display());
    // Written aside and renamed: a reader never sees half a list.
    let aside = folder.join("boards.json.new");
    let _ = fs::remove_file(&aside);
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&aside).map_err(failed)?;
    let text = serde_json::to_vec_pretty(list).map_err(|error| error.to_string())?;
    file.write_all(&text).and_then(|_| file.sync_all()).map_err(failed)?;
    fs::rename(&aside, folder.join("boards.json")).map_err(failed)
}

/// Reads the list, changes it, and writes it back when `change` says it did.
fn update<T>(folder: &Path, change: impl FnOnce(&mut List) -> (T, bool)) -> Result<T, String> {
    let _lock = lock(folder)?;
    let mut list = load(folder)?;
    let (result, changed) = change(&mut list);
    if changed {
        save(folder, &list)?;
    }
    Ok(result)
}

/// What a board that proved it holds `key` gets. Only called after its proof was checked.
pub fn admit(folder: &Path, key: &[u8; 32], name: &[u8], now: u64) -> Result<Verdict, String> {
    let (key, name) = (STANDARD.encode(key), sanitized(name));
    update(folder, |list| {
        let before = list.pending.len();
        list.pending.retain(|board| now.saturating_sub(board.last_seen) < STALE);
        let pruned = list.pending.len() != before;
        if let Some(board) = list.trusted.iter_mut().find(|board| board.key == key) {
            // Trusted by its key alone, at the terminal: it says what it calls itself now.
            let named = board.name.is_empty() && !name.is_empty();
            if named {
                board.name = name;
            }
            return (Verdict::Trusted, named || pruned);
        }
        // A window that ended never opens again, whatever the clock does later.
        let open = list.first_use_until.take().is_some_and(|until| now < until);
        if open && list.trusted.is_empty() {
            list.pending.retain(|board| board.key != key);
            list.trusted.push(Trusted { key, name, added: now });
            return (Verdict::Trusted, true);
        }
        let verdict = Verdict::Pending(list.trusted.len());
        if let Some(known) = list.pending.iter_mut().find(|board| board.key == key) {
            let changed = known.last_seen != now;
            known.last_seen = now;
            return (verdict, changed || open || pruned);
        }
        if list.pending.iter().any(|board| now.abs_diff(board.first_seen) < EVERY) {
            return (verdict, pruned);
        }
        if list.pending.len() >= MOST_PENDING {
            let oldest = (0..list.pending.len()).min_by_key(|at| list.pending[*at].last_seen).expect("not empty");
            list.pending.remove(oldest);
        }
        list.pending.push(Pending { key, name, first_seen: now, last_seen: now });
        (verdict, true)
    })
}

/// Trusts a waiting board; false when `key` isn't waiting.
pub fn trust(folder: &Path, key: &str, now: u64) -> Result<bool, String> {
    update(folder, |list| {
        let done = promote(list, key, now);
        (done, done)
    })
}

/// Trusts a key whether or not a board showed it yet: what somebody at this host's terminal
/// may always do, so nobody can keep a board out by crowding the waiting list.
fn trust_key(folder: &Path, key: &str, now: u64) -> Result<(), String> {
    update(folder, |list| {
        let waiting = list.pending.iter().position(|board| board.key == key).map(|at| list.pending.remove(at));
        if !list.trusted.iter().any(|board| board.key == key) {
            list.trusted.push(Trusted { key: key.to_string(), name: waiting.map(|board| board.name).unwrap_or_default(), added: now });
        }
        list.first_use_until = None;
        ((), true)
    })
}

/// Stops trusting a board; false when `key` isn't trusted. Never opens a first-use window:
/// a host left with no board has every board waiting.
pub fn forget(folder: &Path, key: &str) -> Result<bool, String> {
    update(folder, |list| (drop_key(list, key), true))
}

/// Takes `key` off the list, trusted or waiting; whether it was there.
fn drop_key(list: &mut List, key: &str) -> bool {
    let before = list.trusted.len() + list.pending.len();
    list.trusted.retain(|board| board.key != key);
    list.pending.retain(|board| board.key != key);
    list.first_use_until = None;
    list.trusted.len() + list.pending.len() != before
}

fn promote(list: &mut List, key: &str, now: u64) -> bool {
    let Some(at) = list.pending.iter().position(|board| board.key == key) else { return false };
    let board = list.pending.remove(at);
    list.trusted.push(Trusted { key: board.key, name: board.name, added: now });
    list.first_use_until = None;
    true
}

/// Forgets every board, trusted or waiting.
pub fn clear(folder: &Path) -> Result<(), String> {
    update(folder, |list| (*list = List::default(), true))
}

/// The first board to prove itself before `until` is trusted, while none is.
pub fn open_window(folder: &Path, until: u64) -> Result<(), String> {
    update(folder, |list| (list.first_use_until = Some(until), true))
}

/// One request of a channel carrying `boards`, from the trusted board holding `caller`: the
/// reply's line, or None when `caller` is no longer trusted and the channel must end.
pub fn answer(folder: &Path, caller: &str, request: &[u8], now: u64) -> Option<String> {
    // Checked and changed in one step: a board forgotten meanwhile changes nothing.
    let reply = update(folder, |list| {
        if !list.trusted.iter().any(|board| board.key == caller) {
            return (None, false);
        }
        let request: Value = serde_json::from_slice(request).unwrap_or_default();
        let done = |done: bool, otherwise: &str| if done { json!({ "ok": true }) } else { json!({ "error": otherwise }) };
        let (reply, changed) = if request.get("list").is_some() {
            let waiting: Vec<&Pending> = list.pending.iter().filter(|board| now.saturating_sub(board.last_seen) < STALE).collect();
            (json!({ "trusted": list.trusted, "pending": waiting }), false)
        } else if let Some(key) = request["trust"]["key"].as_str() {
            let trusted = promote(list, key, now);
            (done(trusted, "not_pending"), trusted)
        } else if let Some(key) = request["forget"]["key"].as_str() {
            let forgotten = drop_key(list, key);
            (done(forgotten, "not_trusted"), forgotten)
        } else {
            (json!({ "error": "invalid_request" }), false)
        };
        (Some(reply), changed)
    });
    match reply {
        Ok(reply) => reply.map(|reply| format!("{reply}\n")),
        Err(error) => Some(format!("{}\n", json!({ "error": error }))),
    }
}

/// The stored key a person means by `text`: a whole key (base64), or the full fingerprint of
/// exactly one of `keys`. Never a prefix, and never one of two keys that share a fingerprint.
fn resolve<'a>(keys: impl Iterator<Item = &'a str>, text: &str, print: &dyn Fn(&str) -> String) -> Result<String, String> {
    let text: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    if text.len() == 20 && text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        let wanted = text.to_lowercase();
        let found: Vec<&str> = keys.filter(|key| print(key).replace(' ', "") == wanted).collect();
        return match found[..] {
            [key] => Ok(key.to_string()),
            [] => Err("No board here has that fingerprint: see `agentboard boards`.".into()),
            _ => Err(format!("{} boards here share that fingerprint, so it names neither. Give the whole key of the one you mean:\n  {}", found.len(), found.join("\n  "))),
        };
    }
    match STANDARD.decode(&text) {
        Ok(key) if key.len() == 32 => Ok(STANDARD.encode(key)),
        _ => Err("Give a full fingerprint (five groups of four, as `agentboard boards` shows) or a whole key.".into()),
    }
}

fn line(key: &str, name: &str) -> String {
    format!("  {}  calls itself \"{name}\"", stored_fingerprint(key))
}

/// `agentboard boards`.
pub fn show() -> Result<(), String> {
    let list = load(&config::data_folder())?;
    println!("Trusted:{}", if list.trusted.is_empty() { " none" } else { "" });
    list.trusted.iter().for_each(|board| println!("{}", line(&board.key, &board.name)));
    println!("Waiting to be trusted:{}", if list.pending.is_empty() { " none" } else { "" });
    list.pending.iter().for_each(|board| println!("{}", line(&board.key, &board.name)));
    println!("{WHERE} A name is only what a computer calls itself.\n`agentboard trust <fingerprint or key>` trusts one, `agentboard untrust <fingerprint>` stops.");
    Ok(())
}

/// `agentboard trust <fingerprint or key>`.
pub fn trust_named(text: &str) -> Result<(), String> {
    let folder = config::data_folder();
    let list = load(&folder)?;
    let key = resolve(list.pending.iter().map(|board| board.key.as_str()), text, &stored_fingerprint)?;
    trust_key(&folder, &key, now())?;
    println!("{} is trusted.", stored_fingerprint(&key));
    Ok(())
}

/// `agentboard untrust <fingerprint or key>`.
pub fn untrust_named(text: &str) -> Result<(), String> {
    let folder = config::data_folder();
    let list = load(&folder)?;
    let key = resolve(list.trusted.iter().map(|board| board.key.as_str()).chain(list.pending.iter().map(|board| board.key.as_str())), text, &stored_fingerprint)?;
    if !forget(&folder, &key)? {
        return Err("That board isn't on this host's list.".into());
    }
    println!("{} is off this host's list.", stored_fingerprint(&key));
    Ok(())
}

/// At a terminal, after `login`: asks about each board that shows up waiting, until one is
/// trusted and no other waits, or `FIRST_USE` passes. `read` gives the person's answer.
pub fn ask(folder: &Path, say: &mut dyn FnMut(&str), wait: &mut dyn FnMut(std::time::Duration), read: &mut dyn FnMut() -> Option<String>) -> Result<(), String> {
    const LATER: &str = "`agentboard boards` lists the computers waiting, `agentboard trust <fingerprint>` trusts one.";
    const POLL: u64 = 2;
    if !load(folder)?.trusted.is_empty() {
        return Ok(());
    }
    // Said first: Ctrl+C leaves the list as it is, and says nothing more.
    say(&format!("Waiting for a computer to ask to use this host (open the app there). Ctrl+C stops waiting: {LATER}\n"));
    let (mut asked, mut trusted, mut waited) = (Vec::new(), false, 0);
    while waited < FIRST_USE {
        let list = load(folder)?;
        let Some(board) = list.pending.iter().find(|board| !asked.contains(&board.key)) else {
            // Trusted here, or meanwhile by another command.
            if trusted || !list.trusted.is_empty() {
                return Ok(());
            }
            wait(std::time::Duration::from_secs(POLL));
            waited += POLL;
            continue;
        };
        asked.push(board.key.clone());
        let print = stored_fingerprint(&board.key);
        say(&format!("{print} wants to use this host (it calls itself \"{}\"). {WHERE} Trust it? [y/N] ", board.name));
        if read().is_some_and(|answer| matches!(answer.trim(), "y" | "Y" | "yes")) {
            if trust(folder, &board.key, now())? {
                trusted = true;
                say(&format!("{print} is trusted.\n"));
            } else {
                say("It is no longer waiting.\n");
            }
        }
    }
    say(&format!("No computer was trusted. {LATER}\n"));
    Ok(())
}

/// `agentboard login`, once signed in with the service running: how the first board gets in.
pub fn first_board() -> Result<(), String> {
    use std::io::IsTerminal;
    let folder = config::data_folder();
    if !load(&folder)?.trusted.is_empty() {
        return Ok(());
    }
    if !(std::io::stdin().is_terminal() && std::io::stdout().is_terminal()) {
        open_window(&folder, now() + FIRST_USE)?;
        println!("The first computer to connect in the next 15 minutes will be trusted. After that: `agentboard boards` and `agentboard trust <fingerprint>`.");
        return Ok(());
    }
    let mut say = |text: &str| {
        print!("{text}");
        let _ = std::io::stdout().flush();
    };
    let mut read = || {
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer).ok().filter(|count| *count > 0).map(|_| answer)
    };
    ask(&folder, &mut say, &mut std::thread::sleep, &mut read)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::temporary;

    fn key(number: u16) -> [u8; 32] {
        let mut key = [0u8; 32];
        key[..2].copy_from_slice(&number.to_be_bytes());
        key
    }

    fn stored(number: u16) -> String {
        STANDARD.encode(key(number))
    }

    fn waiting(folder: &Path) -> Vec<String> {
        load(folder).unwrap().pending.into_iter().map(|board| board.key).collect()
    }

    #[test]
    fn fingerprints_are_ten_bytes_in_five_groups() {
        // SHA-256 of 32 zero bytes starts 66687aadf862bd776c8f.
        assert_eq!(fingerprint(&[0; 32]), "6668 7aad f862 bd77 6c8f");
        assert_eq!(stored_fingerprint(&STANDARD.encode([0u8; 32])), "6668 7aad f862 bd77 6c8f");
    }

    #[test]
    fn an_empty_list_outside_the_window_refuses_and_records() {
        let folder = temporary("boards");
        assert_eq!(admit(&folder, &key(1), b"One", 100), Ok(Verdict::Pending(0)));
        let list = load(&folder).unwrap();
        assert!(list.trusted.is_empty());
        assert_eq!(list.pending, [Pending { key: stored(1), name: "One".into(), first_seen: 100, last_seen: 100 }]);
        // Again: only `last_seen` moves, whatever name it gives now.
        assert_eq!(admit(&folder, &key(1), b"Other", 130), Ok(Verdict::Pending(0)));
        assert_eq!(load(&folder).unwrap().pending, [Pending { key: stored(1), name: "One".into(), first_seen: 100, last_seen: 130 }]);
        // A window that ended is no window.
        open_window(&folder, 200).unwrap();
        assert_eq!(admit(&folder, &key(1), b"One", 200), Ok(Verdict::Pending(0)));
        assert_eq!(load(&folder).unwrap().first_use_until, None);
        assert_eq!(admit(&folder, &key(1), b"One", 150), Ok(Verdict::Pending(0)), "not even with the clock set back");

        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(folder.join("boards.json")).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn inside_the_window_the_first_board_is_trusted_and_the_window_is_used() {
        let folder = temporary("boards");
        assert_eq!(admit(&folder, &key(1), b"One", 90), Ok(Verdict::Pending(0)));
        open_window(&folder, 1000).unwrap();
        assert_eq!(admit(&folder, &key(1), b"One", 100), Ok(Verdict::Trusted));
        let list = load(&folder).unwrap();
        assert_eq!(list.trusted, [Trusted { key: stored(1), name: "One".into(), added: 100 }]);
        assert!(list.pending.is_empty() && list.first_use_until.is_none());
        // The second, well inside the same 15 minutes, waits.
        assert_eq!(admit(&folder, &key(2), b"Two", 120), Ok(Verdict::Pending(1)));
        assert_eq!(admit(&folder, &key(1), b"One", 5000), Ok(Verdict::Trusted));

        // A window opened while a board is trusted is nobody's.
        open_window(&folder, 9000).unwrap();
        assert_eq!(admit(&folder, &key(3), b"Three", 6000), Ok(Verdict::Pending(1)));
        assert_eq!(load(&folder).unwrap().first_use_until, None);
    }

    #[test]
    fn a_flood_of_new_keys_is_slowed_and_never_evicts_a_board_that_keeps_trying() {
        let folder = temporary("boards");
        assert_eq!(admit(&folder, &key(0), b"Real", 1000), Ok(Verdict::Pending(0)));
        // Ten minutes of a new key every second, the real board back every 30.
        for second in 1..=600u64 {
            if second % 30 == 0 {
                admit(&folder, &key(0), b"Real", 1000 + second).unwrap();
            }
            assert_eq!(admit(&folder, &key(second as u16), b"Flood", 1000 + second), Ok(Verdict::Pending(0)));
            let list = load(&folder).unwrap();
            assert!(list.pending.len() <= MOST_PENDING);
            assert!(list.pending.iter().any(|board| board.key == stored(0)), "evicted at {second}");
            // One new key per 10 seconds: every other one left no trace.
            let recorded = second % 10 == 0;
            assert_eq!(list.pending.iter().any(|board| board.key == stored(second as u16)), recorded, "{second}");
        }
        assert_eq!(waiting(&folder).len(), MOST_PENDING);
        // One that stops trying is the first to go.
        for second in 610..=700u64 {
            admit(&folder, &key(second as u16), b"Flood", 1000 + second).unwrap();
        }
        assert!(!waiting(&folder).contains(&stored(0)));
    }

    #[test]
    fn names_are_stored_without_what_a_terminal_would_obey() {
        let folder = temporary("boards");
        admit(&folder, &key(1), "Mac\x1b[2J\x1b]0;x\x07\r\nTrusted: \u{202e}all\u{7f}\0".as_bytes(), 100).unwrap();
        assert_eq!(load(&folder).unwrap().pending[0].name, "Mac[2J]0;xTrusted: all");
        // At most 64 bytes, cut between characters; bytes that aren't UTF-8 don't get through.
        clear(&folder).unwrap();
        admit(&folder, &key(2), "é".repeat(40).as_bytes(), 200).unwrap();
        assert_eq!(load(&folder).unwrap().pending[0].name, "é".repeat(32));
        clear(&folder).unwrap();
        admit(&folder, &key(3), b"a\xff\x1bb", 300).unwrap();
        assert_eq!(load(&folder).unwrap().pending[0].name, "a\u{fffd}b");
    }

    #[test]
    fn trust_acts_on_the_stored_key_and_never_on_a_prefix() {
        let keys = [stored(1), stored(2)];
        let all = || keys.iter().map(String::as_str);
        let print = stored_fingerprint(&keys[0]);
        assert_eq!(resolve(all(), &print, &stored_fingerprint), Ok(keys[0].clone()));
        assert_eq!(resolve(all(), &print.replace(' ', "").to_uppercase(), &stored_fingerprint), Ok(keys[0].clone()));
        for short in [&print[..19], &print[..4], "", " "] {
            assert!(resolve(all(), short, &stored_fingerprint).is_err(), "{short:?}");
        }
        assert!(resolve(all(), "0000 0000 0000 0000 0000", &stored_fingerprint).unwrap_err().contains("No board"));
        // A whole key names itself, stored or not.
        assert_eq!(resolve(all(), &stored(9), &stored_fingerprint), Ok(stored(9)));
        assert!(resolve(all(), &stored(9)[..43], &stored_fingerprint).is_err());
        assert!(resolve(all(), &STANDARD.encode([1u8; 31]), &stored_fingerprint).is_err());

        // Two keys with one fingerprint: neither, and both are named.
        let same = |_: &str| "aaaa bbbb cccc dddd eeee".to_string();
        let refused = resolve(all(), "aaaa bbbb cccc dddd eeee", &same).unwrap_err();
        assert!(refused.contains(&keys[0]) && refused.contains(&keys[1]) && refused.contains("share"), "{refused}");
        assert_eq!(resolve(all(), &keys[1], &same), Ok(keys[1].clone()));
    }

    #[test]
    fn a_whole_key_is_trusted_whether_or_not_it_is_waiting() {
        let folder = temporary("boards");
        open_window(&folder, 1000).unwrap();
        trust_key(&folder, &stored(7), 100).unwrap();
        assert_eq!(load(&folder).unwrap().trusted, [Trusted { key: stored(7), name: "".into(), added: 100 }]);
        assert_eq!(load(&folder).unwrap().first_use_until, None);
        assert_eq!(admit(&folder, &key(7), b"Seven", 110), Ok(Verdict::Trusted));
        // One that waits keeps its name and leaves the waiting list; twice is once.
        admit(&folder, &key(8), b"Eight", 120).unwrap();
        trust_key(&folder, &stored(8), 130).unwrap();
        trust_key(&folder, &stored(8), 140).unwrap();
        let list = load(&folder).unwrap();
        assert_eq!(list.trusted[1..], [Trusted { key: stored(8), name: "Eight".into(), added: 130 }]);
        assert!(list.pending.is_empty());
        // Over a channel, only a key that waits.
        assert_eq!(trust(&folder, &stored(9), 150), Ok(false));
    }

    #[test]
    fn a_board_gone_quiet_leaves_the_waiting_list_and_one_can_be_dropped_by_hand() {
        let folder = std::env::temp_dir().join(format!("boards-stale-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        admit(&folder, &key(1), b"gone", 1_000).unwrap();
        admit(&folder, &key(2), b"here", 1_100).unwrap();
        // Five minutes of silence from the first; the second kept trying.
        admit(&folder, &key(2), b"here", 1_000 + STALE).unwrap();
        assert_eq!(waiting(&folder), [stored(2)]);
        assert!(forget(&folder, &stored(2)).unwrap());
        assert!(waiting(&folder).is_empty());
        // Trusted by its key alone, it is named the first time it proves itself.
        trust_key(&folder, &stored(3), 2_000).unwrap();
        assert_eq!(admit(&folder, &key(3), b"desk\x1b[2K", 2_001).unwrap(), Verdict::Trusted);
        assert_eq!(load(&folder).unwrap().trusted[0].name, "desk[2K");
        let _ = fs::remove_dir_all(&folder);
    }

    #[test]
    fn forgetting_the_last_board_leaves_every_board_waiting() {
        let folder = temporary("boards");
        open_window(&folder, 1000).unwrap();
        assert_eq!(admit(&folder, &key(1), b"One", 100), Ok(Verdict::Trusted));
        // A window set again while it was trusted goes with it.
        open_window(&folder, 1000).unwrap();
        assert_eq!(forget(&folder, &stored(1)), Ok(true));
        assert_eq!(forget(&folder, &stored(1)), Ok(false));
        assert_eq!(load(&folder).unwrap().first_use_until, None);
        assert_eq!(admit(&folder, &key(1), b"One", 200), Ok(Verdict::Pending(0)));
        assert_eq!(admit(&folder, &key(2), b"Two", 300), Ok(Verdict::Pending(0)));

        clear(&folder).unwrap();
        let list = load(&folder).unwrap();
        assert!(list.trusted.is_empty() && list.pending.is_empty() && list.first_use_until.is_none());
    }

    #[test]
    fn answers_a_trusted_board_and_nobody_else() {
        let folder = temporary("boards");
        open_window(&folder, 1000).unwrap();
        admit(&folder, &key(1), b"One", 100).unwrap();
        admit(&folder, &key(2), b"Two", 200).unwrap();
        let ask = |caller: u16, request: &str| answer(&folder, &stored(caller), request.as_bytes(), 300).map(|reply| serde_json::from_str::<Value>(reply.strip_suffix('\n').unwrap()).unwrap());

        assert_eq!(ask(2, r#"{"list":{}}"#), None);
        assert_eq!(ask(2, &format!(r#"{{"trust":{{"key":"{}"}}}}"#, stored(2))), None);
        assert_eq!(waiting(&folder), [stored(2)]);

        let listed = ask(1, r#"{"list":{}}"#).unwrap();
        assert_eq!(listed, json!({ "trusted": [{ "key": stored(1), "name": "One", "added": 100 }], "pending": [{ "key": stored(2), "name": "Two", "first_seen": 200, "last_seen": 200 }] }));
        for (request, error) in [("", "invalid_request"), ("{}", "invalid_request"), (r#"{"trust":{}}"#, "invalid_request"), (r#"{"trust":{"key":"AAAA"}}"#, "not_pending"), (r#"{"forget":{"key":"AAAA"}}"#, "not_trusted")] {
            assert_eq!(ask(1, request), Some(json!({ "error": error })), "{request}");
        }
        assert_eq!(ask(1, &format!(r#"{{"trust":{{"key":"{}"}}}}"#, stored(1))), Some(json!({ "error": "not_pending" })));
        assert_eq!(ask(1, &format!(r#"{{"trust":{{"key":"{}"}}}}"#, stored(2))), Some(json!({ "ok": true })));
        assert_eq!(ask(2, &format!(r#"{{"forget":{{"key":"{}"}}}}"#, stored(1))), Some(json!({ "ok": true })));
        // Forgotten: its next request ends its channel. The last one may forget itself.
        assert_eq!(ask(1, r#"{"list":{}}"#), None);
        assert_eq!(ask(2, &format!(r#"{{"forget":{{"key":"{}"}}}}"#, stored(2))), Some(json!({ "ok": true })));
        assert_eq!(admit(&folder, &key(2), b"Two", 400), Ok(Verdict::Pending(0)));
    }

    /// `ask` with scripted answers; what it said, and how long it waited in all.
    fn asked(folder: &Path, answers: &[&str], mut meanwhile: impl FnMut(u64)) -> (String, u64) {
        let (mut said, waited, mut answers) = (String::new(), std::cell::Cell::new(0), answers.iter());
        let mut wait = |time: std::time::Duration| {
            waited.set(waited.get() + time.as_secs());
            meanwhile(waited.get());
        };
        ask(folder, &mut |text| said.push_str(text), &mut wait, &mut || answers.next().map(|answer| answer.to_string())).unwrap();
        (said, waited.get())
    }

    #[test]
    fn login_asks_about_each_waiting_board_fingerprint_first() {
        let folder = temporary("boards");
        let (said, waited) = asked(&folder, &["n\n", "y\n", "\n"], |waited| {
            // The first shows up after 4 seconds, two more together later.
            match waited {
                4 => drop(admit(&folder, &key(1), b"One", 100)),
                20 => {
                    admit(&folder, &key(2), b"Two\x1b[A", 200).unwrap();
                    admit(&folder, &key(3), b"Three", 300).unwrap();
                }
                _ => {}
            }
        });
        assert_eq!(waited, 20);
        assert_eq!(said.matches("Trust it? [y/N]").count(), 3, "{said}");
        for (number, name) in [(1, "One"), (2, "Two[A"), (3, "Three")] {
            assert!(said.contains(&format!("{} wants to use this host (it calls itself \"{name}\"). {WHERE} Trust it? [y/N] ", fingerprint(&key(number)))), "{said}");
        }
        assert!(said.contains("`agentboard trust <fingerprint>`") && !said.contains('\x1b'));
        let list = load(&folder).unwrap();
        assert_eq!(list.trusted.iter().map(|board| board.key.clone()).collect::<Vec<_>>(), [stored(2)]);
        assert_eq!(waiting(&folder), [stored(1), stored(3)], "a no leaves the board waiting");
    }

    #[test]
    fn login_stops_asking_after_fifteen_minutes_or_when_a_board_is_trusted() {
        let folder = temporary("boards");
        let (said, waited) = asked(&folder, &[], |_| {});
        assert_eq!(waited, FIRST_USE);
        assert!(said.ends_with("`agentboard trust <fingerprint>` trusts one.\n") && said.contains("No computer was trusted"));
        assert!(!folder.join("boards.json").exists(), "the list is left as it was");

        // Trusted meanwhile by `agentboard trust`: nothing more to wait for.
        let (said, waited) = asked(&folder, &[], |waited| {
            if waited == 6 {
                trust_key(&folder, &stored(1), 100).unwrap();
            }
        });
        assert_eq!(waited, 6);
        assert!(!said.contains("Trust it?"));
        // And with a board already trusted, not a word.
        assert_eq!(asked(&folder, &["y\n"], |_| {}), (String::new(), 0));
    }
}
