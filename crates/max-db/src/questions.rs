//! What Max in one conversation asked Max in another that has no answer
//! yet: kept from when Max there is shown a question until it answers,
//! so that the answer may come in any later turn. One asked over
//! [`ASK_DAYS`] days before `now` is neither shown nor answered. See
//! "Asking another conversation" in docs/design/jobs.md.

use chrono::{DateTime, Duration, Utc};
use max_core::ids::ConversationId;
use max_core::limits::ASK_DAYS;
use sqlx::PgConnection;

use crate::links::Peer;

/// A question that waits for its answer, as one of its two conversations
/// is shown it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Waiting {
    /// Its number, `ask#5`.
    pub number: i64,
    /// The other conversation: who asked, or who was asked.
    pub peer: Peer,
    pub question: String,
    pub asked_at: DateTime<Utc>,
}

/// A question taken out, on its way back to who asked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Taken {
    pub asker: ConversationId,
    pub question: String,
}

/// After which a question still waits at `now`.
fn since(now: DateTime<Utc>) -> DateTime<Utc> {
    now - Duration::days(i64::from(ASK_DAYS))
}

/// The number the next question gets, before there is a row of it.
pub async fn number(conn: &mut PgConnection) -> sqlx::Result<i64> {
    sqlx::query_scalar!(r#"select nextval(pg_get_serial_sequence('questions', 'id')) as "number!""#)
        .fetch_one(conn)
        .await
}

/// Keeps question `number`, which Max in `asker` put to Max in `asked`
/// at `at`, and drops every question that waits no longer.
pub async fn keep(
    conn: &mut PgConnection,
    number: i64,
    asker: ConversationId,
    asked: ConversationId,
    question: &str,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query!("delete from questions where asked_at <= $1", since(at))
        .execute(&mut *conn)
        .await?;
    sqlx::query!(
        "insert into questions (id, asker_id, asked_id, question, asked_at)
         values ($1, $2, $3, $4, $5)",
        number,
        asker.get(),
        asked.get(),
        question,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// How many questions of `asker`'s wait in `asked`.
pub async fn count(
    conn: &mut PgConnection,
    asker: ConversationId,
    asked: ConversationId,
    now: DateTime<Utc>,
) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"select count(*) as "count!" from questions
           where asker_id = $1 and asked_id = $2 and asked_at > $3"#,
        asker.get(),
        asked.get(),
        since(now)
    )
    .fetch_one(conn)
    .await
}

/// The questions that wait in `conversation`, for Max there to answer,
/// and those Max there asked and has no answer to: each oldest first,
/// with the other conversation.
pub async fn waiting(
    conn: &mut PgConnection,
    conversation: ConversationId,
    now: DateTime<Utc>,
) -> sqlx::Result<(Vec<Waiting>, Vec<Waiting>)> {
    let rows = sqlx::query!(
        "select q.id, q.question, q.asked_at, q.asked_id, c.id as peer, c.title
         from questions q join conversations c
           on c.id = case when q.asked_id = $1 then q.asker_id else q.asked_id end
         where (q.asked_id = $1 or q.asker_id = $1) and q.asked_at > $2
         order by q.id",
        conversation.get(),
        since(now)
    )
    .fetch_all(conn)
    .await?;
    let (mut to_answer, mut unanswered) = (Vec::new(), Vec::new());
    for row in rows {
        let list = if row.asked_id == conversation.get() {
            &mut to_answer
        } else {
            &mut unanswered
        };
        list.push(Waiting {
            number: row.id,
            peer: Peer {
                conversation: ConversationId::new(row.peer),
                title: row.title,
            },
            question: row.question,
            asked_at: row.asked_at,
        });
    }
    Ok((to_answer, unanswered))
}

/// Takes question `number` out, if it waits in `asked`: it is answered
/// once.
pub async fn take(
    conn: &mut PgConnection,
    number: i64,
    asked: ConversationId,
    now: DateTime<Utc>,
) -> sqlx::Result<Option<Taken>> {
    let taken = sqlx::query!(
        "delete from questions where id = $1 and asked_id = $2 and asked_at > $3
         returning asker_id, question",
        number,
        asked.get(),
        since(now)
    )
    .fetch_optional(conn)
    .await?;
    Ok(taken.map(|row| Taken {
        asker: ConversationId::new(row.asker_id),
        question: row.question,
    }))
}

/// Takes out every question that waits in `asked`, oldest first: Max
/// there won't answer them.
pub async fn take_all(
    conn: &mut PgConnection,
    asked: ConversationId,
    now: DateTime<Utc>,
) -> sqlx::Result<Vec<Taken>> {
    let mut taken = sqlx::query!(
        "delete from questions where asked_id = $1 returning id, asker_id, question, asked_at",
        asked.get()
    )
    .fetch_all(conn)
    .await?;
    taken.sort_by_key(|row| row.id);
    Ok(taken
        .into_iter()
        .filter(|row| row.asked_at > since(now))
        .map(|row| Taken {
            asker: ConversationId::new(row.asker_id),
            question: row.question,
        })
        .collect())
}

#[cfg(test)]
mod tests;
