//! The model's copies of the imported pictures, and their sizes, which
//! maxx makes as it downloads a picture. The old tables have neither.
//! Those done already are skipped, so it can run again after a stop. It
//! runs while maxx is stopped: opening the store clears its `tmp/`.

use std::path::Path;

use color_eyre::eyre::Result;
use max::media::prepare::prepare;
use max::media::store::Store;
use max_db::PgConnection;
use tokio::task::JoinSet;
use tracing::{info, warn};

/// Pictures prepared side by side.
const AT_ONCE: usize = 8;

pub async fn run(new: &mut PgConnection, store: &Path) -> Result<()> {
    let store = Store::open(store).await?;
    let pending: Vec<String> = sqlx::query_scalar(
        "select sha256 from media
         where model_sha256 is null and (mime is null or mime like 'image/%')
         order by sha256",
    )
    .fetch_all(&mut *new)
    .await?;
    info!(pictures = pending.len(), "preparing");
    let mut pending = pending.into_iter();
    let mut running = JoinSet::new();
    let mut done = 0;
    loop {
        while running.len() < AT_ONCE {
            let Some(sha256) = pending.next() else { break };
            let path = store.path(&sha256);
            running.spawn(async move {
                let bytes = tokio::fs::read(&path).await;
                let prepared = match bytes {
                    Ok(bytes) => Ok(tokio::task::spawn_blocking(move || prepare(&bytes)).await),
                    Err(error) => Err(error),
                };
                (sha256, prepared)
            });
        }
        let Some(finished) = running.join_next().await else {
            break;
        };
        let (sha256, prepared) = finished?;
        let prepared = match prepared {
            Ok(prepared) => prepared?,
            Err(error) => {
                warn!(sha256, "couldn't read a picture: {error}");
                continue;
            }
        };
        let prepared = match prepared {
            Ok(Some(prepared)) => prepared,
            // Not a picture after all.
            Ok(None) => continue,
            Err(error) => {
                warn!(sha256, "a picture that doesn't decode: {error}");
                continue;
            }
        };
        let model_sha256 = match prepared.copy {
            Some(copy) => store.put(copy).await?,
            None => sha256.clone(),
        };
        sqlx::query(
            "update media set width = $2, height = $3, model_sha256 = $4 where sha256 = $1",
        )
        .bind(&sha256)
        .bind(i32::try_from(prepared.width)?)
        .bind(i32::try_from(prepared.height)?)
        .bind(model_sha256)
        .execute(&mut *new)
        .await?;
        done += 1;
        if done % 1000 == 0 {
            info!(done, "prepared");
        }
    }
    info!(done, "prepared");
    Ok(())
}
