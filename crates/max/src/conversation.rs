//! A conversation's actor: the one writer of its timeline and the driver
//! of its core. See "会话 actor" in docs/rust-rewrite.md.

pub mod ingest;
pub mod project;
#[cfg(test)]
mod testing;

use max_core::ids::{ConversationId, EndpointId};
use max_core::message::Platform;
use max_db::platform::{Account, ConversationKind};

/// Where a conversation lives. v1 has one endpoint per conversation; the
/// mirror will make this a list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Place {
    pub conversation: ConversationId,
    pub kind: ConversationKind,
    pub endpoint: EndpointId,
    pub platform: Platform,
    /// The adapter's id for the endpoint, such as `group:<group_openid>`.
    pub native_id: String,
    /// Max's account there.
    pub me: Account,
    pub my_name: String,
}
