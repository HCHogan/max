//! The ledger's message format. Projection, intent, search and later the
//! mirror all read this, whichever platform a message came from.
//!
//! Every non-text node carries its text fallback (a mention's display name,
//! a picture's caption, a card's title), captured when the message is
//! ingested, so degrading a node anywhere never needs a lookup. The
//! platform's original payload travels beside the nodes as `raw`: it is the
//! source of truth for a native round trip, and nodes can be rebuilt from it
//! if a normaliser changes.

use std::fmt::{self, Write};
use std::str::FromStr;

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

crate::names!(Platform, "platform", {
    Qq => "qq",
    QqLegacy => "qq_legacy",
});

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
    /// What is read of the platform's payload, the ledger's `raw`: who
    /// said a row of Max's account that Max didn't, else null. The rest
    /// stays in the ledger.
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

crate::names!(Role, "role", {
    Owner => "owner",
    Admin => "admin",
    Member => "member",
});

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

/// A file's name in the content store: the SHA-256 of its bytes, as 64
/// lowercase hex digits. The store makes one of the bytes it is given,
/// and text from outside is parsed; one in a stored node is read as it
/// was written.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Sha256(String);

impl Sha256 {
    /// Of the hash itself.
    #[must_use]
    pub fn of(digest: [u8; 32]) -> Self {
        let mut hex = String::with_capacity(2 * digest.len());
        for byte in digest {
            let _ = write!(hex, "{byte:02x}");
        }
        Self(hex)
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Text that isn't a file's name in the content store.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} isn't a SHA-256 in lowercase hex")]
pub struct NotSha256(String);

impl FromStr for Sha256 {
    type Err = NotSha256;

    fn from_str(text: &str) -> Result<Self, NotSha256> {
        let hex = |byte: u8| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte);
        if text.len() == 64 && text.bytes().all(hex) {
            Ok(Self(text.to_owned()))
        } else {
            Err(NotSha256(text.to_owned()))
        }
    }
}

impl fmt::Display for Sha256 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.pad(&self.0)
    }
}

/// Where a stored picture or file lives.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaRef {
    /// In the content store.
    Blob(Sha256),
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

// How a handle or a placeholder names it, too: `image#103.0`.
crate::names!(MediaKind, "media kind", {
    Image => "image",
    Sticker => "sticker",
    Video => "video",
    Audio => "audio",
    File => "file",
});

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
    /// A row's picture or sticker sent again, by its handle
    /// (`[sticker#123.0]`). Whether Max may send it is checked when it is
    /// committed.
    Picture {
        message: MessageId,
        ordinal: u16,
    },
    /// A picture a tool made, in the content store already. The model
    /// can't write it.
    Made {
        sha256: Sha256,
        mime: String,
        size: u64,
    },
    /// A file a tool sends, in the content store already, shown under
    /// `name`. The model can't write it.
    File {
        sha256: Sha256,
        name: String,
        size: u64,
    },
    /// A voice message a tool sends, in the content store already. The
    /// model can't write it.
    Voice {
        sha256: Sha256,
        size: u64,
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
            id: MessageId::new(7405),
            conversation: ConversationId::new(3),
            sender: Sender {
                identity: IdentityId::new(12),
                name: "小明".into(),
                role: Some(Role::Admin),
            },
            at: Utc.with_ymd_and_hms(2026, 10, 28, 12, 30, 0).unwrap(),
            content: Content::Message {
                reply_to: Some(MessageId::new(7400)),
                nodes: vec![
                    Node::Mention {
                        target: MentionTarget::Identity(IdentityId::new(1)),
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
