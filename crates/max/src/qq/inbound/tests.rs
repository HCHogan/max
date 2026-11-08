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
    let inbound = inbound(&mut dispatch("GROUP_MESSAGE_CREATE", data.clone()), now()).unwrap();
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
            files: Vec::new(),
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
                media: Some(MediaRef::Remote("https://example.com/a.png".into())),
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
        "attachments": [{
            "content_type": "voice", "url": "example.com/v.silk",
            "voice_wav_url": "//example.com/v.wav", "asr_refer_text": "你好"
        }]
    });
    let inbound = inbound(&mut dispatch("C2C_MESSAGE_CREATE", data), now()).unwrap();
    assert_eq!(inbound.chat.native_id, "c2c:USER1");
    assert_eq!(inbound.chat.kind, ConversationKind::Direct);
    assert_eq!(inbound.sender.role, None);
    assert_eq!(inbound.sender.name, "某人");
    assert_eq!(inbound.at, now());
    assert_eq!(inbound.quote, None);
    let [InNode::Node(Node::Media { media, meta })] = &inbound.nodes[..] else {
        panic!("{:?}", inbound.nodes);
    };
    let wav = MediaRef::Remote("https://example.com/v.wav".into());
    assert_eq!(media.as_ref(), Some(&wav), "the WAV, with a scheme");
    assert_eq!(meta.kind, MediaKind::Audio);
    assert_eq!(meta.description.as_deref(), Some("你好"));
}

#[test]
fn other_events_are_not_messages() {
    let data = json!({ "group_openid": "GROUP1", "op_member_openid": "XIAOMING" });
    assert_eq!(inbound(&mut dispatch("GROUP_ADD_ROBOT", data), now()), None);
}

#[test]
fn base64_both_ways_of_padding() {
    assert_eq!(base64("aGk=").as_deref(), Some(&b"hi"[..]));
    assert_eq!(base64("aGk").as_deref(), Some(&b"hi"[..]));
    assert_eq!(base64("a!"), None);
}

/// What a quote says of the message it quotes, as QQ shows it.
fn quoting(quoted: Value) -> Option<Quote> {
    let data = json!({
        "id": "ROBOT1.0_MSG2",
        "group_openid": "GROUP1",
        "author": { "member_openid": "XIAOMING", "username": "小明" },
        "content": "<@BOT> 这是什么",
        "mentions": [{ "id": "BOT", "username": "maxx", "bot": true, "is_you": true }],
        "message_type": 103,
        "message_scene": { "source": "default", "ext": ["msg_idx=IDX9", "ref_msg_idx=IDX8"] },
        "msg_elements": [quoted]
    });
    inbound(&mut dispatch("GROUP_MESSAGE_CREATE", data), now())
        .unwrap()
        .quote
}

#[test]
fn a_quoted_picture_by_its_file_name() {
    // Shaped like a quote of a picture on 2026-11-08: no text, the picture.
    let quote = quoting(json!({
        "msg_idx": "IDX8", "message_type": 103, "content": "",
        "attachments": [{
            "content_type": "image/png", "filename": "0A1B2C3D4E5F60718293A4B5C6D7E8F9.png",
            "url": "https://example.com/p.png", "size": 1024, "width": 10, "height": 10
        }]
    }));
    assert_eq!(
        quote,
        Some(Quote {
            quote_id: Some("IDX8".into()),
            text: None,
            files: vec!["0A1B2C3D4E5F60718293A4B5C6D7E8F9.png".into()],
        })
    );
}

#[test]
fn quoted_text_without_mentions_or_faces() {
    let quote = quoting(json!({
        "msg_idx": "IDX8", "message_type": 103,
        "content": "<@XIAOHONG> 明天<faceType=1,faceId=\"76\",ext=\"\">几点"
    }));
    let quote = quote.unwrap();
    assert_eq!(quote.text.as_deref(), Some(" 明天几点"));
    assert!(quote.files.is_empty());
}

#[test]
fn a_quoted_quote_comes_as_a_dump() {
    // A quote of a message that quoted another: its own text and files,
    // not what it quotes, which is indented after [关联消息].
    let dump = "=== 消息 1 ===\n\
        [消息内容]   ？这上面的照片是\n何意味\n\
        [消息类型] 引用消息\n\
        [附件1] 类型:图片 文件名:11111111111111111111111111111111.jpg 尺寸:30x40 大小:8.2MB URL:https://example.com/1\n\
        [关联消息]\n\
        --- 第1条 ---\n    \
        [消息内容] 看\n    \
        [消息类型] 引用消息\n    \
        [附件1] 类型:图片 文件名:22222222222222222222222222222222.jpg 尺寸:30x40 大小:1MB URL:https://example.com/2\n";
    let quote = quoting(json!({ "msg_idx": "IDX8", "message_type": 103, "content": dump }));
    assert_eq!(
        quote,
        Some(Quote {
            quote_id: Some("IDX8".into()),
            text: Some("   ？这上面的照片是\n何意味".into()),
            files: vec!["11111111111111111111111111111111.jpg".into()],
        })
    );

    // One with no text of its own, and a forward, which has none either.
    let empty = "=== 消息 1 ===\n[消息内容]   \n\n[消息类型] 引用消息\n[关联消息]\n--- 第1条 ---\n    [消息内容] 早\n";
    let quote = quoting(json!({ "msg_idx": "IDX8", "message_type": 103, "content": empty }));
    assert_eq!(quote.unwrap().text, None);
    let forward = "=== 消息 1 ===\n[消息内容] [群聊的聊天记录]\n[消息类型] 引用消息\n[关联消息]\n--- 第1条 ---\n    [消息内容] 早\n    [发送者] 小红\n";
    let quote = quoting(json!({ "msg_idx": "IDX8", "message_type": 103, "content": forward }));
    assert_eq!(quote.unwrap().text.as_deref(), Some(" [群聊的聊天记录]"));
}
