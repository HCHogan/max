//! Media: which file each media node of the rows that came along is, and
//! a row per file. The files themselves are copied into maxx's content
//! store beforehand, as root; every one has to be there.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use chrono::{DateTime, Utc};
use color_eyre::eyre::{Result, bail};
use max_core::message::{self, MediaKind, MediaRef, Node};
use max_db::PgConnection;
use sqlx::AssertSqlSafe;
use sqlx::types::Json;
use tracing::info;

use crate::messages::Messages;

/// A file in the old tables: its SHA-256, MIME type, size and when it
/// was first seen.
type Known = (String, Option<String>, Option<i64>, DateTime<Utc>);

/// A file's row, as far as the old tables say.
struct File {
    mime: Option<String>,
    size: Option<i64>,
    first_seen_at: Option<DateTime<Utc>>,
}

pub async fn import(
    old: &mut PgConnection,
    new: &mut PgConnection,
    messages: &Messages,
    store: &Path,
) -> Result<()> {
    // (row, ordinal) → SHA-256; the first source to name one wins.
    let mut links: BTreeMap<(i64, u16), String> = BTreeMap::new();
    // Pictures and videos name the old node they were.
    for table in ["message_images", "message_videos"] {
        let query = format!("select canonical_message_id, seg_index, sha256 from {table}");
        let rows: Vec<(i64, i32, String)> = sqlx::query_as(AssertSqlSafe(query))
            .fetch_all(&mut *old)
            .await?;
        for (id, index, sha256) in rows {
            // Some name a node that isn't media, or a row that stayed
            // behind.
            if let Some(at) = messages.media.get(&(id, index)) {
                links.entry(*at).or_insert(sha256);
            }
        }
    }
    // A file names its row, which has one file node.
    let files: Vec<(i64, String)> = sqlx::query_as(
        "select canonical_message_id, sha256 from group_files
         where sha256 is not null and canonical_message_id is not null",
    )
    .fetch_all(&mut *old)
    .await?;
    let ids: Vec<i64> = files.iter().map(|(id, _)| *id).collect();
    let rows: Vec<(i64, Json<Vec<Node>>)> =
        sqlx::query_as("select id, nodes from messages where id = any($1)")
            .bind(&ids)
            .fetch_all(&mut *new)
            .await?;
    let nodes: HashMap<i64, Vec<Node>> =
        rows.into_iter().map(|(id, nodes)| (id, nodes.0)).collect();
    for (id, sha256) in files {
        let file = nodes.get(&id).and_then(|nodes| {
            message::media(nodes).find(|(_, _, meta)| meta.kind == MediaKind::File)
        });
        if let Some((ordinal, _, _)) = file {
            links.entry((id, ordinal)).or_insert(sha256);
        }
    }
    // The rest are nodes that name their file: mostly what Max sent.
    let mut blobs: HashMap<String, File> = HashMap::new();
    let rows: Vec<(i64, Json<Vec<Node>>)> = sqlx::query_as(
        "select id, nodes from messages where jsonb_path_exists(nodes, '$[*].media.blob')",
    )
    .fetch_all(&mut *new)
    .await?;
    for (id, nodes) in rows {
        for (ordinal, media, meta) in message::media(&nodes) {
            if let Some(MediaRef::Blob(sha256)) = media {
                links.entry((id, ordinal)).or_insert_with(|| sha256.clone());
                blobs.entry(sha256.clone()).or_insert_with(|| File {
                    mime: meta.mime.clone(),
                    size: meta.size.and_then(|size| i64::try_from(size).ok()),
                    first_seen_at: None,
                });
            }
        }
    }

    let mut known: HashMap<String, File> = HashMap::new();
    let shas: Vec<&String> = links.values().collect();
    for query in [
        "select sha256, mime_type, bytes_size, first_seen_at from images where sha256 = any($1)",
        "select sha256, mime_type, bytes_size, first_seen_at from videos where sha256 = any($1)",
        "select sha256, mime_type, bytes_size, received_at from group_files where sha256 = any($1)",
    ] {
        let rows: Vec<Known> = sqlx::query_as(query)
            .bind(&shas)
            .fetch_all(&mut *old)
            .await?;
        for (sha256, mime, size, first_seen_at) in rows {
            known.entry(sha256).or_insert(File {
                mime,
                size,
                first_seen_at: Some(first_seen_at),
            });
        }
    }
    let rows: Vec<i64> = links.keys().map(|(id, _)| *id).collect();
    let sent: HashMap<i64, DateTime<Utc>> =
        sqlx::query_as("select id, sent_at from messages where id = any($1)")
            .bind(&rows)
            .fetch_all(&mut *new)
            .await?
            .into_iter()
            .collect();

    // When each file first came, by the rows that have it.
    let mut earliest: BTreeMap<&String, DateTime<Utc>> = BTreeMap::new();
    for ((id, _), sha256) in &links {
        let Some(at) = sent.get(id).copied() else {
            bail!("message {id} isn't in");
        };
        earliest
            .entry(sha256)
            .and_modify(|first| *first = (*first).min(at))
            .or_insert(at);
    }
    let mut media = Vec::new();
    let mut missing = Vec::new();
    for (sha256, earliest) in earliest {
        let path = store
            .join("objects")
            .join(sha256.get(..2).unwrap_or("00"))
            .join(sha256);
        let Ok(on_disk) = tokio::fs::metadata(&path).await else {
            missing.push(sha256);
            continue;
        };
        let file = known.get(sha256).or_else(|| blobs.get(sha256));
        let size = match file.and_then(|file| file.size) {
            Some(size) => size,
            None => i64::try_from(on_disk.len())?,
        };
        media.push((
            sha256,
            file.and_then(|file| file.mime.clone()),
            size,
            file.and_then(|file| file.first_seen_at).unwrap_or(earliest),
        ));
    }
    if let Some(first) = missing.first() {
        bail!(
            "{} files aren't in the content store at {}, such as {first}",
            missing.len(),
            store.display()
        );
    }

    sqlx::query(
        "insert into media (sha256, mime, size, first_seen_at)
         select * from unnest($1::text[], $2::text[], $3::bigint[], $4::timestamptz[])",
    )
    .bind(media.iter().map(|m| m.0).collect::<Vec<_>>())
    .bind(media.iter().map(|m| m.1.clone()).collect::<Vec<_>>())
    .bind(media.iter().map(|m| m.2).collect::<Vec<_>>())
    .bind(media.iter().map(|m| m.3).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    sqlx::query(
        "insert into message_media (message_id, ordinal, sha256)
         select * from unnest($1::bigint[], $2::smallint[], $3::text[])",
    )
    .bind(links.keys().map(|(id, _)| *id).collect::<Vec<_>>())
    .bind(
        links
            .keys()
            .map(|(_, ordinal)| i16::try_from(*ordinal))
            .collect::<Result<Vec<_>, _>>()?,
    )
    .bind(links.values().collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    info!(files = media.len(), links = links.len(), "media");
    Ok(())
}
