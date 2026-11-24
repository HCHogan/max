//! Lines as wxdesk sent them, in the test group, with made-up names.

use super::*;

fn line(json: &str) -> Message {
    serde_json::from_str(json).unwrap()
}

fn now() -> DateTime<Utc> {
    DateTime::from_timestamp(1_795_520_000, 0).unwrap()
}

#[test]
fn mentions_of_max_and_of_someone() {
    let m = line(
        r#"{"seq":3,"chat":"测试群","group":true,"sender":"小明","mine":false,"kind":"text",
            "text":"@Max 看看 @小红 的 a@b.com","quote":null,"mentions_me":true,
            "attachment":null,"at":1795519219}"#,
    );
    let inbound = inbound(&m, 1700, "Max", None, now()).unwrap();
    assert_eq!(inbound.chat.native_id, "group:测试群");
    assert_eq!(inbound.chat.kind, ConversationKind::Group);
    assert_eq!(inbound.native_id, "1700-3");
    assert_eq!(inbound.sender.native_user_id, "小明");
    assert_eq!(inbound.sender.role, Some(Role::Member));
    assert_eq!(
        inbound.nodes,
        vec![
            InNode::MentionMe {
                display: "Max".into()
            },
            InNode::Node(Node::Text {
                text: "看看 ".into()
            }),
            InNode::Mention {
                user: "小红".into(),
                display: "小红".into()
            },
            InNode::Node(Node::Text {
                text: "的 a@b.com".into()
            }),
        ]
    );
}

#[test]
fn a_quote_in_a_private_chat() {
    let m = line(
        r#"{"seq":4,"chat":"小明","group":false,"sender":"小明","mine":false,"kind":"text",
            "text":"这个呢","quote":{"sender":"Max","text":"昨天的消息"},"mentions_me":false,
            "attachment":null,"at":1795519225}"#,
    );
    let inbound = inbound(&m, 1700, "Max", None, now()).unwrap();
    assert_eq!(inbound.chat.native_id, "user:小明");
    assert_eq!(inbound.sender.role, None);
    let quote = inbound.quote.unwrap();
    assert_eq!(quote.quote_id, None);
    assert_eq!(quote.text.as_deref(), Some("昨天的消息"));
}

#[test]
fn a_file_keeps_its_name_and_not_its_bytes() {
    let m = line(
        r#"{"seq":5,"chat":"测试群","group":true,"sender":"小明","mine":false,"kind":"file",
            "text":"文件\nreport.pdf","quote":null,"mentions_me":false,
            "attachment":{"name":"report.pdf","mime":"application/octet-stream","data":"JVBERi0="},
            "at":1795519231}"#,
    );
    let inbound = inbound(&m, 1700, "Max", None, now()).unwrap();
    let [InNode::Node(Node::Media { meta, .. })] = inbound.nodes.as_slice() else {
        panic!("not one medium: {:?}", inbound.nodes);
    };
    assert_eq!(meta.kind, MediaKind::File);
    assert_eq!(meta.name.as_deref(), Some("report.pdf"));
    assert_eq!(inbound.raw["attachment"]["data"], "");
}

#[test]
fn max_s_own_and_the_client_s_lines_are_not_inbound() {
    let mine = line(
        r#"{"seq":1,"chat":"测试群","group":true,"sender":"Max","mine":true,"kind":"text",
            "text":"好","quote":null,"mentions_me":false,"attachment":null,"at":1795519067}"#,
    );
    let system = line(
        r#"{"seq":2,"chat":"测试群","group":true,"sender":null,"mine":false,"kind":"system",
            "text":"小红加入了群聊","quote":null,"mentions_me":false,"attachment":null,"at":1795519068}"#,
    );
    assert!(inbound(&mine, 1700, "Max", None, now()).is_none());
    assert!(inbound(&system, 1700, "Max", None, now()).is_none());
}
