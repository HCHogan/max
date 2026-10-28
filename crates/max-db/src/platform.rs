//! Conversations, endpoints, people and their accounts, and settings.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, EndpointId, IdentityId, MessageId, PrincipalId};
use max_core::message::{Platform, Role};
use sqlx::{Connection, PgConnection};

use crate::unknown;

pub(crate) fn platform_name(platform: Platform) -> &'static str {
    match platform {
        Platform::Qq => "qq",
        Platform::QqLegacy => "qq_legacy",
    }
}

pub(crate) fn role(name: Option<String>) -> sqlx::Result<Option<Role>> {
    name.map(|name| match name.as_str() {
        "owner" => Ok(Role::Owner),
        "admin" => Ok(Role::Admin),
        "member" => Ok(Role::Member),
        _ => Err(unknown("role", &name)),
    })
    .transpose()
}

/// A platform account and the person behind it, after merges.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Account {
    pub identity: IdentityId,
    pub principal: PrincipalId,
}

/// The account, created with a person of its own the first time it shows
/// up. Known accounts are found without a lock, so ingesting in different
/// conversations doesn't wait; a new one is created under an advisory lock
/// on the account, held to the end of the caller's transaction, so two
/// conversations seeing the same newcomer create one person.
pub async fn account(
    conn: &mut PgConnection,
    platform: Platform,
    native_user_id: &str,
    name: &str,
) -> sqlx::Result<Account> {
    let platform = platform_name(platform);
    if let Some(account) = find_account(conn, platform, native_user_id).await? {
        return Ok(account);
    }
    let mut tx = conn.begin().await?;
    sqlx::query!(
        "select pg_advisory_xact_lock(hashtextextended('account:' || $1 || ':' || $2, 0))",
        platform,
        native_user_id
    )
    .execute(&mut *tx)
    .await?;
    if let Some(account) = find_account(&mut tx, platform, native_user_id).await? {
        return Ok(account);
    }
    let row = sqlx::query!(
        r#"
        with principal as (
            insert into principals (display_name) values ($3) returning id
        )
        insert into identities (principal_id, platform, native_user_id)
        select id, $1, $2 from principal
        returning id, principal_id
        "#,
        platform,
        native_user_id,
        name
    )
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Account {
        identity: IdentityId(row.id),
        principal: PrincipalId(row.principal_id),
    })
}

async fn find_account(
    conn: &mut PgConnection,
    platform: &str,
    native_user_id: &str,
) -> sqlx::Result<Option<Account>> {
    let row = sqlx::query!(
        r#"
        select i.id, coalesce(p.merged_into, p.id) as "principal!"
        from identities i join principals p on p.id = i.principal_id
        where i.platform = $1 and i.native_user_id = $2
        "#,
        platform,
        native_user_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map(|row| Account {
        identity: IdentityId(row.id),
        principal: PrincipalId(row.principal),
    }))
}

/// The person behind each account, after merges, for rendering.
pub async fn principals(
    conn: &mut PgConnection,
    identities: &[IdentityId],
) -> sqlx::Result<BTreeMap<IdentityId, PrincipalId>> {
    let ids: Vec<i64> = identities.iter().map(|identity| identity.0).collect();
    let rows = sqlx::query!(
        r#"
        select i.id, coalesce(p.merged_into, p.id) as "principal!"
        from identities i join principals p on p.id = i.principal_id
        where i.id = any($1)
        "#,
        &ids
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| (IdentityId(row.id), PrincipalId(row.principal)))
        .collect())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConversationKind {
    Group,
    Direct,
}

fn kind_name(kind: ConversationKind) -> &'static str {
    match kind {
        ConversationKind::Group => "group",
        ConversationKind::Direct => "direct",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Endpoint {
    pub id: EndpointId,
    pub conversation: ConversationId,
}

/// The endpoint for a platform's group or chat as served by `me`, created
/// with a conversation of its own the first time.
pub async fn endpoint(
    conn: &mut PgConnection,
    platform: Platform,
    native_id: &str,
    me: IdentityId,
    kind: ConversationKind,
    title: Option<&str>,
) -> sqlx::Result<Endpoint> {
    let platform = platform_name(platform);
    let mut tx = conn.begin().await?;
    sqlx::query!(
        "select pg_advisory_xact_lock(hashtextextended('endpoint:' || $1 || ':' || $2 || ':' || $3, 0))",
        platform,
        me.0.to_string(),
        native_id
    )
    .execute(&mut *tx)
    .await?;
    let found = sqlx::query!(
        "select id, conversation_id from endpoints
         where platform = $1 and self_identity_id = $2 and native_id = $3",
        platform,
        me.0,
        native_id
    )
    .fetch_optional(&mut *tx)
    .await?;
    let (id, conversation) = match found {
        Some(row) => (row.id, row.conversation_id),
        None => {
            let kind = kind_name(kind);
            let row = sqlx::query!(
                r#"
                with conversation as (
                    insert into conversations (kind, title) values ($4, $5) returning id
                )
                insert into endpoints (conversation_id, platform, native_id, self_identity_id)
                select id, $1, $2, $3 from conversation
                returning id, conversation_id
                "#,
                platform,
                native_id,
                me.0,
                kind,
                title
            )
            .fetch_one(&mut *tx)
            .await?;
            (row.id, row.conversation_id)
        }
    };
    tx.commit().await?;
    Ok(Endpoint {
        id: EndpointId(id),
        conversation: ConversationId(conversation),
    })
}

/// The endpoint for a platform's group or chat as served by `me`, if
/// there is one; unlike [`endpoint`], creates nothing.
pub async fn find_endpoint(
    conn: &mut PgConnection,
    platform: Platform,
    native_id: &str,
    me: IdentityId,
) -> sqlx::Result<Option<Endpoint>> {
    let row = sqlx::query!(
        "select id, conversation_id from endpoints
         where platform = $1 and self_identity_id = $2 and native_id = $3",
        platform_name(platform),
        me.0,
        native_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map(|row| Endpoint {
        id: EndpointId(row.id),
        conversation: ConversationId(row.conversation_id),
    }))
}

/// The conversation an endpoint of this platform belongs to, whoever
/// serves it: how `!bind` finds a group's history from before.
pub async fn conversation_of(
    conn: &mut PgConnection,
    platform: Platform,
    native_id: &str,
) -> sqlx::Result<Option<ConversationId>> {
    let id = sqlx::query_scalar!(
        "select conversation_id from endpoints where platform = $1 and native_id = $2 limit 1",
        platform_name(platform),
        native_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(id.map(ConversationId))
}

/// The conversation's endpoint on a platform, by its native id, if it has
/// one. A conversation has one endpoint an adapter serves, or two actors
/// would write its timeline.
pub async fn endpoint_on(
    conn: &mut PgConnection,
    conversation: ConversationId,
    platform: Platform,
) -> sqlx::Result<Option<String>> {
    sqlx::query_scalar!(
        "select native_id from endpoints where conversation_id = $1 and platform = $2 limit 1",
        conversation.0,
        platform_name(platform)
    )
    .fetch_optional(conn)
    .await
}

/// A new endpoint for an existing conversation, or for a new one when
/// `conversation` is None.
pub async fn attach(
    conn: &mut PgConnection,
    conversation: Option<ConversationId>,
    platform: Platform,
    native_id: &str,
    me: IdentityId,
    kind: ConversationKind,
) -> sqlx::Result<Endpoint> {
    let mut tx = conn.begin().await?;
    let conversation = match conversation {
        Some(conversation) => conversation.0,
        None => {
            sqlx::query_scalar!(
                "insert into conversations (kind) values ($1) returning id",
                kind_name(kind)
            )
            .fetch_one(&mut *tx)
            .await?
        }
    };
    let id = sqlx::query_scalar!(
        "insert into endpoints (conversation_id, platform, native_id, self_identity_id)
         values ($1, $2, $3, $4) returning id",
        conversation,
        platform_name(platform),
        native_id,
        me.0
    )
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Endpoint {
        id: EndpointId(id),
        conversation: ConversationId(conversation),
    })
}

pub async fn conversation_kind(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<ConversationKind> {
    let kind = sqlx::query_scalar!(
        "select kind from conversations where id = $1",
        conversation.0
    )
    .fetch_one(conn)
    .await?;
    match kind.as_str() {
        "group" => Ok(ConversationKind::Group),
        "direct" => Ok(ConversationKind::Direct),
        other => Err(unknown("conversation kind", other)),
    }
}

/// Records that `merged` is the same person as `into`: readers follow
/// `merged_into` once, so `into` must not be merged itself.
pub async fn merge(
    conn: &mut PgConnection,
    merged: PrincipalId,
    into: PrincipalId,
) -> sqlx::Result<()> {
    if merged == into {
        return Ok(());
    }
    sqlx::query!(
        "update principals set merged_into = $2 where id = $1 and merged_into is null",
        merged.0,
        into.0
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// An account's id on its platform: whom a mention of it reaches.
pub async fn native_user_id(
    conn: &mut PgConnection,
    identity: IdentityId,
) -> sqlx::Result<Option<String>> {
    sqlx::query_scalar!(
        "select native_user_id from identities where id = $1",
        identity.0
    )
    .fetch_optional(conn)
    .await
}

/// The account a person spoke from most recently in an endpoint: whom to
/// mention there.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Speaker {
    pub identity: IdentityId,
    pub native_user_id: String,
    pub name: String,
}

pub async fn speaker(
    conn: &mut PgConnection,
    endpoint: EndpointId,
    principal: PrincipalId,
) -> sqlx::Result<Option<Speaker>> {
    let row = sqlx::query!(
        r#"
        select i.id, i.native_user_id, m.sender_name
        from identities i
        join principals p on p.id = i.principal_id
        cross join lateral (
            select id, sender_name from messages
            where endpoint_id = $1 and sender_identity_id = i.id
            order by id desc limit 1
        ) m
        where coalesce(p.merged_into, p.id) = $2
        order by m.id desc limit 1
        "#,
        endpoint.0,
        principal.0
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map(|row| Speaker {
        identity: IdentityId(row.id),
        native_user_id: row.native_user_id,
        name: row.sender_name,
    }))
}

/// A roster line's facts: the name and role from the person's latest
/// message in the endpoint, or the name they were first seen with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Known {
    pub principal: PrincipalId,
    pub name: String,
    pub role: Option<Role>,
}

pub async fn roster(
    conn: &mut PgConnection,
    endpoint: EndpointId,
    people: &[PrincipalId],
) -> sqlx::Result<Vec<Known>> {
    let ids: Vec<i64> = people.iter().map(|principal| principal.0).collect();
    let rows = sqlx::query!(
        r#"
        select p.id, coalesce(latest.sender_name, p.display_name) as "name!",
               latest.sender_role as "role?"
        from principals p
        left join lateral (
            select m.sender_name, m.sender_role
            from identities i
            join principals owner on owner.id = i.principal_id
            cross join lateral (
                select id, sender_name, sender_role from messages
                where endpoint_id = $1 and sender_identity_id = i.id
                order by id desc limit 1
            ) m
            where coalesce(owner.merged_into, owner.id) = p.id
            order by m.id desc limit 1
        ) latest on true
        where p.id = any($2)
        order by p.id
        "#,
        endpoint.0,
        &ids
    )
    .fetch_all(conn)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(Known {
                principal: PrincipalId(row.id),
                name: row.name,
                role: role(row.role)?,
            })
        })
        .collect()
}

/// A platform connection's session, saved as Max last stopped: its id and
/// the last sequence number it saw.
pub async fn gateway_session(
    conn: &mut PgConnection,
    platform: Platform,
) -> sqlx::Result<Option<(String, u64)>> {
    let row = sqlx::query!(
        "select session_id, seq from gateway_sessions where platform = $1",
        platform_name(platform)
    )
    .fetch_optional(conn)
    .await?;
    row.map(|row| {
        let seq = u64::try_from(row.seq).map_err(|_| unknown("seq", &row.seq.to_string()))?;
        Ok((row.session_id, seq))
    })
    .transpose()
}

pub async fn save_gateway_session(
    conn: &mut PgConnection,
    platform: Platform,
    session_id: &str,
    seq: u64,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let seq = i64::try_from(seq).map_err(|_| unknown("seq", &seq.to_string()))?;
    sqlx::query!(
        r#"
        insert into gateway_sessions (platform, session_id, seq, saved_at)
        values ($1, $2, $3, $4)
        on conflict (platform) do update set
            session_id = excluded.session_id, seq = excluded.seq, saved_at = excluded.saved_at
        "#,
        platform_name(platform),
        session_id,
        seq,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// What the conversation's commands set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub persona: Option<String>,
    pub proactive: bool,
    pub cleared_upto: Option<MessageId>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            model: None,
            effort: None,
            persona: None,
            proactive: true,
            cleared_upto: None,
        }
    }
}

pub async fn settings(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<Settings> {
    let row = sqlx::query!(
        "select model, effort, persona, proactive, cleared_upto
         from conversation_settings where conversation_id = $1",
        conversation.0
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map_or_else(Settings::default, |row| Settings {
        model: row.model,
        effort: row.effort,
        persona: row.persona,
        proactive: row.proactive,
        cleared_upto: row.cleared_upto.map(MessageId),
    }))
}

pub async fn save_settings(
    conn: &mut PgConnection,
    conversation: ConversationId,
    settings: &Settings,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query!(
        r#"
        insert into conversation_settings
            (conversation_id, model, effort, persona, proactive, cleared_upto, updated_at)
        values ($1, $2, $3, $4, $5, $6, $7)
        on conflict (conversation_id) do update set
            model = excluded.model, effort = excluded.effort, persona = excluded.persona,
            proactive = excluded.proactive, cleared_upto = excluded.cleared_upto,
            updated_at = excluded.updated_at
        "#,
        conversation.0,
        settings.model,
        settings.effort,
        settings.persona,
        settings.proactive,
        settings.cleared_upto.map(|id| id.0),
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests;
