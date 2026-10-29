//! The old captions, for the files maxx has: a picture's from `images`,
//! and the sticker library's from `stickers`, which wins where a file is
//! both. A file maxx captioned already keeps its own, so this can run
//! again, and while maxx serves. See "导入".

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_db::PgConnection;
use tracing::info;

/// What the Haskell version wrote for a sticker its captioner skipped.
const SKIPPED: &str = "(skipped by captioner)";
/// The most of a caption that is kept, in characters, as maxx keeps.
const MOST: usize = 300;

/// A caption to write: its kind, text, whether it's a sticker not to
/// send, and when.
type Caption = (&'static str, String, bool, DateTime<Utc>);

pub async fn import(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
    let have: Vec<String> = sqlx::query_scalar("select sha256 from media")
        .fetch_all(&mut *new)
        .await?;
    let mut captions: BTreeMap<String, Caption> = BTreeMap::new();
    let pictures: Vec<(String, String, DateTime<Utc>)> = sqlx::query_as(
        "select sha256, description, first_seen_at from images
         where sha256 = any($1) and btrim(description) <> ''",
    )
    .bind(&have)
    .fetch_all(&mut *old)
    .await?;
    for (sha256, text, at) in pictures {
        captions.insert(sha256, ("image", one_line(&text), false, at));
    }
    let stickers: Vec<(String, Option<String>, bool, DateTime<Utc>)> = sqlx::query_as(
        "select sha256, description, banned, first_seen_at from stickers
         where sha256 = any($1)",
    )
    .bind(&have)
    .fetch_all(&mut *old)
    .await?;
    for (sha256, text, banned, at) in stickers {
        let text = text
            .filter(|text| text != SKIPPED)
            .map(|text| one_line(&text))
            .unwrap_or_default();
        // One never captioned isn't one yet.
        if banned || !text.is_empty() {
            captions.insert(sha256, ("sticker", text, banned, at));
        }
    }
    let written = sqlx::query(
        "insert into media_captions (sha256, kind, text, skip, created_at)
         select * from unnest($1::text[], $2::text[], $3::text[], $4::boolean[],
                              $5::timestamptz[])
         on conflict (sha256) do nothing",
    )
    .bind(captions.keys().collect::<Vec<_>>())
    .bind(captions.values().map(|c| c.0).collect::<Vec<_>>())
    .bind(captions.values().map(|c| c.1.as_str()).collect::<Vec<_>>())
    .bind(captions.values().map(|c| c.2).collect::<Vec<_>>())
    .bind(captions.values().map(|c| c.3).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    info!(
        old = captions.len(),
        written = written.rows_affected(),
        "captions"
    );
    Ok(())
}

/// On one line, as maxx's own are, and no longer.
fn one_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MOST)
        .collect()
}
