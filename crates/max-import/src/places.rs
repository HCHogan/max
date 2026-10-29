//! Conversations with a QQ endpoint, under their old ids, and those
//! endpoints as `qq_legacy` ones served by Max's old account. WeChat,
//! iMessage and Matrix endpoints stay behind.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use color_eyre::eyre::{Result, ensure};
use max_db::PgConnection;
use tracing::info;

use crate::people::People;

pub struct Places {
    /// Each old QQ endpoint's id in the new database. Two private chats had
    /// two endpoints for one number, `user:N` and `-N`; they are one now.
    pub endpoint: HashMap<i64, i64>,
    /// The group conversations.
    pub groups: HashSet<i64>,
}

pub async fn import(
    old: &mut PgConnection,
    new: &mut PgConnection,
    people: &People,
) -> Result<Places> {
    let conversations: Vec<(i64, String, Option<String>, DateTime<Utc>)> = sqlx::query_as(
        "select c.conversation_id, c.conversation_kind, c.title, c.created_at
         from conversations c
         where exists (
             select 1 from conversation_endpoints ce join platform_accounts pa using (platform_account_id)
             where ce.conversation_id = c.conversation_id and pa.platform = 'qq'
         )
         order by c.conversation_id",
    )
    .fetch_all(&mut *old)
    .await?;
    sqlx::query(
        "insert into conversations (id, kind, title, created_at)
         select * from unnest($1::bigint[], $2::text[], $3::text[], $4::timestamptz[])",
    )
    .bind(conversations.iter().map(|row| row.0).collect::<Vec<_>>())
    .bind(
        conversations
            .iter()
            .map(|row| row.1.clone())
            .collect::<Vec<_>>(),
    )
    .bind(
        conversations
            .iter()
            .map(|row| row.2.clone())
            .collect::<Vec<_>>(),
    )
    .bind(conversations.iter().map(|row| row.3).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    let groups: HashSet<i64> = conversations
        .iter()
        .filter(|row| row.1 == "group")
        .map(|row| row.0)
        .collect();

    let endpoints: Vec<(i64, i64, String, DateTime<Utc>)> = sqlx::query_as(
        "select ce.endpoint_id, ce.conversation_id, ce.native_conversation_id, ce.created_at
         from conversation_endpoints ce join platform_accounts pa using (platform_account_id)
         where pa.platform = 'qq'
         order by ce.endpoint_id",
    )
    .fetch_all(&mut *old)
    .await?;
    let mut places = Places {
        endpoint: HashMap::new(),
        groups,
    };
    let mut kept = HashMap::new();
    let mut rows = Vec::new();
    for (id, conversation, native, created_at) in endpoints {
        let native = native_id(places.groups.contains(&conversation), &native)?;
        let same = *kept.entry((conversation, native.clone())).or_insert(id);
        places.endpoint.insert(id, same);
        if same == id {
            rows.push((id, conversation, native, created_at));
        }
    }
    sqlx::query(
        "insert into endpoints (id, conversation_id, platform, native_id, self_identity_id, created_at)
         select id, conversation_id, 'qq_legacy', native_id, $5, created_at
         from unnest($1::bigint[], $2::bigint[], $3::text[], $4::timestamptz[])
             as t (id, conversation_id, native_id, created_at)",
    )
    .bind(rows.iter().map(|row| row.0).collect::<Vec<_>>())
    .bind(rows.iter().map(|row| row.1).collect::<Vec<_>>())
    .bind(rows.iter().map(|row| row.2.clone()).collect::<Vec<_>>())
    .bind(rows.iter().map(|row| row.3).collect::<Vec<_>>())
    .bind(people.max.1)
    .execute(&mut *new)
    .await?;
    info!(
        conversations = conversations.len(),
        endpoints = rows.len(),
        "conversations"
    );
    Ok(places)
}

/// `group:<群号>` or `private:<QQ号>`: what `/bind` looks up. The old ids
/// are `<群号>`, and `user:<QQ号>` or `-<QQ号>`.
fn native_id(group: bool, old: &str) -> Result<String> {
    let (kind, number) = if group {
        ("group", old)
    } else {
        let number = old
            .strip_prefix("user:")
            .or_else(|| old.strip_prefix('-'))
            .unwrap_or(old);
        ("private", number)
    };
    ensure!(
        !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()),
        "an endpoint that isn't a number: {old:?}"
    );
    Ok(format!("{kind}:{number}"))
}
