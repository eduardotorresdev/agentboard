// What the board and the core's `Orchestrator` say to each other, in the core socket's
// `service` frames (JSON). The core owns the cards and the lines; a board mirrors them, sends
// the user's changes, and runs the tools only it can (browsers).
//
// The JSON is what Swift's synthesized `Codable` writes (docs/hosts.md, "Wire compatibility"),
// pinned by the golden files in `core/fixtures/orchestration`.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use connections::{BoardName, Connection, Message, ToolContent, ToolResult, Uuid};
use runtime::Data;

use crate::attention::AttentionRequest;
use crate::cards::{AgentRecord, ElementInfo};
use crate::image_card::ImageRecord;
use crate::post_it::PostItRecord;
use crate::process_inspector::RunnerStats;

/// Board → core.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum BoardRequest {
    AddCard(Unlabelled<AgentRecord>),
    /// Its name, frame or runner changed.
    UpdateCard(Unlabelled<AgentRecord>),
    /// Ends its program and forgets it.
    RemoveCard(Unlabelled<Uuid>),
    Connect(Unlabelled<Connection>),
    Disconnect(Unlabelled<Uuid>),
    /// Every other element the board has (browsers): lines to any it no longer lists go.
    Elements(Unlabelled<Vec<ElementInfo>>),
    /// Attaches the board to the card's session (status, snapshot, output). A session the core
    /// doesn't have yet is created at `cols`×`rows`, and its program started when `start`
    /// (shown as stopped otherwise); one it has is left as it is.
    Open { id: Uuid, cols: i64, rows: i64, start: bool },
    /// Runs the card's program again: an agent that ended, or a runner (stopped first), with
    /// `command` from now on when given.
    Restart {
        id: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
    },
    StartRunner(Unlabelled<Uuid>),
    StopRunner(Unlabelled<Uuid>),
    ToolResult { call: Uuid, result: WireToolResult },
    AddPostIt(Unlabelled<PostItRecord>),
    /// Its name or frame changed; the core keeps its text.
    UpdatePostIt(Unlabelled<PostItRecord>),
    RemovePostIt(Unlabelled<Uuid>),
    /// The user rewrote its text.
    WritePostIt { id: Uuid, text: String },
    /// A picture the user pasted, picked or dropped: the board stored its file with `ImageFiles`
    /// first. One whose file isn't there is ignored.
    AddImage(Unlabelled<ImageRecord>),
    /// Its name or frame changed; the core keeps its picture.
    UpdateImage(Unlabelled<ImageRecord>),
    /// Forgets it and deletes its file.
    RemoveImage(Unlabelled<Uuid>),
    /// The developer dealt with the agent's attention request.
    DismissAttention(Unlabelled<Uuid>),
    /// The developer answered the questions the agent asked, keyed by question text; none
    /// leaves them to the agent's terminal.
    AnswerQuestions {
        id: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        answers: Option<HashMap<String, String>>,
    },
    /// The user sent `text` from one of the board's elements (a file tree's annotations) to
    /// every agent connected to it, or only to the connected agent `to` (an image's marks).
    Deliver {
        from: Uuid,
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<Uuid>,
    },
    /// The user sent `text` from the agent card's composer: typed into its terminal as a
    /// prompt, queued behind messages so neither interrupts the other.
    Prompt { id: Uuid, text: String },
    /// Delivers the messages held while the user had text on the agent's terminal line.
    DeliverHeld(Unlabelled<Uuid>),
}

/// Core → board.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum BoardEvent {
    CardAdded(Unlabelled<AgentRecord>),
    CardUpdated(Unlabelled<AgentRecord>),
    CardRemoved(Unlabelled<Uuid>),
    /// Every line, after any change.
    Connections(Unlabelled<Vec<Connection>>),
    /// A message travelled along a line.
    Message(Unlabelled<Message>),
    Runners(Unlabelled<RunnerReport>),
    /// A tool only the board can run (the browser tools): answer with `toolResult`.
    ToolCall { call: Uuid, name: String, arguments: Data, caller: Uuid },
    PostItAdded(Unlabelled<PostItRecord>),
    /// Its name, frame or text changed.
    PostItUpdated(Unlabelled<PostItRecord>),
    PostItRemoved(Unlabelled<Uuid>),
    ImageAdded(Unlabelled<ImageRecord>),
    /// Its name, frame or picture (`file`, `pixelSize`) changed.
    ImageUpdated(Unlabelled<ImageRecord>),
    ImageRemoved(Unlabelled<Uuid>),
    /// Every attention request, oldest first, after any change.
    Attention(Unlabelled<Vec<AttentionRequest>>),
    /// How many messages wait for the user to finish the line they typed in agent `id`'s terminal.
    Held { id: Uuid, count: i64 },
    /// A composer prompt agent `id` couldn't take (it stopped, or waits on the developer):
    /// back to the composer with why.
    PromptReturned { id: Uuid, text: String, reason: String },
    /// The boards' other elements (browsers, simulators), after a board said which it has: how
    /// a board that can't run them (a phone) learns of them. Not sent back to that board.
    Elements(Unlabelled<Vec<ElementInfo>>),
}

/// The one unlabelled value of a Swift enum case: `{"_0": value}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Unlabelled<T> {
    #[serde(rename = "_0")]
    pub value: T,
}

/// Shorthand for an unlabelled case's payload.
pub fn only<T>(value: T) -> Unlabelled<T> {
    Unlabelled { value }
}

/// What a board gets with its welcome.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardState {
    pub cards: Vec<AgentRecord>,
    pub connections: Vec<Connection>,
    pub runners: RunnerReport,
    /// The post-its; none from a core that predates them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub post_its: Option<Vec<PostItRecord>>,
    /// The agents waiting on the developer; none from a core that predates them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attention: Option<Vec<AttentionRequest>>,
    /// The images; none from a core that predates them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<ImageRecord>>,
    /// The boards' other elements; none from a core that predates sending them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elements: Option<Vec<ElementInfo>>,
}

/// What the running runners serve and cost, and when each started.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunnerReport {
    #[serde(with = "uuid_keyed")]
    pub stats: HashMap<Uuid, RunnerStats>,
    /// Seconds since 2001, as Swift's `Date`.
    #[serde(with = "uuid_keyed")]
    pub starts: HashMap<Uuid, f64>,
    /// This machine's address on the local network, for ports other devices can reach.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_address: Option<String>,
}

/// A `ToolResult` on the wire.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WireToolResult {
    items: Vec<Item>,
    is_error: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
enum Item {
    Text(Unlabelled<String>),
    Image {
        #[serde(rename = "_0")]
        data: Data,
        mime_type: String,
    },
}

impl WireToolResult {
    pub fn new(result: &ToolResult) -> Self {
        let items = result
            .content
            .iter()
            .map(|content| match content {
                ToolContent::Text(text) => Item::Text(only(text.clone())),
                ToolContent::Image { data, mime_type } => Item::Image { data: Data(data.clone()), mime_type: mime_type.clone() },
            })
            .collect();
        Self { items, is_error: result.is_error }
    }

    pub fn result(self) -> ToolResult {
        let content = self
            .items
            .into_iter()
            .map(|item| match item {
                Item::Text(text) => ToolContent::Text(text.value),
                Item::Image { data, mime_type } => ToolContent::Image { data: data.0, mime_type },
            })
            .collect();
        ToolResult { content, is_error: self.is_error }
    }
}

impl BoardRequest {
    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// None for a request this core doesn't know (a newer board's).
    pub fn decode(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }

    /// The request with every name it carries made a valid one: one line of visible text, never
    /// an id. A rename to an invalid name becomes empty, which keeps the old name. The one place
    /// names from a board are cleaned on their way in.
    pub(crate) fn with_clean_names(mut self) -> Self {
        let named = |name: &mut String, fallback: &str| *name = BoardName::named(name, fallback);
        match &mut self {
            Self::AddCard(Unlabelled { value: record }) => {
                let fallback = if record.runner.is_none() { "Agent" } else { "Runner" };
                named(&mut record.name, fallback)
            }
            Self::UpdateCard(record) => named(&mut record.value.name, ""),
            Self::AddPostIt(record) => named(&mut record.value.name, "Post-it"),
            Self::UpdatePostIt(record) => named(&mut record.value.name, ""),
            Self::AddImage(Unlabelled { value: record }) => {
                let fallback = if record.is_video() { "Video" } else { "Image" };
                named(&mut record.name, fallback)
            }
            Self::UpdateImage(record) => named(&mut record.value.name, ""),
            Self::Elements(list) => list.value.iter_mut().for_each(|info| info.name = BoardName::named(&info.name, &info.kind)),
            _ => {}
        }
        self
    }
}

impl BoardEvent {
    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }
}

impl BoardState {
    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }
}

/// Now, as Swift's `Date` counts it: seconds since 2001-01-01 UTC.
pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |since| since.as_secs_f64()) - 978_307_200.0
}

/// The same id for the runtime crate, which has a type of its own.
pub(crate) fn to_runtime(id: Uuid) -> runtime::Uuid {
    runtime::Uuid::from_bytes(*id.as_bytes())
}

pub(crate) fn from_runtime(id: runtime::Uuid) -> Uuid {
    Uuid::from_bytes(*id.as_bytes())
}

/// `CGRect` on the wire: `[[x, y], [width, height]]`.
pub(crate) mod rect {
    use connections::Rect;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(rect: &Rect, serializer: S) -> Result<S::Ok, S::Error> {
        [[rect.origin.x, rect.origin.y], [rect.size.width, rect.size.height]].serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Rect, D::Error> {
        let [[x, y], [width, height]] = <[[f64; 2]; 2]>::deserialize(deserializer)?;
        Ok(Rect::new(x, y, width, height))
    }
}

/// `CGSize` on the wire: `[width, height]`.
pub(crate) mod size {
    use connections::Size;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(size: &Size, serializer: S) -> Result<S::Ok, S::Error> {
        [size.width, size.height].serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Size, D::Error> {
        let [width, height] = <[f64; 2]>::deserialize(deserializer)?;
        Ok(Size::new(width, height))
    }
}

/// A Swift dictionary keyed by `UUID`: an array alternating key and value.
mod uuid_keyed {
    use std::collections::HashMap;

    use connections::Uuid;
    use serde::ser::SerializeSeq;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use serde_json::Value;

    pub fn serialize<S: Serializer, V: Serialize>(entries: &HashMap<Uuid, V>, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(entries.len() * 2))?;
        for (key, value) in entries {
            sequence.serialize_element(key)?;
            sequence.serialize_element(value)?;
        }
        sequence.end()
    }

    pub fn deserialize<'de, D: Deserializer<'de>, V: serde::de::DeserializeOwned>(deserializer: D) -> Result<HashMap<Uuid, V>, D::Error> {
        let flat = Vec::<Value>::deserialize(deserializer)?;
        let invalid = |error: serde_json::Error| serde::de::Error::custom(error);
        flat.chunks(2)
            .map(|pair| match pair {
                [key, value] => Ok((serde_json::from_value(key.clone()).map_err(invalid)?, serde_json::from_value(value.clone()).map_err(invalid)?)),
                _ => Err(serde::de::Error::custom("a key without its value")),
            })
            .collect()
    }
}
