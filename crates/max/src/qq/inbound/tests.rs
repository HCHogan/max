//! Shaped like what the gateway sent in the 2026-10-29 tests, with made-up
//! ids.

use chrono::TimeZone;
use serde_json::{Value, json};

use super::*;

fn dispatch(kind: &str, data: Value) -> Dispatch {
    Dispatch {
        kind: kind.into(),
        id: None,
        seq: Some(7),
        event: Event::parse(kind, &data),
        data,
    }
}

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 29, 12, 0, 0).unwrap()
}

fn text(text: &str) -> InNode {
    InNode::Node(Node::Text { text: text.into() })
}

#[test]
fn a_group_message_with_everything() {
    let data = json!({
        "id": "ROBOT1.0_MSG1",
        "group_openid": "GROUP1",
        "author": { "member_openid": "XIAOMING", "username": "小明", "member_role": "admin" },
        "content": "<@BOT> 看<@XIAOHONG>这个<faceType=1,faceId=\"306\",ext=\"eyJ0ZXh0IjogIueJm+awlOWGsuWkqSJ9\"> a<b <@all>",
        "timestamp": "2026-10-29T10:00:00+08:00",
        "mentions": [
            { "id": "BOT", "username": "maxx", "bot": true, "is_you": true },
            { "member_openid": "XIAOHONG", "username": "小红" }
        ],
        "attachments": [{
            "content_type": "image/png", "url": "https://example.com/a.png",
            "filename": "a.png", "size": 1024, "width": 10, "height": 10
        }],
        "message_scene": { "source": "default", "ext": ["msg_idx=IDX9", "ref_msg_idx=IDX8"] },
        "msg_elements": [
            { "msg_idx": "IDX8", "message_type": 103, "content": "早" }
        ]
    });
    let inbound = inbound(&dispatch("GROUP_MESSAGE_CREATE", data.clone()), now()).unwrap();
    assert_eq!(
        inbound.chat,
        Chat {
            native_id: "group:GROUP1".into(),
            kind: ConversationKind::Group,
        }
    );
    assert_eq!(inbound.native_id, "ROBOT1.0_MSG1");
    assert_eq!(inbound.quote_id.as_deref(), Some("IDX9"));
    assert_eq!(
        inbound.sender,
        Person {
            native_user_id: "XIAOMING".into(),
            name: "小明".into(),
            role: Some(Role::Admin),
        }
    );
    assert_eq!(
        inbound.at,
        Utc.with_ymd_and_hms(2026, 10, 29, 2, 0, 0).unwrap()
    );
    assert_eq!(
        inbound.quote,
        Some(Quote {
            quote_id: Some("IDX8".into()),
            text: Some("早".into()),
        })
    );
    assert_eq!(
        inbound.nodes,
        [
            InNode::MentionMe {
                display: "maxx".into()
            },
            text(" 看"),
            InNode::Mention {
                user: "XIAOHONG".into(),
                display: "小红".into()
            },
            text("这个"),
            InNode::Node(Node::Emote(Emote {
                platform: Platform::Qq,
                id: "306".into(),
                name: Some("牛气冲天".into()),
            })),
            text(" a<b "),
            InNode::Node(Node::Mention {
                target: MentionTarget::All,
                display: "全体成员".into(),
            }),
            InNode::Node(Node::Media {
                media: None,
                meta: MediaMeta {
                    kind: MediaKind::Image,
                    mime: Some("image/png".into()),
                    size: Some(1024),
                    name: Some("a.png".into()),
                    description: None,
                },
            }),
        ]
    );
    assert!(inbound.mentions_me());
    assert_eq!(inbound.plain_text(), "看@小红这个 a<b");
    assert_eq!(inbound.raw, data);
}

#[test]
fn a_private_voice_message() {
    let data = json!({
        "id": "ROBOT1.0_C2C1",
        "author": { "user_openid": "USER1", "username": "" },
        "content": "",
        "attachments": [{ "content_type": "voice", "asr_refer_text": "你好" }]
    });
    let inbound = inbound(&dispatch("C2C_MESSAGE_CREATE", data), now()).unwrap();
    assert_eq!(inbound.chat.native_id, "c2c:USER1");
    assert_eq!(inbound.chat.kind, ConversationKind::Direct);
    assert_eq!(inbound.sender.role, None);
    assert_eq!(inbound.sender.name, "某人");
    assert_eq!(inbound.at, now());
    assert_eq!(inbound.quote, None);
    let [InNode::Node(Node::Media { meta, .. })] = &inbound.nodes[..] else {
        panic!("{:?}", inbound.nodes);
    };
    assert_eq!(meta.kind, MediaKind::Audio);
    assert_eq!(meta.description.as_deref(), Some("你好"));
}

#[test]
fn other_events_are_not_messages() {
    let data = json!({ "group_openid": "GROUP1", "op_member_openid": "XIAOMING" });
    assert_eq!(inbound(&dispatch("GROUP_ADD_ROBOT", data), now()), None);
}

#[test]
fn base64_both_ways_of_padding() {
    assert_eq!(base64("aGk=").as_deref(), Some(&b"hi"[..]));
    assert_eq!(base64("aGk").as_deref(), Some(&b"hi"[..]));
    assert_eq!(base64("a!"), None);
}
