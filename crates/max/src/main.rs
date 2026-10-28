//! Max, a group chat agent. `max run` serves; `max check-config` checks a
//! configuration file's structure without reading its secrets, which the
//! NixOS module does when it builds the file.

mod config;

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Parser, Subcommand};
use color_eyre::config::{HookBuilder, Theme};
use color_eyre::eyre::{Result, WrapErr};
use tokio::signal::unix::{SignalKind, signal};
use tracing::info;

use crate::config::Config;

/// How long tasks still running when Max stops get to finish.
const SHUTDOWN: Duration = Duration::from_secs(10);

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Serve.
    Run(Args),
    /// Check a configuration file without reading the secrets it names.
    CheckConfig(Args),
}

#[derive(clap::Args)]
struct Args {
    /// The configuration file.
    #[arg(long)]
    config: PathBuf,
}

fn main() -> Result<()> {
    // journald keeps the colours' escape codes as they are.
    let theme = if std::io::stderr().is_terminal() {
        Theme::dark()
    } else {
        Theme::new()
    };
    HookBuilder::new().theme(theme).install()?;
    match Cli::parse().command {
        Command::CheckConfig(args) => Config::load(&args.config).map(drop),
        Command::Run(args) => run(&args.config),
    }
}

fn run(path: &Path) -> Result<()> {
    let config = Config::load(path)?;
    logging(&config);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let served = runtime.block_on(serve(config));
    // Dropping the runtime would wait on blocking tasks for as long as
    // they take.
    runtime.shutdown_timeout(SHUTDOWN);
    served
}

fn logging(config: &Config) {
    let journal = std::env::var_os("JOURNAL_STREAM").is_some();
    let logs = tracing_subscriber::fmt()
        .with_max_level(config.log.level)
        .with_ansi(std::io::stdout().is_terminal());
    // journald stamps each line itself.
    if journal {
        logs.without_time().init();
    } else {
        logs.init();
    }
}

async fn serve(config: Config) -> Result<()> {
    let qq = config
        .platforms
        .qq
        .as_ref()
        .map(config::Qq::credentials)
        .transpose()?;

    let pool = max_db::PgPool::connect(&config.database.url)
        .await
        .wrap_err("connecting to the database")?;
    max_db::MIGRATOR
        .run(&pool)
        .await
        .wrap_err("migrating the database")?;
    info!("migrations applied");

    if let Some(credentials) = qq {
        let client = qqbot::Client::new(credentials)?;
        let me = client.me().await.wrap_err("checking the QQ credentials")?;
        info!(bot = %me.username, "QQ credentials work");
    }

    let mut terminate = signal(SignalKind::terminate())?;
    tokio::select! {
        _ = terminate.recv() => {}
        interrupted = tokio::signal::ctrl_c() => interrupted?,
    }
    info!("stopping");
    pool.close().await;
    Ok(())
}
