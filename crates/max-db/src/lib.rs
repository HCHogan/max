//! Max's PostgreSQL schema: migrations, every sqlx query and the row types.

pub use sqlx::{PgConnection, PgPool};

/// The migrations in `migrations/`, embedded.
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!();

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
