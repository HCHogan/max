//! Max's PostgreSQL schema: migrations, every sqlx query and the row types.
//!
//! Queries take a `&mut PgConnection`, so the caller decides what shares a
//! transaction: `&mut *tx` inside one, or a connection from the pool. A
//! query that needs several statements to agree opens its own (a
//! savepoint when the caller already has a transaction).

pub mod captions;
pub mod embeddings;
pub mod ledger;
pub mod links;
pub mod media;
pub mod platform;
pub mod recall;
pub mod turns;
pub mod usage;
pub mod vectors;

#[cfg(test)]
mod testing;

use std::str::FromStr;

use max_core::names::Unknown;
pub use sqlx::{PgConnection, PgPool};

/// The migrations in `migrations/`, embedded.
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!();

/// A column holds a value this code doesn't know: the schema's checks and
/// the code disagree.
fn unknown(column: &str, value: &str) -> sqlx::Error {
    sqlx::Error::Decode(format!("unknown {column}: {value:?}").into())
}

/// What a column names, by `max_core::names!`.
fn named<T: FromStr<Err = Unknown>>(name: &str) -> sqlx::Result<T> {
    name.parse()
        .map_err(|unknown: Unknown| sqlx::Error::Decode(unknown.into()))
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
                "caption_embeddings",
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
                "message_embeddings",
                "message_media",
                "messages",
                "principals",
                "summaries",
                "summary_embeddings",
                "summary_runs",
                "turn_outcomes",
                "turns",
            ]
        );
        Ok(())
    }
}
