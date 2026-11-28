//! Max's PostgreSQL schema: migrations, every sqlx query and the row types.
//!
//! Queries take a `&mut PgConnection`, so the caller decides what shares a
//! transaction: `&mut *tx` inside one, or a connection from the pool. A
//! query that needs several statements to agree opens its own (a
//! savepoint when the caller already has a transaction).
//!
//! Every function fails as its queries do, with sqlx's error: the
//! database's own, or a decode error where a column holds what this code
//! doesn't know. That goes for all of them, and none says it again.

#![expect(
    clippy::missing_errors_doc,
    reason = "every function fails as its queries do, which the crate's documentation says once"
)]

pub mod captions;
pub mod ledger;
pub mod links;
pub mod media;
pub mod platform;
pub mod recall;
pub mod stickers;
pub mod tool_calls;
pub mod turns;
pub mod usage;

#[cfg(test)]
mod testing;

use std::borrow::Cow;
use std::str::FromStr;

use serde_json::Value;
pub use sqlx::{PgConnection, PgPool};

/// The migrations in `migrations/`, embedded.
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!();

/// A column holds a value this code doesn't know: the schema's checks and
/// the code disagree.
fn unknown(column: &str, value: &str) -> sqlx::Error {
    sqlx::Error::Decode(format!("unknown {column}: {value:?}").into())
}

/// What a column names: one of an enum's `max_core::names!`, or a file
/// in the content store.
fn named<T>(name: &str) -> sqlx::Result<T>
where
    T: FromStr<Err: std::error::Error + Send + Sync + 'static>,
{
    name.parse()
        .map_err(|error: T::Err| sqlx::Error::Decode(error.into()))
}

/// What stands for U+0000, which Postgres's text and jsonb can't hold. A
/// tool's output, the model's text or a platform's payload can have one,
/// and the row would fail to write.
const NUL: &str = "\u{FFFD}";

/// `text` as a text column can hold it.
fn text(text: &str) -> Cow<'_, str> {
    if text.contains('\0') {
        Cow::Owned(text.replace('\0', NUL))
    } else {
        Cow::Borrowed(text)
    }
}

/// A value serialized for a jsonb column, as one can hold it.
fn json(value: serde_json::Result<Value>) -> sqlx::Result<Value> {
    let mut value = value.map_err(|error| sqlx::Error::Encode(error.into()))?;
    storable(&mut value);
    Ok(value)
}

fn storable(value: &mut Value) {
    let clean = |string: &mut String| {
        if let Cow::Owned(owned) = text(string) {
            *string = owned;
        }
    };
    match value {
        Value::String(string) => clean(string),
        Value::Array(items) => items.iter_mut().for_each(storable),
        Value::Object(fields) => {
            if fields.keys().any(|key| key.contains('\0')) {
                *fields = std::mem::take(fields)
                    .into_iter()
                    .map(|(mut key, value)| {
                        clean(&mut key);
                        (key, value)
                    })
                    .collect();
            }
            fields.values_mut().for_each(storable);
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

#[cfg(test)]
mod tests {

    use sqlx::PgPool;

    #[sqlx::test]
    async fn the_migrations_apply(pool: PgPool) -> sqlx::Result<()> {
        let tables: Vec<String> = sqlx::query_scalar(
            "select tablename::text from pg_tables where schemaname = 'public' order by 1",
        )
        .fetch_all(&pool)
        .await?;
        assert_eq!(
            tables,
            [
                "_sqlx_migrations",
                "conversation_settings",
                "conversations",
                "deliveries",
                "endpoints",
                "gateway_sessions",
                "identities",
                "links",
                "llm_usage",
                "media",
                "media_captions",
                "message_media",
                "messages",
                "principals",
                "summaries",
                "summary_runs",
                "tool_calls",
                "turn_outcomes",
                "turns",
            ]
        );
        Ok(())
    }
}
