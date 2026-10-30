use std::path::PathBuf;
use std::sync::Arc;

use max_core::ids::TurnId;
use max_core::message::{MediaKind, MediaRef, Node};
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::sync::mpsc;

use super::*;
use crate::conversation::testing::{group, offset};
use crate::conversation::{Act, Event, Poster, ingest};
use crate::mcp::tool::Tool;
use crate::mcp::{Caller, Services};
use crate::media::store::Store;
use crate::scope::Scope;

/// Calls the tool as a program does, its arguments checked.
async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    crate::mcp::call(SendFile::NAME, context, args).await
}

/// A scratch directory, gone when dropped.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn names() {
    assert_eq!(named(" 周报.pdf ").unwrap(), "周报.pdf");
    let long = "长".repeat(LONGEST_NAME + 1);
    for bad in [
        "",
        " ",
        "..",
        "a/b.txt",
        "a\\b.txt",
        "a\nb.txt",
        long.as_str(),
    ] {
        assert_eq!(named(bad).unwrap_err().code, "bad_name", "{bad:?}");
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_report_goes_out_under_its_name(pool: PgPool) {
    let scratch =
        Scratch(std::env::temp_dir().join(format!("max-send-file-{:016x}", rand::random::<u64>())));
    let work = scratch.0.join("work");
    std::fs::create_dir_all(work.join("out")).unwrap();
    let store = Arc::new(Store::open(&scratch.0.join("store")).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    // The actor's part: commit what is posted, and say it went out.
    let (mailbox, mut posts) = mpsc::unbounded_channel();
    let committing = Arc::clone(&place);
    let mut scope = Scope::new();
    scope.spawn(move |_| async move {
        while let Some(event) = posts.recv().await {
            let Event::Post(post) = event else { continue };
            let Act::Say(draft) = post.act else { continue };
            let said = ingest::said(
                &mut conn,
                &committing,
                draft,
                None,
                None,
                Utc::now(),
                offset(),
            );
            let message = said.await.unwrap().unwrap();
            let _ = post.receipt.unwrap().send(Ok(message.id));
        }
    });
    let context = Context {
        services: Arc::new(Services {
            store: Some(Arc::clone(&store)),
            ..Services::bare(pool.clone())
        }),
        place: Arc::clone(&place),
        page_tokens: 2000,
        work: Some(work.clone()),
        caller: Caller::Turn(Poster::new(mailbox, TurnId(1))),
    };
    std::fs::write(work.join("out/report.pdf"), b"%PDF-1.4").unwrap();
    std::fs::write(work.join("empty.txt"), b"").unwrap();

    let sent = |args: Value| run(&context, args);
    let named = sent(json!({ "path": "/work/out/report.pdf", "name": "十月周报.pdf" }));
    let handle = named.await.unwrap()["handle"].as_str().unwrap().to_owned();
    let as_is = sent(json!({ "path": "out/report.pdf" })).await.unwrap();
    let ids: Vec<i64> = [handle.as_str(), as_is["handle"].as_str().unwrap()]
        .iter()
        .map(|handle| {
            let id = handle
                .strip_prefix("file#")
                .and_then(|rest| rest.strip_suffix(".0"));
            id.unwrap().parse().unwrap()
        })
        .collect();
    let mut shown = Vec::new();
    for id in &ids {
        let (nodes, text, linked): (sqlx::types::Json<Vec<Node>>, String, i64) = sqlx::query_as(
            "select nodes, text, (select count(*) from message_media where message_id = $1)
             from messages where id = $1",
        )
        .bind(id)
        .fetch_one(&pool)
        .await
        .unwrap();
        let [
            Node::Media {
                media: Some(MediaRef::Blob(sha256)),
                meta,
            },
        ] = nodes.0.as_slice()
        else {
            panic!("{nodes:?}");
        };
        assert_eq!(std::fs::read(store.path(sha256)).unwrap(), b"%PDF-1.4");
        assert_eq!(
            (meta.kind, meta.size, linked),
            (MediaKind::File, Some(8), 1)
        );
        // The text searched has the name; the handle is in the model's
        // view only.
        shown.push((meta.name.clone().unwrap(), text));
    }
    let named = |name: &str| (name.to_owned(), format!("[file: {name}]"));
    assert_eq!(shown, [named("十月周报.pdf"), named("report.pdf")]);

    let code = |result: Result<Value, Failure>| result.unwrap_err().code;
    assert_eq!(code(sent(json!({ "path": "empty.txt" })).await), "empty");
    assert_eq!(code(sent(json!({ "path": "out" })).await), "bad_path");
    let renamed = json!({ "path": "out/report.pdf", "name": "../x" });
    assert_eq!(code(sent(renamed).await), "bad_name");
    let elsewhere = Context {
        caller: Caller::Check,
        ..context
    };
    let refused = run(&elsewhere, json!({ "path": "out/report.pdf" })).await;
    assert_eq!(refused.unwrap_err().code, "unavailable");
    // The poster is gone, so the actor's part ends.
    scope.close(std::time::Duration::from_secs(5)).await;
}
