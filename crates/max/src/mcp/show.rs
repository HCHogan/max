//! `max.image`: a picture a program has in /work, shown to the model after
//! the program's result. Not one of Max's tools: the runner's SDK calls it
//! by this name, and the model sees the picture, not a value. See "多模态结果".

use std::sync::{Mutex, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::task::spawn_blocking;
use tracing::warn;

use super::send_image::{beneath_work, internal, read};
use super::{Context, Failure, arguments};
use crate::media::prepare::prepare;

pub const NAME: &str = "max.image";
/// The most pictures one program shows.
pub const MOST: usize = 4;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    path: String,
}

/// Stores the model's copy of the picture at `path`, and adds it to
/// `shown`, the program's pictures so far, unless it is there already.
pub async fn run(
    context: &Context,
    shown: &Mutex<Vec<String>>,
    args: Value,
) -> Result<Value, Failure> {
    let Args { path } = arguments(NAME, args)?;
    let (Some(work), Some(store)) = (&context.work, &context.store) else {
        return Err(Failure::new("unavailable", "这里看不了图。"));
    };
    let full = || Failure::new("too_many", format!("一次 run_code 最多交 {MOST} 张图"));
    if lock(shown).len() >= MOST {
        return Err(full());
    }
    let relative = beneath_work(&path)?;
    let work = work.clone();
    let bytes = spawn_blocking(move || read(&work, &relative))
        .await
        .map_err(|_| internal())??;
    let (prepared, bytes) = spawn_blocking(move || (prepare(&bytes), bytes))
        .await
        .map_err(|_| internal())?;
    let Ok(Some(prepared)) = prepared else {
        return Err(Failure::new(
            "not_a_picture",
            format!("{path} 不是解得开的 PNG、JPEG、GIF、WebP"),
        ));
    };
    let sha256 = store
        .put(prepared.copy.unwrap_or(bytes))
        .await
        .map_err(|error| {
            warn!(%error, "couldn't store a picture to show");
            internal()
        })?;
    let mut shown = lock(shown);
    if !shown.contains(&sha256) {
        if shown.len() >= MOST {
            return Err(full());
        }
        shown.push(sha256);
    }
    Ok(json!({ "width": prepared.width, "height": prepared.height }))
}

fn lock(shown: &Mutex<Vec<String>>) -> std::sync::MutexGuard<'_, Vec<String>> {
    shown.lock().unwrap_or_else(PoisonError::into_inner)
}
