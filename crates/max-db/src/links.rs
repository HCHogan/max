//! Which conversation's Max may enter which other's VM: the edges `/link`
//! makes. See "Entering another conversation's VM" in docs/design/vm.md.

use std::fmt::{self, Write};

use chrono::{DateTime, Utc};
use max_core::ids::ConversationId;
use sqlx::PgConnection;

/// A conversation as another one names it: `c#N`, with its title if it
/// has one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub conversation: ConversationId,
    /// Its title, a group's name as its platform has it.
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
#[must_use]
pub fn named(handle: &str) -> Option<ConversationId> {
    let handle = handle.trim();
    let number = handle
        .strip_prefix("c#")
        .or_else(|| handle.strip_prefix("C#"))
        .unwrap_or(handle);
    let all_digits = !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit());
    let id = number.parse().ok().filter(|_| all_digits)?;
    Some(ConversationId::new(id))
}

/// A conversation as another one names it, if there is such a
/// conversation.
pub async fn peer(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<Option<Peer>> {
    let found = sqlx::query!(
        "select title from conversations where id = $1",
        conversation.get()
    )
    .fetch_optional(conn)
    .await?;
    Ok(found.map(|row| Peer {
        conversation,
        title: row.title,
    }))
}

/// Lets Max in `from` enter the VM of `to`, and not the other way: false
/// if it already could. The two must differ.
pub async fn link(
    conn: &mut PgConnection,
    from: ConversationId,
    to: ConversationId,
    at: DateTime<Utc>,
) -> sqlx::Result<bool> {
    let made = sqlx::query!(
        "insert into links (from_id, to_id, made_at) values ($1, $2, $3)
         on conflict do nothing",
        from.get(),
        to.get(),
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
         where (from_id = $1 and to_id = $2) or (from_id = $2 and to_id = $1)",
        one.get(),
        other.get()
    )
    .execute(conn)
    .await?;
    Ok(removed.rows_affected())
}

/// Whether Max in `from` may enter the VM of `to`.
pub async fn linked(
    conn: &mut PgConnection,
    from: ConversationId,
    to: ConversationId,
) -> sqlx::Result<bool> {
    sqlx::query_scalar!(
        r#"select exists (select 1 from links where from_id = $1 and to_id = $2) as "linked!""#,
        from.get(),
        to.get()
    )
    .fetch_one(conn)
    .await
}

/// The conversations whose VMs Max in `from` may enter, by id.
pub async fn enterable(conn: &mut PgConnection, from: ConversationId) -> sqlx::Result<Vec<Peer>> {
    let rows = sqlx::query!(
        "select c.id, c.title from links l join conversations c on c.id = l.to_id
         where l.from_id = $1 order by c.id",
        from.get()
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Peer {
            conversation: ConversationId::new(row.id),
            title: row.title,
        })
        .collect())
}

/// The conversations whose Max may enter the VM of `to`, by id.
pub async fn enterers(conn: &mut PgConnection, to: ConversationId) -> sqlx::Result<Vec<Peer>> {
    let rows = sqlx::query!(
        "select c.id, c.title from links l join conversations c on c.id = l.from_id
         where l.to_id = $1 order by c.id",
        to.get()
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Peer {
            conversation: ConversationId::new(row.id),
            title: row.title,
        })
        .collect())
}

#[cfg(test)]
mod tests;
