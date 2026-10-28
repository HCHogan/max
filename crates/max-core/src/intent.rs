//! intent decides when to wake the core. Every row the conversation actor
//! commits goes through it: direct triggers wake the core at once (after a
//! short wait if the sender seems to be mid-sentence), and other chatter
//! passes a gate to a small classifier model.

use serde::{Deserialize, Serialize};

/// Why the core was woken.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reason {
    /// An @, a reply to Max, a poke, or a private message from someone on
    /// the list.
    Direct,
    /// The classifier judged that Max should join in.
    Judged { kind: Kind, note: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Someone called Max without an @, such as by name.
    Called,
    /// A follow-up to what Max just said.
    Followup,
    /// A topic Max can help with.
    Topic,
}
