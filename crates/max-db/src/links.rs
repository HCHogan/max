//! Which conversation's Max may ask which other's: the edges `/link`
//! makes. See "Asking another conversation" in docs/rust-rewrite.md.

use std::fmt::{self, Write};

use chrono::{DateTime, Utc};
use max_core::ids::ConversationId;
use sqlx::PgConnection;

/// A conversation as another one names it: `c#N`, with its title if it
/// has one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub conversation: ConversationId,
    pub title: Option<String>,
}

/// The most of a title a name shows.
const TITLE_CHARS: usize = 40;

/// On one line, whatever the title holds: a title is a QQ group's name
/// or a person's, which they choose, and the name goes into lines that
/// maxx says.
impl fmt::Display for Peer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "c#{}", self.conversation)?;
        let title = self.title.as_deref().unwrap_or_default().trim();
        if title.is_empty() {
            return Ok(());
        }
        f.write_char(' ')?;
        title
            .chars()
            .take(TITLE_CHARS)
            .map(|c| if c.is_control() { ' ' } else { c })
            .try_for_each(|c| f.write_char(c))
    }
}

/// The conversation a handle names: `c#7` as [`Peer`] shows it, or the
/// number alone.
pub fn named(handle: &str) -> Option<ConversationId> {
    let handle = handle.trim();
    let number = handle
        .strip_prefix("c#")
        .or_else(|| handle.strip_prefix("C#"))
        .unwrap_or(handle);
    let all_digits = !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit());
    let id = number.parse().ok().filter(|_| all_digits)?;
    Some(ConversationId(id))
}

/// A conversation as another one names it, if there is such a
/// conversation.
pub async fn peer(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<Option<Peer>> {
    let found = sqlx::query!(
        "select title from conversations where id = $1",
        conversation.0
    )
    .fetch_optional(conn)
    .await?;
    Ok(found.map(|row| Peer {
        conversation,
        title: row.title,
    }))
}

/// Lets Max in `asker` ask Max in `asked`, and not the other way: false
/// if it already could. The two must differ.
pub async fn link(
    conn: &mut PgConnection,
    asker: ConversationId,
    asked: ConversationId,
    at: DateTime<Utc>,
) -> sqlx::Result<bool> {
    let made = sqlx::query!(
        "insert into links (asker_id, asked_id, made_at) values ($1, $2, $3)
         on conflict do nothing",
        asker.0,
        asked.0,
        at
    )
    .execute(conn)
    .await?;
    Ok(made.rows_affected() > 0)
}

/// Removes the edges between two conversations, both ways: how many
/// there were.
pub async fn unlink(
    conn: &mut PgConnection,
    one: ConversationId,
    other: ConversationId,
) -> sqlx::Result<u64> {
    let removed = sqlx::query!(
        "delete from links
         where (asker_id = $1 and asked_id = $2) or (asker_id = $2 and asked_id = $1)",
        one.0,
        other.0
    )
    .execute(conn)
    .await?;
    Ok(removed.rows_affected())
}

/// Whether Max in `asker` may ask Max in `asked`.
pub async fn linked(
    conn: &mut PgConnection,
    asker: ConversationId,
    asked: ConversationId,
) -> sqlx::Result<bool> {
    sqlx::query_scalar!(
        r#"select exists (select 1 from links where asker_id = $1 and asked_id = $2) as "linked!""#,
        asker.0,
        asked.0
    )
    .fetch_one(conn)
    .await
}

/// The conversations Max in `asker` may ask, by id.
pub async fn asked(conn: &mut PgConnection, asker: ConversationId) -> sqlx::Result<Vec<Peer>> {
    let rows = sqlx::query!(
        "select c.id, c.title from links l join conversations c on c.id = l.asked_id
         where l.asker_id = $1 order by c.id",
        asker.0
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Peer {
            conversation: ConversationId(row.id),
            title: row.title,
        })
        .collect())
}

/// The conversations whose Max may ask Max in `asked`, by id.
pub async fn askers(conn: &mut PgConnection, asked: ConversationId) -> sqlx::Result<Vec<Peer>> {
    let rows = sqlx::query!(
        "select c.id, c.title from links l join conversations c on c.id = l.asker_id
         where l.asked_id = $1 order by c.id",
        asked.0
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Peer {
            conversation: ConversationId(row.id),
            title: row.title,
        })
        .collect())
}

#[cfg(test)]
mod tests;
