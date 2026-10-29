//! Imports the Haskell version's database into maxx's, once, at go-live:
//! everything into an empty database in one transaction, reading the old
//! one read-only. The mapping is "导入" in docs/rust-rewrite.md. The old
//! schema's code lives only here, and goes once maxx has run on the
//! imported data for a while.

mod messages;
mod nodes;
mod people;
mod places;
#[cfg(test)]
mod tests;

use std::str::FromStr;

use clap::{Parser, Subcommand};
use color_eyre::eyre::{Result, ensure};
use max_db::{MIGRATOR, PgConnection};
use sqlx::postgres::PgConnectOptions;
use sqlx::{AssertSqlSafe, Connection};
use tracing::info;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Import into an empty database, in one transaction.
    Import {
        /// The old database's URL, opened read-only.
        #[arg(long)]
        from: String,
        /// The new database's URL: migrated here, and refused unless empty.
        #[arg(long)]
        to: String,
        #[command(flatten)]
        accounts: Accounts,
    },
}

/// What the old database doesn't know: the official bot's accounts.
#[derive(clap::Args, Clone, Debug)]
pub struct Accounts {
    /// The bot's own openid: Max's new account.
    #[arg(long)]
    pub bot_openid: String,
    /// The owner's old QQ number.
    #[arg(long)]
    pub owner_qq: String,
    /// The user_openid the bot sees the owner by.
    #[arg(long)]
    pub owner_openid: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt().init();
    match Cli::parse().command {
        Command::Import { from, to, accounts } => {
            let from = PgConnectOptions::from_str(&from)?
                .options([("default_transaction_read_only", "on")]);
            let mut old = PgConnection::connect_with(&from).await?;
            let mut new = PgConnection::connect(&to).await?;
            import(&mut old, &mut new, &accounts).await
        }
    }
}

/// Everything, or nothing.
async fn import(old: &mut PgConnection, new: &mut PgConnection, accounts: &Accounts) -> Result<()> {
    MIGRATOR.run(&mut *new).await?;
    let rows: i64 = sqlx::query_scalar(
        "select (select count(*) from conversations) + (select count(*) from principals)
              + (select count(*) from identities) + (select count(*) from messages)",
    )
    .fetch_one(&mut *new)
    .await?;
    ensure!(rows == 0, "the new database isn't empty");

    let mut old = old.begin().await?;
    sqlx::query("set transaction isolation level repeatable read")
        .execute(&mut *old)
        .await?;
    let mut new = new.begin().await?;
    let people = people::import(&mut old, &mut new).await?;
    let places = places::import(&mut old, &mut new, &people).await?;
    messages::import(&mut old, &mut new, &people, &places).await?;
    people::name(&mut new).await?;
    sequences(&mut old, &mut new).await?;
    people::accounts(&mut new, &people, accounts).await?;
    new.commit().await?;
    info!("imported");
    Ok(())
}

/// New rows go after every old id, kept or not: old text may cite one.
async fn sequences(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
    let tables = [
        ("principals", "principals", "principal_id"),
        (
            "identities",
            "principal_identities",
            "principal_identity_id",
        ),
        ("conversations", "conversations", "conversation_id"),
        ("endpoints", "conversation_endpoints", "endpoint_id"),
        ("messages", "messages", "canonical_message_id"),
        ("summaries", "conversation_compartments", "id"),
    ];
    // The names are the constants above.
    for (table, old_table, old_column) in tables {
        let highest = format!("select max({old_column}) from {old_table}");
        let highest: Option<i64> = sqlx::query_scalar(AssertSqlSafe(highest))
            .fetch_one(&mut *old)
            .await?;
        let set = format!(
            "select setval(pg_get_serial_sequence('{table}', 'id'),
                           greatest($1, (select max(id) from {table}), 1))"
        );
        sqlx::query(AssertSqlSafe(set))
            .bind(highest)
            .execute(&mut *new)
            .await?;
    }
    Ok(())
}
