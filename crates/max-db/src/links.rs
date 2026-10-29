//! Linking QQ accounts to old QQ numbers by their avatars: the accounts
//! left to check, the old numbers to check them against, and what came of
//! it. See "按头像接上" in docs/rust-rewrite.md.

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, IdentityId, PrincipalId};
use sqlx::PgConnection;

/// A QQ account that spoke in a conversation, isn't merged into anyone and
/// hasn't been checked.
#[derive(Clone, Debug)]
pub struct Account {
    pub identity: IdentityId,
    pub principal: PrincipalId,
    pub openid: String,
    /// The name it last spoke under there.
    pub name: String,
}

/// An old QQ number that spoke in the conversation: whom an account there
/// may be.
#[derive(Clone, Debug)]
pub struct Number {
    pub identity: IdentityId,
    /// Its person, after merges: what an account is linked to.
    pub principal: PrincipalId,
    pub number: String,
    pub name: String,
    /// Its avatar, shrunk, as last fetched.
    pub print: Option<Vec<u8>>,
    pub fetched_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Merged into the number's person.
    Linked,
    /// It shows QQ's default avatar, as everyone without one does.
    Default,
    /// No old number there shows its avatar.
    None,
    /// Two or more old numbers there show it.
    Ambiguous,
    /// Another account there shows the same number, or is linked to it.
    Taken,
    /// It shows an owner's or Max's number, which nothing is linked to.
    Barred,
}

impl Outcome {
    fn as_str(self) -> &'static str {
        match self {
            Self::Linked => "linked",
            Self::Default => "default",
            Self::None => "none",
            Self::Ambiguous => "ambiguous",
            Self::Taken => "taken",
            Self::Barred => "barred",
        }
    }
}

/// The groups that go on from an old one: they have a QQ endpoint and an
/// old QQ one.
pub async fn conversations(conn: &mut PgConnection) -> sqlx::Result<Vec<ConversationId>> {
    let ids = sqlx::query_scalar!(
        "select c.id from conversations c
         where c.kind = 'group'
           and exists (select 1 from endpoints e where e.conversation_id = c.id and e.platform = 'qq')
           and exists (
               select 1 from endpoints e where e.conversation_id = c.id and e.platform = 'qq_legacy'
           )
         order by c.id"
    )
    .fetch_all(conn)
    .await?;
    Ok(ids.into_iter().map(ConversationId).collect())
}

/// Whether `conversation` goes on from an old group.
pub async fn goes_on(conn: &mut PgConnection, conversation: ConversationId) -> sqlx::Result<bool> {
    let found = sqlx::query_scalar!(
        r#"select exists (
               select 1 from endpoints where conversation_id = $1 and platform = 'qq_legacy'
           ) as "found!""#,
        conversation.0
    )
    .fetch_one(conn)
    .await?;
    Ok(found)
}

/// The QQ accounts that spoke in `conversation`, aren't merged into anyone
/// and haven't been checked.
pub async fn unchecked(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<Vec<Account>> {
    let rows = sqlx::query!(
        "select distinct on (i.id) i.id, i.principal_id, i.native_user_id, m.sender_name
         from messages m
         join identities i on i.id = m.sender_identity_id
         join principals p on p.id = i.principal_id
         where m.conversation_id = $1 and i.platform = 'qq' and p.merged_into is null
           and not exists (select 1 from avatar_checks c where c.identity_id = i.id)
         order by i.id, m.id desc",
        conversation.0
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Account {
            identity: IdentityId(row.id),
            principal: PrincipalId(row.principal_id),
            openid: row.native_user_id,
            name: row.sender_name,
        })
        .collect())
}

/// The old QQ numbers that spoke in `conversation`, with their avatars as
/// last fetched.
pub async fn numbers(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<Vec<Number>> {
    let rows = sqlx::query!(
        r#"select distinct on (i.id) i.id, coalesce(p.merged_into, p.id) as "principal!",
               i.native_user_id, m.sender_name, a.print as "print?", a.fetched_at as "fetched_at?"
           from messages m
           join identities i on i.id = m.sender_identity_id
           join principals p on p.id = i.principal_id
           left join legacy_avatars a on a.identity_id = i.id
           where m.conversation_id = $1 and i.platform = 'qq_legacy'
           order by i.id, m.id desc"#,
        conversation.0
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Number {
            identity: IdentityId(row.id),
            principal: PrincipalId(row.principal),
            number: row.native_user_id,
            name: row.sender_name,
            print: row.print,
            fetched_at: row.fetched_at,
        })
        .collect())
}

pub async fn save_print(
    conn: &mut PgConnection,
    number: IdentityId,
    print: &[u8],
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into legacy_avatars (identity_id, print, fetched_at) values ($1, $2, $3)
         on conflict (identity_id) do update set print = excluded.print, fetched_at = excluded.fetched_at",
        number.0,
        print,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// Whether an account other than `except` that spoke in `conversation` is
/// merged into `person`.
pub async fn linked_here(
    conn: &mut PgConnection,
    conversation: ConversationId,
    person: PrincipalId,
    except: IdentityId,
) -> sqlx::Result<bool> {
    let found = sqlx::query_scalar!(
        r#"select exists (
               select 1 from identities i join principals p on p.id = i.principal_id
               where p.merged_into = $2 and i.id <> $3
                 and exists (
                     select 1 from messages m
                     where m.conversation_id = $1 and m.sender_identity_id = i.id
                 )
           ) as "found!""#,
        conversation.0,
        person.0,
        except.0
    )
    .fetch_one(conn)
    .await?;
    Ok(found)
}

/// Records what came of `account`; linked, it is merged into `into` too,
/// in one transaction. `into` must not be merged itself.
pub async fn record(
    conn: &mut PgConnection,
    account: &Account,
    outcome: Outcome,
    number: Option<(IdentityId, PrincipalId)>,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = sqlx::Connection::begin(conn).await?;
    if let (Outcome::Linked, Some((_, into))) = (outcome, number) {
        sqlx::query!(
            "update principals set merged_into = $2 where id = $1 and merged_into is null",
            account.principal.0,
            into.0
        )
        .execute(&mut *tx)
        .await?;
    }
    sqlx::query!(
        "insert into avatar_checks (identity_id, outcome, number_id, checked_at)
         values ($1, $2, $3, $4)",
        account.identity.0,
        outcome.as_str(),
        number.map(|(identity, _)| identity.0),
        at
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await
}

/// Every account checked, whatever came of it.
pub async fn checked(conn: &mut PgConnection) -> sqlx::Result<Vec<IdentityId>> {
    let ids = sqlx::query_scalar!("select identity_id from avatar_checks")
        .fetch_all(conn)
        .await?;
    Ok(ids.into_iter().map(IdentityId).collect())
}
