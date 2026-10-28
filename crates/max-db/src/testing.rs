//! Fixtures for the database tests: a QQ group with Max and 小明 in it.

use chrono::{DateTime, Utc};
use max_core::ids::MessageId;
use max_core::message::{Content, Node, Platform, Role, Sender};
use serde_json::json;
use sqlx::PgConnection;

use crate::ledger::{self, NewMessage};
use crate::platform::{self, Account, ConversationKind, Endpoint};

pub struct Group {
    pub endpoint: Endpoint,
    pub max: Account,
    pub xiaoming: Account,
}

pub async fn group(conn: &mut PgConnection, native_id: &str) -> sqlx::Result<Group> {
    let max = platform::account(conn, Platform::Qq, "20000", "Max").await?;
    let xiaoming = platform::account(conn, Platform::Qq, "10001", "小明").await?;
    let kind = ConversationKind::Group;
    let endpoint =
        platform::endpoint(conn, Platform::Qq, native_id, max.identity, kind, None).await?;
    Ok(Group {
        endpoint,
        max,
        xiaoming,
    })
}

/// Minutes into the test's day.
pub fn at(minute: i64) -> DateTime<Utc> {
    DateTime::from_timestamp(1_800_000_000 + minute * 60, 0).unwrap_or_default()
}

pub fn sender(account: Account, name: &str, role: Option<Role>) -> Sender {
    Sender {
        identity: account.identity,
        name: name.into(),
        role,
    }
}

pub fn said(text: &str) -> Content {
    Content::Message {
        reply_to: None,
        nodes: vec![Node::Text { text: text.into() }],
    }
}

/// Commits a row at `minute`. Someone else's comes with the platform id
/// `n<minute>`; Max's has none.
pub async fn commit(
    conn: &mut PgConnection,
    group: &Group,
    sender: &Sender,
    content: &Content,
    minute: i64,
) -> sqlx::Result<MessageId> {
    let native_id = format!("n{minute}");
    let mine = sender.identity == group.max.identity;
    ledger::insert(
        conn,
        &NewMessage {
            conversation: group.endpoint.conversation,
            endpoint: group.endpoint.id,
            sender,
            native_id: (!mine).then_some(native_id.as_str()),
            sent_at: at(minute),
            received_at: at(minute),
            command: false,
            content,
            raw: &json!({ "message_id": minute }),
            text: "",
            turn: None,
            segment: None,
        },
    )
    .await
}
