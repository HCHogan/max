//! The ledger's message format. Projection, intent, search and later the
//! mirror all read this, whichever platform a message came from.
//!
//! Every non-text node carries its text fallback (a mention's display name,
//! a picture's caption, a card's title), captured when the message is
//! ingested, so degrading a node anywhere never needs a lookup. The
//! platform's original payload travels beside the nodes as `raw`: it is the
//! source of truth for a native round trip, and nodes can be rebuilt from it
//! if a normaliser changes.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::ids::{ConversationId, IdentityId, MessageId, PrincipalId, TurnId};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    /// QQ through the official bot API: users and groups are openids.
    Qq,
    /// QQ as the Haskell version saw it through NapCat, by QQ and group
    /// numbers. Only imported history has it; nothing sends there.
    QqLegacy,
}

/// One row of a conversation's timeline.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub id: MessageId,
    pub conversation: ConversationId,
    pub sender: Sender,
    pub at: DateTime<Utc>,
    pub content: Content,
    /// For what Max said: the turn that said it.
    pub turn: Option<TurnId>,
    pub raw: serde_json::Value,
}

/// Who sent a message, as they were when they sent it. Names and roles are
/// snapshots, so a rename doesn't rewrite old lines.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sender {
    pub identity: IdentityId,
    pub name: String,
    /// None in private chats.
    pub role: Option<Role>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Owner,
    Admin,
    Member,
}

/// What a timeline row records: something said, or an event about an
/// earlier row.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Content {
    Message {
        reply_to: Option<MessageId>,
        nodes: Vec<Node>,
    },
    /// The new content of an earlier message.
    Edit { target: MessageId, nodes: Vec<Node> },
    /// The earlier message was recalled or redacted.
    Unsend { target: MessageId },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Node {
    Text {
        text: String,
    },
    Mention {
        target: MentionTarget,
        display: String,
    },
    Emote(Emote),
    Media {
        media: Option<MediaRef>,
        meta: MediaMeta,
    },
    Card(Card),
    Forward(ForwardRef),
    Unsupported(Unsupported),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MentionTarget {
    Identity(IdentityId),
    All,
}

/// A platform's own face or emote. Only native when sent back to the
/// platform it came from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Emote {
    pub platform: Platform,
    pub id: String,
    pub name: Option<String>,
}

/// A message's media nodes with their ordinals, from 0: `image#<id>.<n>`.
pub fn media(nodes: &[Node]) -> impl Iterator<Item = (u16, Option<&MediaRef>, &MediaMeta)> {
    nodes
        .iter()
        .filter_map(|node| match node {
            Node::Media { media, meta } => Some((media.as_ref(), meta)),
            _ => None,
        })
        .zip(0..)
        .map(|((media, meta), n)| (n, media, meta))
}

/// Where a stored picture or file lives.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaRef {
    /// Content-addressed, by lowercase SHA-256 hex.
    Blob(String),
    Remote(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaMeta {
    pub kind: MediaKind,
    pub mime: Option<String>,
    pub size: Option<u64>,
    pub name: Option<String>,
    /// The caption or summary. Never blank: no caption is None.
    pub description: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Image,
    Sticker,
    Video,
    Audio,
    File,
}

impl MediaKind {
    /// How a handle or placeholder names it: `image`, `sticker`, …
    pub fn word(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Sticker => "sticker",
            Self::Video => "video",
            Self::Audio => "audio",
            Self::File => "file",
        }
    }
}

/// A share card, such as a QQ lightapp.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    /// Where it's from, such as "哔哩哔哩".
    pub tag: Option<String>,
    pub title: Option<String>,
    pub subtitle: Option<String>,
    pub url: Option<String>,
}

/// A forwarded chat record. Its messages are rows of their own.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForwardRef {
    pub native_id: String,
    pub count: Option<u32>,
}

/// Anything the normaliser doesn't understand.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unsupported {
    /// The platform's name for it, such as a OneBot segment type.
    pub source: String,
    /// Required: what a reader sees instead, such as "语音消息".
    pub description: String,
}

/// What the model can write: one message of a reply. Forwards, cards and
/// unsupported nodes have no counterpart because the model can't author
/// them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Draft {
    pub reply_to: Option<MessageId>,
    pub nodes: Vec<DraftNode>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DraftNode {
    Text {
        text: String,
    },
    /// Resolved to the person's account on the destination platform when
    /// sent; plain `@名字` where they have none.
    Mention {
        principal: PrincipalId,
    },
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    /// Messages are stored as JSON, so the shape is a schema: changing it
    /// needs a migration.
    #[test]
    fn stored_shape() {
        let message = Message {
            id: MessageId(7405),
            conversation: ConversationId(3),
            sender: Sender {
                identity: IdentityId(12),
                name: "小明".into(),
                role: Some(Role::Admin),
            },
            at: Utc.with_ymd_and_hms(2026, 10, 28, 12, 30, 0).unwrap(),
            content: Content::Message {
                reply_to: Some(MessageId(7400)),
                nodes: vec![
                    Node::Mention {
                        target: MentionTarget::Identity(IdentityId(1)),
                        display: "Max".into(),
                    },
                    Node::Text {
                        text: " 看这个".into(),
                    },
                    Node::Emote(Emote {
                        platform: Platform::Qq,
                        id: "212".into(),
                        name: Some("托腮".into()),
                    }),
                    Node::Media {
                        media: None,
                        meta: MediaMeta {
                            kind: MediaKind::Image,
                            mime: Some("image/png".into()),
                            size: None,
                            name: None,
                            description: Some("一只猫".into()),
                        },
                    },
                    Node::Card(Card {
                        tag: Some("哔哩哔哩".into()),
                        title: Some("视频标题".into()),
                        subtitle: None,
                        url: Some("https://b23.tv/xxxx".into()),
                    }),
                    Node::Unsupported(Unsupported {
                        source: "record".into(),
                        description: "语音消息".into(),
                    }),
                ],
            },
            turn: None,
            raw: serde_json::json!({"post_type": "message"}),
        };
        insta::assert_json_snapshot!(message);
        let back: Message =
            serde_json::from_value(serde_json::to_value(&message).unwrap()).unwrap();
        assert_eq!(back, message);
    }
}
