use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// An id as Swift's `UUID` writes it: uppercase, in text and in JSON alike. The same type as
/// `connections::Uuid`, which this crate doesn't depend on.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Uuid(uuid::Uuid);

impl Uuid {
    /// A random one.
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }

    /// As `UUID(uuidString:)`: the 36-character hyphenated form only, in either case.
    pub fn parse(text: &str) -> Option<Self> {
        (text.len() == 36).then(|| uuid::Uuid::try_parse(text).ok().map(Self)).flatten()
    }

    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(uuid::Uuid::from_bytes(bytes))
    }

    /// The id a `data` or `snapshot` frame starts with.
    pub fn from_prefix(bytes: &[u8]) -> Option<Self> {
        Some(Self::from_bytes(bytes.get(..16)?.try_into().ok()?))
    }

    pub const fn as_bytes(&self) -> &[u8; 16] {
        self.0.as_bytes()
    }

    /// As `uuidString.lowercased()`, the form the agent CLIs take.
    pub fn lowercased(&self) -> String {
        self.0.hyphenated().to_string()
    }
}

impl fmt::Display for Uuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0.hyphenated().encode_upper(&mut uuid::Uuid::encode_buffer()))
    }
}

impl fmt::Debug for Uuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl Serialize for Uuid {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Uuid {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::parse(&text).ok_or_else(|| serde::de::Error::custom(format!("not a UUID: {text}")))
    }
}
