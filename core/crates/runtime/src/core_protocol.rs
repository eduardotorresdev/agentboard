// What the board and the core say to each other over the core's Unix socket.
//
// The core is a separate process that owns the agents' PTYs, so they keep running while the
// board quits, crashes or is rebuilt. The board mirrors each session's terminal: on attaching it
// gets a snapshot, then the same output the core's terminal parses, in the same order.
//
// Frames: a 4-byte big-endian length, then a kind byte, then the payload.
// - `control`: a JSON `CoreRequest` (board → core) or `CoreEvent` (core → board).
// - `data`: a 16-byte session id, then bytes: program output (core → board) or keyboard input
//   (board → core).
// - `snapshot`: a 16-byte session id, then `Terminal::snapshot()` bytes (core → board).
// - `service`: bytes for the core's service (the board's cards, lines and tools; see
//   `CoreService`), both ways. The sessions layer doesn't read them.
//
// The JSON is what Swift's synthesized `Codable` writes (docs/hosts.md, "Wire compatibility"),
// pinned by the golden files in `core/fixtures/runtime`.

use std::fmt;

use base64::Engine;
use serde::de::{SeqAccess, Visitor};
use serde::ser::SerializeSeq;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::agent_session::State;
use crate::{data_folder, Uuid};

/// What a build speaks: `version`, and every one back to `oldest`. A board and a core use
/// the newest version both speak (the core picks it, in its welcome); with none in common
/// they don't talk, and the board says what to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Versions {
    pub version: i64,
    pub oldest: i64,
}

impl Versions {
    /// The newest version both speak, if any.
    pub fn agreed(&self, other: Versions) -> Option<i64> {
        let version = self.version.min(other.version);
        (version >= self.oldest.max(other.oldest)).then_some(version)
    }
}

/// Bumped whenever a message changes. Older peers must keep working one version back, so a
/// change only adds: optional fields, and requests or events an older peer can ignore
/// (unknown ones are dropped). Anything else raises `OLDEST` past the versions it breaks.
/// 3: `takeOver`, and both sides say the oldest version they speak.
/// 4: the attention queue (`BoardEvent.attention`, `BoardRequest.dismissAttention`).
/// 5: an agent's questions in its attention request, answered with `answerQuestions`.
/// 6: the composer's `prompt`, and messages `held` behind the user's terminal line (`deliverHeld`).
/// 7: `subscribeStatuses`, a board hearing every session's status.
/// 8: hosts: `run` (a program on the core's machine, answered with `ran`) and `subscribeHost`.
/// 9: decisions (`BoardEvent.decisions`, `BoardRequest.answerDecision`); the Swift core only, for now.
pub const VERSION: i64 = 9;
pub const OLDEST: i64 = 2;
pub const VERSIONS: Versions = Versions { version: VERSION, oldest: OLDEST };

/// Frames larger than this are refused: a corrupt length must not allocate gigabytes.
pub const MAXIMUM_FRAME: usize = 256 * 1024 * 1024;

/// `AGENTBOARD_CORE_SOCKET`, or `core.sock` in the data folder. A data folder too deep for
/// a socket path gets one in this user's temporary folder, named after it.
pub fn socket_path() -> String {
    if let Some(path) = std::env::var("AGENTBOARD_CORE_SOCKET").ok().filter(|path| !path.is_empty()) {
        return path;
    }
    let folder = data_folder::url();
    let path = folder.join("core.sock").to_string_lossy().into_owned();
    // SAFETY: an all-zero sockaddr_un is a valid value; only its size is read.
    let capacity = unsafe { std::mem::zeroed::<libc::sockaddr_un>() }.sun_path.len();
    if path.len() < capacity {
        return path;
    }
    // FNV-1a: stable across launches.
    let hash = folder.to_string_lossy().bytes().fold(0xcbf2_9ce4_8422_2325u64, |hash, byte| (hash ^ byte as u64).wrapping_mul(0x100_0000_01b3));
    // On Linux the temporary folder is everyone's; the runtime folder is this user's.
    let temporary = std::env::var_os("XDG_RUNTIME_DIR").filter(|folder| !folder.is_empty()).map(Into::into).unwrap_or_else(std::env::temp_dir);
    temporary.join(format!("agentboard-{hash:x}.sock")).to_string_lossy().into_owned()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameKind {
    Control = 1,
    Data = 2,
    Snapshot = 3,
    Service = 4,
}

impl FrameKind {
    pub fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            1 => Some(Self::Control),
            2 => Some(Self::Data),
            3 => Some(Self::Snapshot),
            4 => Some(Self::Service),
            _ => None,
        }
    }
}

/// What to run for a session; built by the service from an `AgentProvider`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LaunchSpec {
    pub executable: String,
    pub arguments: Vec<String>,
    pub environment: std::collections::HashMap<String, String>,
    pub directory: String,
}

/// What a session is doing, as the core reports it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SessionStatus {
    pub state: State,
    #[serde(rename = "processID", default, skip_serializing_if = "Option::is_none")]
    pub process_id: Option<i32>,
    #[serde(rename = "exitCode", default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum CoreRequest {
    /// `oldest`: since 3; a board that doesn't say speaks only `version`.
    Hello {
        version: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        oldest: Option<i64>,
    },
    /// Starts (or restarts) the program of session `id`, creating the session if needed; the
    /// sender is attached to it.
    Start { id: Uuid, spec: LaunchSpec, cols: i64, rows: i64 },
    /// Subscribes to a session the core already has: a status and a snapshot come back.
    Attach { id: Uuid },
    Resize { id: Uuid, cols: i64, rows: i64 },
    /// Whether a board shows the session; the core reads output sooner while any does.
    Observe { id: Uuid, observed: bool },
    /// From a board: every session's status, of every organization, from now on, as `status`
    /// events; the sessions it attaches to get theirs anyway. Since 7.
    SubscribeStatuses {},
    /// SIGTERM to the program's group, SIGKILL after `grace` seconds.
    Terminate { id: Uuid, grace: f64 },
    /// SIGHUP, as when a terminal window closes.
    Stop { id: Uuid },
    /// Writes `text` into the session's terminal as if the program printed it (on a fresh
    /// line when `fresh_line`), for every board that mirrors it.
    Annotate { id: Uuid, text: String, fresh_line: bool },
    /// Ends the program (`grace` as in `terminate`, or SIGHUP when none) and forgets the session.
    Close {
        id: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        grace: Option<f64>,
    },
    /// Ends every program and exits.
    Shutdown {},
    /// From a newer core: hand it every session without ending them. Not in this core.
    TakeOver {},
    /// Runs a program on the core's machine and answers with `ran`: how a board runs git on
    /// another host. An `executable` without a slash is looked up in the PATH the core launches
    /// agents with; `input` is what the program reads (nothing when none). Since 8; an older
    /// core never answers.
    Run {
        call: Uuid,
        executable: String,
        arguments: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        directory: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        input: Option<Data>,
    },
    /// The machine's stats from now on, as `host` events. Since 8.
    SubscribeHost {},
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum CoreEvent {
    /// The answer to `hello`: every session the core has, running or not, and the service's
    /// state for this board.
    /// `version` is the one agreed on, or the core's own when there is none (nothing else
    /// follows then, and the board hangs up). `oldest`: since 3.
    Welcome {
        version: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        oldest: Option<i64>,
        #[serde(with = "uuid_keyed")]
        sessions: Vec<(Uuid, SessionStatus)>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        service: Option<Data>,
    },
    Status { id: Uuid, status: SessionStatus },
    /// The answer to `run`: `status` is the exit code, or -1 when the program couldn't start
    /// (`error` then says why).
    Ran { call: Uuid, status: i32, output: Data, error: Data },
    Host {
        #[serde(rename = "_0")]
        stats: HostStats,
    },
}

/// What the core's machine is using, as it reports it every couple of seconds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostStats {
    /// Of every processor together, 0 to 1.
    pub cpu: f64,
    pub memory_used: u64,
    pub memory_total: u64,
    /// Of the volume the home folder is on.
    pub disk_used: u64,
    pub disk_total: u64,
    /// The 1-minute load average.
    pub load: f64,
    pub cores: i64,
}

/// Bytes as Swift's `Data` travels in JSON: base64.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Data(pub Vec<u8>);

impl fmt::Debug for Data {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Data({} bytes)", self.0.len())
    }
}

impl Serialize for Data {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for Data {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        base64::engine::general_purpose::STANDARD.decode(text).map(Data).map_err(serde::de::Error::custom)
    }
}

/// A Swift dictionary keyed by `UUID`: an array alternating key and value.
mod uuid_keyed {
    use super::*;

    pub fn serialize<S: Serializer, V: Serialize>(entries: &[(Uuid, V)], serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(entries.len() * 2))?;
        for (key, value) in entries {
            sequence.serialize_element(key)?;
            sequence.serialize_element(value)?;
        }
        sequence.end()
    }

    pub fn deserialize<'de, D: Deserializer<'de>, V: Deserialize<'de>>(deserializer: D) -> Result<Vec<(Uuid, V)>, D::Error> {
        struct Alternating<V>(std::marker::PhantomData<V>);

        impl<'de, V: Deserialize<'de>> Visitor<'de> for Alternating<V> {
            type Value = Vec<(Uuid, V)>;

            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an array alternating UUID and value")
            }

            fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Self::Value, A::Error> {
                let mut entries = Vec::new();
                while let Some(key) = sequence.next_element()? {
                    let value = sequence.next_element()?.ok_or_else(|| serde::de::Error::custom("a key without its value"))?;
                    entries.push((key, value));
                }
                Ok(entries)
            }
        }

        deserializer.deserialize_seq(Alternating(std::marker::PhantomData))
    }
}
