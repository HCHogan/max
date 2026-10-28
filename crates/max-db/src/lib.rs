//! Max's PostgreSQL schema: migrations, every sqlx query and the row types.
//!
//! Queries take a `&mut PgConnection`, so the caller decides what shares a
//! transaction: `&mut *tx` inside one, or a connection from the pool. A
//! query that needs several statements to agree opens its own (a
//! savepoint when the caller already has a transaction).

pub mod ledger;
pub mod platform;
pub mod turns;

#[cfg(test)]
mod testing;

pub use sqlx::{PgConnection, PgPool};

/// The migrations in `migrations/`, embedded.
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!();

/// A column holds a value this code doesn't know: the schema's checks and
/// the code disagree.
fn unknown(column: &str, value: &str) -> sqlx::Error {
    sqlx::Error::Decode(format!("unknown {column}: {value:?}").into())
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
                "identities",
                "llm_usage",
                "messages",
                "principals",
                "summaries",
                "turn_outcomes",
                "turn_resumes",
                "turn_snapshots",
                "turns",
            ]
        );
        Ok(())
    }
}
