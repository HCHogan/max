//! A QQ group and people in it, for the actor's tests.

use chrono::{DateTime, FixedOffset, TimeZone, Utc};
use max_core::message::{Node, Platform, Role};
use max_db::platform::{self, ConversationKind};
use serde_json::json;
use sqlx::PgConnection;

use super::Place;
use crate::inbound::{Chat, InNode, Inbound, Person};

pub fn offset() -> FixedOffset {
    FixedOffset::east_opt(8 * 3600).unwrap()
}

pub fn at(minute: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 29, 4, minute, 0).unwrap()
}

/// A QQ group with Max in it.
pub async fn group(conn: &mut PgConnection) -> Place {
    let me = platform::account(conn, Platform::Qq, "BOT", "maxx")
        .await
        .unwrap();
    let native_id = "group:GROUP1";
    let kind = ConversationKind::Group;
    let endpoint = platform::endpoint(conn, Platform::Qq, native_id, me.identity, kind, None)
        .await
        .unwrap();
    Place {
        conversation: endpoint.conversation,
        kind,
        endpoint: endpoint.id,
        platform: Platform::Qq,
        native_id: native_id.into(),
        me,
        my_name: "maxx".into(),
    }
}

/// 小明 says something in the group.
pub fn from_xiaoming(n: u32, nodes: Vec<InNode>) -> Inbound {
    Inbound {
        platform: Platform::Qq,
        chat: Chat {
            native_id: "group:GROUP1".into(),
            kind: ConversationKind::Group,
        },
        native_id: format!("MSG{n}"),
        quote_id: Some(format!("IDX{n}")),
        sender: Person {
            native_user_id: "XIAOMING".into(),
            name: "小明".into(),
            role: Some(Role::Member),
        },
        at: at(n),
        quote: None,
        nodes,
        raw: json!({ "id": format!("MSG{n}") }),
    }
}

pub fn text(text: &str) -> InNode {
    InNode::Node(Node::Text { text: text.into() })
}

/// 小红 says something in the group.
pub fn from_xiaohong(n: u32, nodes: Vec<InNode>) -> Inbound {
    let mut inbound = from_xiaoming(n, nodes);
    inbound.sender = Person {
        native_user_id: "XIAOHONG".into(),
        name: "小红".into(),
        role: Some(Role::Admin),
    };
    inbound
}
