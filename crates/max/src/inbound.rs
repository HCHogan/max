//! What a platform connection hands on: a message normalised into nodes,
//! with the platform's own ids still in it. Connections don't touch the
//! database; the conversation actor resolves accounts, quotes and mentions
//! when it commits the row.

use chrono::{DateTime, Utc};
use max_core::message::{Node, Platform, Role};

use max_db::platform::ConversationKind;

/// A message someone sent, as its platform's adapter read it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inbound {
    pub platform: Platform,
    pub chat: Chat,
    /// The platform's id for the message.
    pub native_id: String,
    /// The id it is quoted by, where that differs: QQ's msg_idx.
    pub quote_id: Option<String>,
    pub sender: Person,
    /// When the platform says it was sent.
    pub at: DateTime<Utc>,
    pub quote: Option<Quote>,
    /// What it says, in order.
    pub nodes: Vec<InNode>,
    /// The platform's payload, kept as it came.
    pub raw: serde_json::Value,
}

/// A group or a private chat, by the adapter's endpoint id, such as
/// `group:<group_openid>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chat {
    /// The adapter's id for the chat.
    pub native_id: String,
    /// A group or a private chat.
    pub kind: ConversationKind,
}

/// Someone in a chat, as their platform has them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Person {
    /// The platform's id for their account.
    pub native_user_id: String,
    pub name: String,
    /// None in private chats.
    pub role: Option<Role>,
}

/// The message this one quotes.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Quote {
    /// The id the quoted message is quoted by, where the platform gives it.
    pub quote_id: Option<String>,
    /// Its text as the platform showed it, without mentions or faces, to
    /// find it by when the id is unknown.
    pub text: Option<String>,
    /// The names of its pictures and files as the platform showed them, to
    /// find it by with `text`.
    pub files: Vec<String>,
}

/// A piece of an inbound message: a node, or a mention not yet tied to
/// an account.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InNode {
    /// What needs no looking up.
    Node(Node),
    /// Someone, by their platform id.
    Mention {
        /// The platform's id for whom.
        user: String,
        /// The name the @ showed.
        display: String,
    },
    /// Max.
    MentionMe {
        /// The name the @ showed.
        display: String,
    },
}

impl Inbound {
    /// What the sender wrote, without the @ of Max: what a command is read
    /// from.
    #[must_use]
    pub fn plain_text(&self) -> String {
        let mut text = String::new();
        for node in &self.nodes {
            match node {
                InNode::Node(Node::Text { text: piece }) => text.push_str(piece),
                InNode::Mention { display, .. } => {
                    text.push('@');
                    text.push_str(display);
                }
                InNode::Node(_) | InNode::MentionMe { .. } => {}
            }
        }
        text.truncate(text.trim_end().len());
        text.drain(..text.len() - text.trim_start().len());
        text
    }

    #[must_use]
    pub fn mentions_me(&self) -> bool {
        self.nodes
            .iter()
            .any(|node| matches!(node, InNode::MentionMe { .. }))
    }
}
