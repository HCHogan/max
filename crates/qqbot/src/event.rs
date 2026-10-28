//! What the gateway dispatches. Only the events Max uses get types; every
//! event also keeps its payload as it came, for the ledger's `raw`.
//!
//! Fields are lenient: QQ adds fields freely and leaves documented ones
//! out, and an event that fails to parse would be a message lost.

use serde::Deserialize;
use serde_json::Value;

/// One dispatched event.
#[derive(Clone, Debug, PartialEq)]
pub struct Dispatch {
    /// The event type, such as `GROUP_MESSAGE_CREATE`.
    pub kind: String,
    /// The event's own id, for answering events that can be answered.
    pub id: Option<String>,
    /// Its sequence number: a session resumed from here replays what
    /// came after it.
    pub seq: Option<u64>,
    /// The payload as it came.
    pub data: Value,
    pub event: Event,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// A group message. With every message allowed, messages that @ the
    /// bot come this way too; `at` only says the event was
    /// `GROUP_AT_MESSAGE_CREATE`.
    Group {
        at: bool,
        message: GroupMessage,
    },
    Private(PrivateMessage),
    /// The bot was added to a group, or removed from one.
    JoinedGroup(GroupChange),
    LeftGroup(GroupChange),
    /// The group owner turned the bot's proactive messages off, or on.
    GroupProactiveOff(GroupChange),
    GroupProactiveOn(GroupChange),
    /// Someone added the bot as a friend, or removed it.
    FriendAdded(Friend),
    FriendRemoved(Friend),
    /// Someone turned the bot's proactive private messages off, or on.
    PrivateProactiveOff(Friend),
    PrivateProactiveOn(Friend),
    /// A known type that didn't parse.
    Malformed(String),
    Other,
}

impl Event {
    pub fn parse(kind: &str, data: &Value) -> Self {
        fn typed<T: for<'de> Deserialize<'de>>(
            data: &Value,
            wrap: impl FnOnce(T) -> Event,
        ) -> Event {
            match T::deserialize(data) {
                Ok(value) => wrap(value),
                Err(error) => Event::Malformed(error.to_string()),
            }
        }
        match kind {
            "GROUP_AT_MESSAGE_CREATE" => typed(data, |message| Self::Group { at: true, message }),
            "GROUP_MESSAGE_CREATE" => typed(data, |message| Self::Group { at: false, message }),
            "C2C_MESSAGE_CREATE" => typed(data, Self::Private),
            "GROUP_ADD_ROBOT" => typed(data, Self::JoinedGroup),
            "GROUP_DEL_ROBOT" => typed(data, Self::LeftGroup),
            "GROUP_MSG_REJECT" => typed(data, Self::GroupProactiveOff),
            "GROUP_MSG_RECEIVE" => typed(data, Self::GroupProactiveOn),
            "FRIEND_ADD" => typed(data, Self::FriendAdded),
            "FRIEND_DEL" => typed(data, Self::FriendRemoved),
            "C2C_MSG_REJECT" => typed(data, Self::PrivateProactiveOff),
            "C2C_MSG_RECEIVE" => typed(data, Self::PrivateProactiveOn),
            _ => Self::Other,
        }
    }
}

/// A user as an event gives them. Which ids are set depends on where:
/// `member_openid` in groups, where it differs from group to group, and
/// `user_openid` in private chats.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct User {
    pub id: Option<String>,
    pub username: Option<String>,
    pub bot: bool,
    pub member_openid: Option<String>,
    pub user_openid: Option<String>,
    /// Only with a special permission; usually empty.
    pub union_openid: Option<String>,
    /// owner, admin or member.
    pub member_role: Option<String>,
    /// In `mentions`: this is the bot.
    pub is_you: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Attachment {
    /// A MIME type, or a word such as voice or file.
    pub content_type: Option<String>,
    pub url: Option<String>,
    pub filename: Option<String>,
    pub size: Option<u64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// A voice message converted to WAV.
    pub voice_wav_url: Option<String>,
    /// Tencent's transcript of a voice message.
    pub asr_refer_text: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Scene {
    pub source: Option<String>,
    /// `key=value` strings.
    pub ext: Vec<String>,
}

impl Scene {
    pub fn ext(&self, key: &str) -> Option<&str> {
        self.ext.iter().find_map(|entry| {
            let (k, v) = entry.split_once('=')?;
            (k == key && !v.is_empty()).then_some(v)
        })
    }
}

/// A piece of a message: a quoted message, a forwarded chat history, a
/// card. They nest.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Element {
    pub msg_idx: Option<String>,
    pub author: Option<User>,
    /// 0 text, 3 card, 101 several messages, 102 chat history, 103 a
    /// quoted message.
    pub message_type: Option<i64>,
    pub content: Option<String>,
    pub attachments: Vec<Attachment>,
    pub msg_elements: Vec<Element>,
}

pub const QUOTED: i64 = 103;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct GroupMessage {
    /// For passive replies and recalling it.
    pub id: String,
    pub group_openid: String,
    pub author: User,
    /// Mentions are `<@member_openid>`, everyone is `<@all>`.
    #[serde(default)]
    pub content: String,
    /// RFC 3339.
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    pub mentions: Vec<User>,
    #[serde(default)]
    pub message_scene: Scene,
    #[serde(default)]
    pub msg_elements: Vec<Element>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct PrivateMessage {
    pub id: String,
    pub author: User,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    pub message_scene: Scene,
    #[serde(default)]
    pub msg_elements: Vec<Element>,
}

/// What both kinds of message share.
pub trait Message {
    fn scene(&self) -> &Scene;
    fn elements(&self) -> &[Element];

    /// The id to quote this message by.
    fn msg_idx(&self) -> Option<&str> {
        self.scene().ext("msg_idx")
    }

    /// The `msg_idx` of the message this one quotes.
    fn quotes(&self) -> Option<&str> {
        self.scene().ext("ref_msg_idx")
    }

    /// The quoted message, as QQ included it.
    fn quoted(&self) -> Option<&Element> {
        self.elements()
            .iter()
            .find(|element| element.message_type == Some(QUOTED))
    }
}

impl Message for GroupMessage {
    fn scene(&self) -> &Scene {
        &self.message_scene
    }

    fn elements(&self) -> &[Element] {
        &self.msg_elements
    }
}

impl Message for PrivateMessage {
    fn scene(&self) -> &Scene {
        &self.message_scene
    }

    fn elements(&self) -> &[Element] {
        &self.msg_elements
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct GroupChange {
    pub group_openid: String,
    /// Who did it. Only the bot's creator can add a personal bot.
    #[serde(default)]
    pub op_member_openid: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Friend {
    /// The person's `user_openid`.
    pub openid: String,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    // Shaped like the documented examples, with made-up ids.
    fn group_message() -> Value {
        json!({
            "id": "ROBOT1.0_group_msg",
            "author": {
                "id": "M0A1",
                "member_openid": "M0A1",
                "union_openid": "",
                "username": "小明",
                "member_role": "admin",
                "bot": false
            },
            "content": "<@B0T> 在吗",
            "group_id": "G0A1",
            "group_openid": "G0A1",
            "timestamp": "2026-10-29T10:00:00+08:00",
            "message_type": 0,
            "mentions": [{ "id": "B0T", "username": "maxx", "bot": true, "is_you": true }],
            "message_scene": {
                "source": "default",
                "ext": ["msg_idx=REFIDX_9", "ref_msg_idx=REFIDX_8", "auth_token=x"]
            },
            "msg_elements": [
                { "msg_idx": "REFIDX_9", "message_type": 0, "content": "<@B0T> 在吗" },
                {
                    "msg_idx": "REFIDX_8",
                    "message_type": 103,
                    "content": "早",
                    "author": { "member_openid": "M0A2", "username": "小红" }
                }
            ]
        })
    }

    #[test]
    fn a_group_message() {
        let Event::Group { at, message } =
            Event::parse("GROUP_AT_MESSAGE_CREATE", &group_message())
        else {
            panic!("not a group message");
        };
        assert!(at);
        assert_eq!(message.group_openid, "G0A1");
        assert_eq!(message.author.member_openid.as_deref(), Some("M0A1"));
        assert_eq!(message.author.member_role.as_deref(), Some("admin"));
        assert_eq!(message.mentions[0].id.as_deref(), Some("B0T"));
        assert!(message.mentions[0].is_you);
        assert_eq!(message.msg_idx(), Some("REFIDX_9"));
        assert_eq!(message.quotes(), Some("REFIDX_8"));
        let quoted = message.quoted().unwrap();
        assert_eq!(quoted.content.as_deref(), Some("早"));
        assert_eq!(
            quoted.author.as_ref().unwrap().username.as_deref(),
            Some("小红")
        );
    }

    #[test]
    fn a_bare_message_still_parses() {
        let data = json!({ "id": "m", "group_openid": "G", "author": { "member_openid": "M" } });
        let Event::Group { at, message } = Event::parse("GROUP_MESSAGE_CREATE", &data) else {
            panic!("not a group message");
        };
        assert!(!at);
        assert_eq!((message.content.as_str(), message.msg_idx()), ("", None));
        assert_eq!(message.quoted(), None);
    }

    #[test]
    fn a_private_message() {
        let data = json!({
            "id": "ROBOT1.0_c2c",
            "author": { "user_openid": "U0A1", "union_openid": "U0A1" },
            "content": "hi",
            "timestamp": "2026-10-29T10:00:00+08:00",
            "attachments": [{
                "content_type": "voice",
                "url": "https://example.com/v.silk",
                "voice_wav_url": "https://example.com/v.wav",
                "asr_refer_text": "你好"
            }],
            "message_scene": { "source": "default", "ext": ["msg_idx=REFIDX_1"] }
        });
        let Event::Private(message) = Event::parse("C2C_MESSAGE_CREATE", &data) else {
            panic!("not a private message");
        };
        assert_eq!(message.author.user_openid.as_deref(), Some("U0A1"));
        assert_eq!(
            message.attachments[0].asr_refer_text.as_deref(),
            Some("你好")
        );
        assert_eq!(message.msg_idx(), Some("REFIDX_1"));
    }

    #[test]
    fn group_and_friend_changes() {
        let data = json!({ "group_openid": "G0A1", "op_member_openid": "M0A1", "timestamp": 1_793_000_000 });
        assert_eq!(
            Event::parse("GROUP_ADD_ROBOT", &data),
            Event::JoinedGroup(GroupChange {
                group_openid: "G0A1".into(),
                op_member_openid: Some("M0A1".into()),
            })
        );
        let data = json!({ "openid": "U0A1", "timestamp": 1_793_000_000 });
        assert_eq!(
            Event::parse("C2C_MSG_REJECT", &data),
            Event::PrivateProactiveOff(Friend {
                openid: "U0A1".into()
            })
        );
    }

    #[test]
    fn unknown_and_broken_events() {
        assert_eq!(Event::parse("INTERACTION_CREATE", &json!({})), Event::Other);
        let broken = Event::parse("GROUP_MESSAGE_CREATE", &json!({ "id": 1 }));
        assert!(matches!(broken, Event::Malformed(_)), "{broken:?}");
    }
}
