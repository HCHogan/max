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

fn medium(kind: MediaKind, name: &str, url: &str) -> InNode {
    InNode::Node(Node::Media {
        media: Some(MediaRef::Remote(url.into())),
        meta: MediaMeta {
            kind,
            mime: None,
            size: None,
            name: Some(name.into()),
            description: None,
        },
    })
}

/// Shaped like the transcripts QQ sent for forwards in November 2026, with
/// made-up names and links.
#[test]
fn a_merged_forward_in_maxs_form() {
    let content = "[群聊的聊天记录]
=== 消息 1 ===
[消息内容] 看这个
第二行
[发送者] 小明
[附件1] 类型:图片 文件名:A1.jpg 尺寸:10x10 大小:1.0KB URL:https://example.com/a1?rkey=x
[附件2] 类型:文件 文件名:报告 终版.pdf 大小:5.8MB URL:https://example.com/f

=== 消息 2 ===
[消息内容] 好家伙<faceType=1,faceId=\"13\",ext=\"eyJ0ZXh0IjogIuWRsueJmSJ9\">
[发送者] 小红
[关联消息]
--- 第1条 ---
    [消息内容] 看这个
    [消息类型] 引用消息

=== 消息 3 ===
[消息内容] [群聊的聊天记录]
[发送者] 小明
[消息类型] 合并转发消息
[关联消息]
--- 第1条 ---
    [消息内容] 早
    def f():
        pass
    [发送者] 小刚
--- 第2条 ---
    [发送者] 小刚
    [附件1] 类型:动图 文件名:B2.gif 尺寸:240x240 大小:19.5KB URL:https://example.com/b2

=== 消息 4 ===
[消息内容] [聊天记录]
[发送者] 小红
[消息类型] 合并转发消息

";
    let data = json!({
        "id": "ROBOT1.0_MSG2",
        "group_openid": "GROUP1",
        "author": { "member_openid": "XIAOMING", "username": "小明" },
        "content": content,
        "message_type": 102,
    });
    let inbound = inbound(&mut dispatch("GROUP_MESSAGE_CREATE", data), now()).unwrap();
    assert_eq!(
        inbound.nodes,
        [
            text("[forward: 群聊的聊天记录, 4 条]\n小明: 看这个\n  第二行 "),
            medium(MediaKind::Image, "A1.jpg", "https://example.com/a1?rkey=x"),
            text(" "),
            medium(MediaKind::File, "报告 终版.pdf", "https://example.com/f"),
            text("\n小红: [reply: 看这个] 好家伙"),
            InNode::Node(Node::Emote(Emote {
                platform: Platform::Qq,
                id: "13".into(),
                name: Some("呲牙".into()),
            })),
            text(
                "\n小明: [forward: 群聊的聊天记录, 2 条]\n  小刚: 早\n    def f():\n        pass\n  小刚: "
            ),
            medium(MediaKind::Image, "B2.gif", "https://example.com/b2"),
            text("\n小红: [forward: 聊天记录]"),
        ]
    );
}
