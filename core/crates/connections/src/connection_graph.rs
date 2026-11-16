use serde::{Deserialize, Serialize};

use crate::Uuid;

/// A side of a card, where a line may attach. On the wire, its number.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(into = "u8", try_from = "u8")]
pub enum Side {
    Top = 0,
    Right = 1,
    Bottom = 2,
    Left = 3,
}

impl Side {
    pub const ALL: [Side; 4] = [Side::Top, Side::Right, Side::Bottom, Side::Left];
}

impl From<Side> for u8 {
    fn from(side: Side) -> u8 {
        side as u8
    }
}

impl TryFrom<u8> for Side {
    type Error = String;

    fn try_from(value: u8) -> Result<Self, String> {
        Side::ALL.get(value as usize).copied().ok_or_else(|| format!("no side {value}"))
    }
}

/// A line between two board elements. Undirected: messages travel both ways.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub id: Uuid,
    pub a: Uuid,
    pub b: Uuid,
    /// The sides the user drew the line from and to; none lets the router pick.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub a_side: Option<Side>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub b_side: Option<Side>,
}

impl Connection {
    pub fn new(a: Uuid, b: Uuid) -> Self {
        Self { id: Uuid::new(), a, b, a_side: None, b_side: None }
    }

    pub fn touches(&self, element: Uuid) -> bool {
        self.a == element || self.b == element
    }

    /// The element at the other end from `element`, or none when it isn't an end.
    pub fn other(&self, element: Uuid) -> Option<Uuid> {
        if element == self.a {
            Some(self.b)
        } else if element == self.b {
            Some(self.a)
        } else {
            None
        }
    }

    pub fn joins(&self, x: Uuid, y: Uuid) -> bool {
        (self.a == x && self.b == y) || (self.a == y && self.b == x)
    }
}

/// Which elements are connected, in the order the connections were made (earlier ones get
/// first pick of the board's routes).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct ConnectionGraph {
    connections: Vec<Connection>,
}

impl ConnectionGraph {
    pub fn new(connections: Vec<Connection>) -> Self {
        Self { connections }
    }

    pub fn connections(&self) -> &[Connection] {
        &self.connections
    }

    pub fn connection_between(&self, x: Uuid, y: Uuid) -> Option<&Connection> {
        self.connections.iter().find(|connection| connection.joins(x, y))
    }

    /// Elements one line away from `element`, in connection order.
    pub fn peers(&self, element: Uuid) -> Vec<Uuid> {
        self.connections.iter().filter_map(|connection| connection.other(element)).collect()
    }

    /// Adds a line between `x` and `y`, attached to the given sides. None for a
    /// self-connection or one that exists.
    pub fn connect(&mut self, x: Uuid, y: Uuid, sides: (Option<Side>, Option<Side>)) -> Option<Connection> {
        let connection = Connection { a_side: sides.0, b_side: sides.1, ..Connection::new(x, y) };
        self.add(connection.clone()).then_some(connection)
    }

    /// Adds `connection` as it is (drawn elsewhere, with its id). False for a
    /// self-connection or one between elements already connected.
    pub fn add(&mut self, connection: Connection) -> bool {
        if connection.a == connection.b || self.connection_between(connection.a, connection.b).is_some() {
            return false;
        }
        self.connections.push(connection);
        true
    }

    pub fn disconnect(&mut self, id: Uuid) {
        self.connections.retain(|connection| connection.id != id);
    }

    /// Drops every line touching `element`.
    pub fn remove(&mut self, element: Uuid) {
        self.connections.retain(|connection| !connection.touches(element));
    }
}
