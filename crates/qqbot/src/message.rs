//! What Max sends to a chat, and what QQ answers.

use serde::{Deserialize, Serialize, Serializer};

/// A message to send.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outgoing {
    pub body: Body,
    /// Answering a message or event makes this a passive reply. Without
    /// it, the message is proactive, which the group owner has to allow.
    pub reply: Option<Reply>,
    /// The `msg_idx` or `ref_idx` of a message to quote.
    pub quote: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Body {
    Text(String),
    /// Native Markdown, open to every bot in groups and private chats
    /// since 2026-04-23.
    Markdown(String),
    /// A picture uploaded to the chat, with text under it in the same
    /// bubble; without, it looks like any picture or sticker sent.
    Media {
        file_info: String,
        caption: Option<String>,
    },
}

/// What a passive reply answers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reply {
    /// A message's `id`, within 5 minutes in a group (60 in a private
    /// chat). `seq` counts the replies to it from 1; QQ refuses a repeat.
    Message { id: String, seq: u32 },
    /// The outer `id` of an event that can be answered, such as the bot
    /// joining a group.
    Event(String),
}

impl Serialize for Outgoing {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let (msg_type, content, markdown, media) = match &self.body {
            Body::Text(text) => (0, Some(text.as_str()), None, None),
            Body::Markdown(text) => (2, None, Some(Markdown { content: text }), None),
            Body::Media { file_info, caption } => {
                (7, caption.as_deref(), None, Some(Media { file_info }))
            }
        };
        let (msg_id, msg_seq, event_id) = match &self.reply {
            Some(Reply::Message { id, seq }) => (Some(id.as_str()), Some(*seq), None),
            Some(Reply::Event(id)) => (None, None, Some(id.as_str())),
            None => (None, None, None),
        };
        Wire {
            msg_type,
            content,
            markdown,
            media,
            msg_id,
            msg_seq,
            event_id,
            message_reference: self.quote.as_deref().map(|id| Reference { message_id: id }),
        }
        .serialize(serializer)
    }
}

#[derive(Serialize)]
struct Wire<'a> {
    msg_type: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    markdown: Option<Markdown<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    media: Option<Media<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    msg_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    msg_seq: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    event_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message_reference: Option<Reference<'a>>,
}

#[derive(Serialize)]
struct Markdown<'a> {
    content: &'a str,
}

#[derive(Serialize)]
struct Media<'a> {
    file_info: &'a str,
}

#[derive(Serialize)]
struct Reference<'a> {
    message_id: &'a str,
}

/// QQ's answer to a message that went out. Only the id is required: the
/// message is out either way, and failing on a field we don't use would
/// record it as not sent.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(from = "SentWire")]
pub struct Sent {
    /// For recalling it.
    pub id: String,
    /// For quoting it.
    pub ref_idx: Option<String>,
}

#[derive(Deserialize)]
struct SentWire {
    id: String,
    #[serde(default)]
    ext_info: Option<ExtInfo>,
}

#[derive(Deserialize)]
struct ExtInfo {
    #[serde(default)]
    ref_idx: Option<String>,
}

impl From<SentWire> for Sent {
    fn from(wire: SentWire) -> Self {
        Self {
            id: wire.id,
            ref_idx: wire
                .ext_info
                .and_then(|ext| ext.ref_idx)
                .filter(|idx| !idx.is_empty()),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_passive_text_reply() {
        let message = Outgoing {
            body: Body::Text("早".into()),
            reply: Some(Reply::Message {
                id: "ROBOT1.0_msg".into(),
                seq: 2,
            }),
            quote: None,
        };
        assert_eq!(
            serde_json::to_value(&message).unwrap(),
            json!({ "msg_type": 0, "content": "早", "msg_id": "ROBOT1.0_msg", "msg_seq": 2 })
        );
    }

    #[test]
    fn proactive_markdown_quoting_a_message() {
        let message = Outgoing {
            body: Body::Markdown("**早**".into()),
            reply: None,
            quote: Some("REFIDX_1".into()),
        };
        assert_eq!(
            serde_json::to_value(&message).unwrap(),
            json!({
                "msg_type": 2,
                "markdown": { "content": "**早**" },
                "message_reference": { "message_id": "REFIDX_1" },
            })
        );
        let event = Outgoing {
            reply: Some(Reply::Event("GROUP_ADD_ROBOT:1".into())),
            ..message
        };
        assert_eq!(
            serde_json::to_value(&event).unwrap()["event_id"],
            "GROUP_ADD_ROBOT:1"
        );
    }

    #[test]
    fn a_picture() {
        let message = Outgoing {
            body: Body::Media {
                file_info: "FI".into(),
                caption: None,
            },
            reply: None,
            quote: None,
        };
        assert_eq!(
            serde_json::to_value(&message).unwrap(),
            json!({ "msg_type": 7, "media": { "file_info": "FI" } })
        );
        let captioned = Outgoing {
            body: Body::Media {
                file_info: "FI".into(),
                caption: Some("每日活跃".into()),
            },
            ..message
        };
        assert_eq!(
            serde_json::to_value(&captioned).unwrap()["content"],
            "每日活跃"
        );
    }

    #[test]
    fn what_comes_back() {
        let sent: Sent = serde_json::from_value(json!({
            "id": "ROBOT1.0_sent",
            "timestamp": "2026-10-28T20:00:00+08:00",
            "ext_info": { "ref_idx": "REFIDX_2" },
        }))
        .unwrap();
        assert_eq!(
            sent,
            Sent {
                id: "ROBOT1.0_sent".into(),
                ref_idx: Some("REFIDX_2".into()),
            }
        );
        let bare: Sent = serde_json::from_value(json!({ "id": "x", "timestamp": 1 })).unwrap();
        assert_eq!(bare.ref_idx, None);
    }
}
