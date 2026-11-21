use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::{find_element, is_inline_space, Connection, ConnectionGraph, Side, Uuid};

/// What sort of element sits at the end of a line. Open-ended: each element family adds its own.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ElementKind(pub String);

impl ElementKind {
    pub fn agent() -> Self { Self("agent".into()) }
    pub fn browser() -> Self { Self("browser".into()) }
    pub fn runner() -> Self { Self("runner".into()) }
    pub fn simulator() -> Self { Self("simulator".into()) }
    pub fn post_it() -> Self { Self("postit".into()) }
    pub fn file_tree() -> Self { Self("filetree".into()) }
    pub fn image() -> Self { Self("image".into()) }
    pub fn video() -> Self { Self("video".into()) }
}

/// Anything on the board a line can reach (an agent's terminal, a browser, a post-it and more),
/// as it is right now. Swift's `BoardElement` objects read the store each time they are asked;
/// here the owner of the board hands out these values through `Elements`.
#[derive(Clone, Debug, PartialEq)]
pub struct Element {
    pub id: Uuid,
    /// How peers address it. Unique among the elements of one board.
    pub name: String,
    pub kind: ElementKind,
    /// One short line peers see next to the name (a browser's device, …), or none.
    pub detail: Option<String>,
    /// The board (canvas) it sits on, so `elements_on_board_of` lists only its neighbours: a
    /// worktree path, optionally followed by NUL and the organization it belongs to. One without
    /// an organization (a browser) is on that worktree in every organization; none is on every board.
    pub board: Option<String>,
    /// Set when it takes messages (Swift's `MessageEndpoint`), such as an agent typing them in
    /// as a prompt.
    pub endpoint: Option<Endpoint>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Endpoint {
    /// Why it can't take a message right now (not running, …), or none when it can.
    pub unavailable_reason: Option<String>,
}

impl Element {
    pub fn new(id: Uuid, name: impl Into<String>, kind: ElementKind) -> Self {
        Self { id, name: name.into(), kind, detail: None, board: None, endpoint: None }
    }
}

/// The elements of the board, kept by whoever owns it (the orchestrator's thread). The bus asks
/// it who is there and hands it the messages to deliver.
pub trait Elements {
    /// Every element, in any order. One the owner doesn't return isn't on the board.
    fn elements(&self) -> Vec<Element>;

    fn element(&self, id: Uuid) -> Option<Element> {
        self.elements().into_iter().find(|element| element.id == id)
    }

    /// Hands `message`, sent by `sender`, to the endpoint `message.to`.
    fn receive(&mut self, message: &Message, sender: &Element);

    /// Why what the endpoint `id` was last given waits instead of going in now, or none once it
    /// went in.
    fn queue_note(&self, _id: Uuid) -> Option<String> {
        None
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub id: Uuid,
    pub from: Uuid,
    pub to: Uuid,
    pub text: String,
    /// As Swift's `Date` goes on the wire: seconds since 2001-01-01 UTC.
    pub date: f64,
}

impl Message {
    /// 2001-01-01 UTC, in seconds since 1970.
    const REFERENCE_DATE: Duration = Duration::from_secs(978_307_200);

    pub fn new(from: Uuid, to: Uuid, text: impl Into<String>) -> Self {
        let now = SystemTime::now().duration_since(UNIX_EPOCH + Self::REFERENCE_DATE).unwrap_or_default();
        Self { id: Uuid::new(), from, to, text: text.into(), date: now.as_secs_f64() }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MessageError {
    UnknownSender,
    EmptyMessage,
    /// `to` names nothing connected to the sender; `peers` are the names that are.
    NotConnected { to: String, peers: Vec<String> },
    Unavailable { name: String, reason: String },
    /// `name` is connected but takes no messages (a browser: it has tools of its own instead).
    NotAnEndpoint { name: String },
}

impl fmt::Display for MessageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MessageError::UnknownSender => f.write_str("This agent is no longer on the board."),
            MessageError::EmptyMessage => f.write_str("The message is empty."),
            MessageError::NotConnected { to, peers } if peers.is_empty() => write!(
                f,
                "No agent named “{to}” is connected to you, and nothing is connected yet. The user connects agents by drawing lines between them on the board."
            ),
            MessageError::NotConnected { to, peers } => {
                write!(f, "No agent named “{to}” is connected to you. Connected: {}.", peers.join(", "))
            }
            MessageError::Unavailable { name, reason } => write!(f, "{name} can't receive messages: {reason}."),
            MessageError::NotAnEndpoint { name } => write!(f, "{name} doesn't take messages; use its own tools instead."),
        }
    }
}

impl std::error::Error for MessageError {}

/// Something to call with each new `T`.
pub type Listener<T> = Box<dyn FnMut(&T) + Send>;

/// The board's switchboard: which elements are connected, and delivery between them. A message
/// only ever travels along a line; elements with no line between them can't reach each other.
/// Tool providers ask it the same question (`peers`) to decide what a caller may reach.
///
/// It holds the lines only; the elements are their owner's, passed to each call that needs them.
/// `Send`, so the thread that owns the board may be given one made elsewhere.
#[derive(Default)]
pub struct MessageBus {
    graph: ConnectionGraph,
    /// Called after every change to the connections (to persist them, redraw the lines).
    pub on_graph_change: Option<Listener<ConnectionGraph>>,
    /// Called after each delivered message (to show it travel along its line).
    pub on_message: Option<Listener<Message>>,
}

impl MessageBus {
    pub fn new(graph: ConnectionGraph) -> Self {
        Self { graph, on_graph_change: None, on_message: None }
    }

    pub fn graph(&self) -> &ConnectionGraph {
        &self.graph
    }

    /// Every change adds or drops lines, so a changed count is a changed graph.
    fn change<R>(&mut self, change: impl FnOnce(&mut ConnectionGraph) -> R) -> R {
        let before = self.graph.connections().len();
        let result = change(&mut self.graph);
        if self.graph.connections().len() != before {
            if let Some(changed) = &mut self.on_graph_change {
                changed(&self.graph);
            }
        }
        result
    }

    pub fn connect(&mut self, x: Uuid, y: Uuid, sides: (Option<Side>, Option<Side>)) -> Option<Connection> {
        self.change(|graph| graph.connect(x, y, sides))
    }

    /// Adds a line drawn elsewhere, keeping its id.
    pub fn add(&mut self, connection: Connection) -> bool {
        self.change(|graph| graph.add(connection))
    }

    pub fn disconnect(&mut self, id: Uuid) {
        self.change(|graph| graph.disconnect(id))
    }

    /// Takes an element's lines off the board, as it goes (its owner forgets the element itself).
    pub fn remove(&mut self, element: Uuid) {
        self.change(|graph| graph.remove(element))
    }

    /// The elements connected to `id`, in connection order.
    pub fn peers(&self, id: Uuid, elements: &dyn Elements) -> Vec<Element> {
        self.graph.peers(id).into_iter().filter_map(|peer| elements.element(peer)).collect()
    }

    /// Every element on the same board as `id`, connected or not, itself included, ordered by
    /// kind then name.
    pub fn elements_on_board_of(&self, id: Uuid, elements: &dyn Elements) -> Vec<Element> {
        let board = elements.element(id).and_then(|element| element.board);
        let mut all: Vec<Element> =
            elements.elements().into_iter().filter(|element| Self::same_board(board.as_deref(), element.board.as_deref())).collect();
        all.sort_by_cached_key(|element| (element.kind.0.clone(), element.name.to_lowercase()));
        all
    }

    pub fn same_board(a: Option<&str>, b: Option<&str>) -> bool {
        let (Some(a), Some(b)) = (a, b) else { return true };
        if a == b {
            return true;
        }
        let (x, y): (Vec<&str>, Vec<&str>) = (a.split('\0').collect(), b.split('\0').collect());
        (x.len() == 1 || y.len() == 1) && x[0] == y[0]
    }

    /// The connected elements of `kind`, e.g. the browsers a caller may drive.
    pub fn peers_of_kind(&self, id: Uuid, kind: &ElementKind, elements: &dyn Elements) -> Vec<Element> {
        self.peers(id, elements).into_iter().filter(|element| &element.kind == kind).collect()
    }

    /// Sends `text` from `sender` to the connected peer named `address` (case-insensitive) or
    /// whose id it is.
    pub fn send(&mut self, text: &str, sender: Uuid, address: &str, elements: &mut dyn Elements) -> Result<Message, MessageError> {
        if elements.element(sender).is_none() {
            return Err(MessageError::UnknownSender);
        }
        let peers = self.peers(sender, elements);
        let wanted = address.trim_matches(is_inline_space);
        let Some(target) = find_element(wanted, &peers) else {
            return Err(MessageError::NotConnected { to: wanted.to_string(), peers: peers.into_iter().map(|peer| peer.name).collect() });
        };
        self.deliver(text, sender, target.id, elements)
    }

    /// Sends `text` from any element (a browser relaying a page's call, …) to the connected
    /// element `recipient`, which must take messages.
    pub fn deliver(&mut self, text: &str, sender: Uuid, recipient: Uuid, elements: &mut dyn Elements) -> Result<Message, MessageError> {
        let source = elements.element(sender).ok_or(MessageError::UnknownSender)?;
        let text = text.trim();
        if text.is_empty() {
            return Err(MessageError::EmptyMessage);
        }
        let target = elements.element(recipient);
        let Some(target) = target.filter(|_| self.graph.connection_between(sender, recipient).is_some()) else {
            return Err(MessageError::NotConnected {
                to: elements.element(recipient).map_or_else(|| recipient.to_string(), |element| element.name),
                peers: self.peers(sender, elements).into_iter().map(|peer| peer.name).collect(),
            });
        };
        let Some(endpoint) = target.endpoint else { return Err(MessageError::NotAnEndpoint { name: target.name }) };
        if let Some(reason) = endpoint.unavailable_reason {
            return Err(MessageError::Unavailable { name: target.name, reason });
        }
        let message = Message::new(sender, target.id, text);
        elements.receive(&message, &source);
        if let Some(sent) = &mut self.on_message {
            sent(&message);
        }
        Ok(message)
    }
}
