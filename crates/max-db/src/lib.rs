//! Max's PostgreSQL schema: migrations, every sqlx query and the row types.
//!
//! Queries take a `&mut PgConnection`, so the caller decides what shares a
//! transaction: `&mut *tx` inside one, or a connection from the pool. A
//! query that needs several statements to agree opens its own (a
//! savepoint when the caller already has a transaction).

pub mod captions;
pub mod embeddings;
pub mod ledger;
pub mod media;
pub mod platform;
pub mod recall;
pub mod turns;
pub mod usage;
pub mod vectors;

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
    use std::path::PathBuf;

    use max_core::ids::MessageId;
    use max_core::message::{Content, MentionTarget, Node, Platform};
    use sqlx::postgres::PgConnectOptions;
    use sqlx::{Connection, PgConnection, PgPool};

    use crate::{platform, testing};

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

    /// 0024 undoes the avatar linker's merges, and only those: the rows
    /// that mention an account it linked name the account again.
    #[sqlx::test(migrations = false)]
    async fn the_avatar_links_are_undone(pool: PgPool) -> sqlx::Result<()> {
        let mut conn = pool.acquire().await?;
        let migration = |version| crate::MIGRATOR.iter().find(move |m| m.version == version);
        for version in 1..24 {
            let sql = migration(version).expect("migrations 1 to 23").sql.clone();
            let mut tx = conn.begin().await?;
            sqlx::raw_sql(sql).execute(&mut *tx).await?;
            tx.commit().await?;
        }
        let group = testing::group(&mut conn, "group:30001").await?;
        let xiaoming = group.xiaoming;
        let number = platform::account(&mut conn, Platform::QqLegacy, "10002", "小明").await?;
        let (other, into) = (
            platform::account(&mut conn, Platform::Qq, "10003", "小红").await?,
            platform::account(&mut conn, Platform::Qq, "10004", "小红").await?,
        );
        let merge = "update principals set merged_into = $2 where id = $1";
        for (account, into) in [(xiaoming, number), (other, into)] {
            sqlx::query(merge)
                .bind(account.principal.0)
                .bind(into.principal.0)
                .execute(&mut *conn)
                .await?;
        }
        sqlx::query(
            "insert into avatar_checks (identity_id, outcome, number_id, checked_at)
             values ($1, 'linked', $2, now()), ($3, 'none', null, now())",
        )
        .bind(xiaoming.identity.0)
        .bind(number.identity.0)
        .bind(into.identity.0)
        .execute(&mut *conn)
        .await?;
        let max = testing::sender(group.max, "Max", None);
        let mention = |identity| Content::Message {
            reply_to: None,
            nodes: vec![Node::Mention {
                target: MentionTarget::Identity(identity),
                display: "小明".into(),
            }],
        };
        let old = format!("[mention#{}]", number.principal);
        let mut ids = Vec::new();
        for (minute, identity) in [(1, xiaoming.identity), (2, number.identity)] {
            let id = testing::commit(&mut conn, &group, &max, &mention(identity), minute).await?;
            sqlx::query("update messages set text = $2 where id = $1")
                .bind(id.0)
                .bind(format!("{old} 在吗"))
                .execute(&mut *conn)
                .await?;
            ids.push(id);
        }

        let sql = migration(24).expect("migration 24").sql.clone();
        let mut tx = conn.begin().await?;
        sqlx::raw_sql(sql).execute(&mut *tx).await?;
        tx.commit().await?;

        let merged_into = async |conn: &mut PgConnection, account: platform::Account| {
            sqlx::query_scalar::<_, Option<i64>>("select merged_into from principals where id = $1")
                .bind(account.principal.0)
                .fetch_one(conn)
                .await
        };
        assert_eq!(merged_into(&mut conn, xiaoming).await?, None);
        assert_eq!(merged_into(&mut conn, other).await?, Some(into.principal.0));
        let text = async |conn: &mut PgConnection, id: MessageId| {
            sqlx::query_scalar::<_, String>("select text from messages where id = $1")
                .bind(id.0)
                .fetch_one(conn)
                .await
        };
        let own = format!("[mention#{}] 在吗", xiaoming.principal);
        assert_eq!(text(&mut conn, ids[0]).await?, own);
        assert_eq!(text(&mut conn, ids[1]).await?, format!("{old} 在吗"));
        let tables: Vec<Option<String>> = sqlx::query_scalar(
            "select to_regclass(name)::text from unnest(array['avatar_checks', 'legacy_avatars']) as name",
        )
        .fetch_all(&mut *conn)
        .await?;
        assert_eq!(tables, [None, None]);
        Ok(())
    }

    /// The form the NixOS module writes. With the user before an empty
    /// host, as in `postgresql://max@/max`, it isn't a URL at all.
    #[test]
    fn a_url_for_the_socket() {
        let options: PgConnectOptions = "postgresql:///maxx?host=/run/postgresql&user=maxx"
            .parse()
            .unwrap();
        assert_eq!(
            options.get_socket(),
            Some(&PathBuf::from("/run/postgresql"))
        );
        assert_eq!(options.get_username(), "maxx");
        assert_eq!(options.get_database(), Some("maxx"));
        assert!(
            "postgresql://maxx@/maxx?host=/run/postgresql"
                .parse::<PgConnectOptions>()
                .is_err()
        );
    }
}
