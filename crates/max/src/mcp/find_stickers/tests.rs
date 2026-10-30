use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use max_core::message::{MediaMeta, MediaRef, Node};
use max_db::captions::{self, Caption, Kind};
use max_db::media::{self, Blob};
use serde_json::{Value, json};
use sqlx::PgPool;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset};
use crate::embedding::testing::{serve, vector};
use crate::inbound::InNode;
use crate::mcp::tool::Tool;
use crate::mcp::{Caller, Services};
use crate::scope::Scope;

/// Calls the tool as a program does, its arguments checked.
async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    crate::mcp::call(FindStickers::NAME, context, args).await
}

fn medium(kind: MediaKind) -> InNode {
    InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://q.example/x".into())),
        meta: MediaMeta {
            kind,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    })
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_nearest_stickers_by_handle(pool: PgPool) {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let nodes = vec![
        medium(MediaKind::Sticker),
        medium(MediaKind::Sticker),
        medium(MediaKind::Sticker),
    ];
    let row = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(1, nodes),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap()
    .message
    .id;
    // A cat, a dog, and a selfie the captioner skipped.
    let files = [
        ('a', "翻白眼的猫", false),
        ('b', "开心的狗", false),
        ('c', "猫的自拍", true),
    ];
    for (ordinal, (letter, text, skip)) in (0..).zip(files) {
        let sha256 = letter.to_string().repeat(64);
        let blob = Blob {
            sha256: sha256.clone(),
            mime: None,
            size: 1,
            width: None,
            height: None,
            model_sha256: Some(sha256.clone()),
        };
        media::record(&mut conn, row, ordinal, &blob, Utc::now())
            .await
            .unwrap();
        let caption = Caption {
            sha256: &sha256,
            kind: Kind::Sticker,
            text,
            skip,
            model: None,
            at: Utc::now(),
        };
        captions::write(&mut conn, &caption).await.unwrap();
        let at = Utc::now();
        embeddings::write(&mut conn, &sha256, "test-m3", &vector(text), at)
            .await
            .unwrap();
    }
    drop(conn);
    let mut context = Context {
        services: Arc::new(Services {
            embedder: Some(embedder),
            ..Services::bare(pool)
        }),
        place,
        page_tokens: 2000,
        work: None,
        caller: Caller::Check,
    };

    let found = run(&context, json!({ "query": " 猫 " })).await.unwrap();
    assert_eq!(
        found,
        json!({ "stickers": [
            { "handle": format!("sticker#{row}.0"), "description": "翻白眼的猫" },
            { "handle": format!("sticker#{row}.1"), "description": "开心的狗" },
        ]}),
        "nearest first, the skipped one left out"
    );
    assert_eq!(asked.lock().unwrap()[0].1["input"][0], "猫");
    let one = run(&context, json!({ "query": "狗", "limit": 1 }))
        .await
        .unwrap();
    assert_eq!(one["stickers"][0]["description"], "开心的狗");
    assert_eq!(one["stickers"].as_array().unwrap().len(), 1);

    let code = async |context: &Context, args| run(context, args).await.unwrap_err().code;
    assert_eq!(
        code(&context, json!({ "query": "  " })).await,
        "bad_arguments"
    );
    assert_eq!(
        code(&context, json!({ "query": "猫", "n": 1 })).await,
        "bad_arguments"
    );
    assert_eq!(
        code(&context, json!({ "query": "挂" })).await,
        "unavailable"
    );
    context.services = Arc::new(Services {
        embedder: None,
        ..(*context.services).clone()
    });
    assert_eq!(
        code(&context, json!({ "query": "猫" })).await,
        "unavailable"
    );
    scope.close(Duration::ZERO).await;
}
