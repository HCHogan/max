//! What a platform connection hands on: a message normalised into nodes,
//! with the platform's own ids still in it. Connections don't touch the
//! database; the conversation actor resolves accounts, quotes and mentions
//! when it commits the row.

use chrono::{DateTime, Utc};
use max_core::message::{Node, Platform, Role};

use max_db::platform::ConversationKind;

#[derive(Clone, Debug, PartialEq)]
pub struct Inbound {
    pub platform: Platform,
    pub chat: Chat,
    /// The platform's id for the message.
    pub native_id: String,
    /// The id it is quoted by, where that differs: QQ's msg_idx.
    pub quote_id: Option<String>,
    pub sender: Person,
    pub at: DateTime<Utc>,
    pub quote: Option<Quote>,
    pub nodes: Vec<InNode>,
    pub raw: serde_json::Value,
}

/// A group or a private chat, by the adapter's endpoint id, such as
/// `group:<group_openid>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chat {
    pub native_id: String,
    pub kind: ConversationKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Person {
    pub native_user_id: String,
    pub name: String,
    /// None in private chats.
    pub role: Option<Role>,
}

/// The message this one quotes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Quote {
    pub quote_id: Option<String>,
    /// What the platform showed of it, to find it by when the id is
    /// unknown.
    pub text: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum InNode {
    Node(Node),
    /// Someone, by their platform id.
    Mention {
        user: String,
        display: String,
    },
    /// Max.
    MentionMe {
        display: String,
    },
}

impl Inbound {
    /// What the sender wrote, without the @ of Max: a command's text, and
    /// what intent's gate reads.
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
        text.trim().to_owned()
    }

    pub fn mentions_me(&self) -> bool {
        self.nodes
            .iter()
            .any(|node| matches!(node, InNode::MentionMe { .. }))
    }
}
