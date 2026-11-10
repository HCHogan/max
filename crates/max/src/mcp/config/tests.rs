use std::sync::Arc;

use max_core::ids::TurnId;
use max_db::PgPool;
use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use super::*;
use crate::conversation::testing::group_named;
use crate::conversation::{Event, Poster, Request};
use crate::mcp::{Caller, Services};

/// A turn's context whose conversation is `mailbox`, which a test
/// answers.
async fn context(pool: &PgPool) -> (Context, UnboundedReceiver<Event>) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group_named(&mut conn, "group:GROUP1").await);
    let (mailbox, events) = unbounded_channel();
    let context = Context {
        caller: Caller::Turn(Poster::new(mailbox, TurnId(1))),
        ..Context::check(Services::bare(pool.clone()), place)
    };
    (context, events)
}

/// Answers the next `Configure` with `answer`: the changes it asked for.
async fn answer(
    events: &mut UnboundedReceiver<Event>,
    answer: Result<Vec<Configured>, String>,
) -> Vec<(Setting, Option<u64>)> {
    let Some(Event::Request {
        request: Request::Configure { changes, reply },
        ..
    }) = events.recv().await
    else {
        panic!("no Configure");
    };
    reply.send(answer).unwrap();
    changes
}

fn now() -> Vec<Configured> {
    let one = |setting, value, default| Configured {
        setting,
        value,
        default,
    };
    vec![
        one(Setting::IdleWindowSecs, 1800, 300),
        one(Setting::CallTimeSecs, 60, 60),
        one(Setting::CommandsAtOnce, 8, 8),
    ]
}

async fn call(context: &Context, args: Value) -> Result<Value, Failure> {
    crate::mcp::call(Config::NAME, context, args).await
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn max_sets_and_resets_its_limits(pool: PgPool) {
    let (context, mut events) = context(&pool).await;
    let called = call(
        &context,
        json!({ "call_time_secs": 120, "idle_window_secs": 0 }),
    );
    let (out, changes) = tokio::join!(called, answer(&mut events, Ok(now())));
    assert_eq!(
        changes,
        [
            (Setting::IdleWindowSecs, None),
            (Setting::CallTimeSecs, Some(120))
        ]
    );
    assert_eq!(
        out.unwrap(),
        json!({
            "idle_window_secs": { "value": 1800, "default": 300 },
            "call_time_secs": { "value": 60, "default": 60 },
            "commands_at_once": { "value": 8, "default": 8 },
        })
    );

    // Nothing given: only a look.
    let (out, changes) = tokio::join!(call(&context, json!({})), answer(&mut events, Ok(now())));
    assert!(changes.is_empty());
    assert!(out.is_ok());
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn what_cant_be_set_isnt_asked_for(pool: PgPool) {
    let (context, mut events) = context(&pool).await;
    let short = call(&context, json!({ "call_time_secs": 5 }))
        .await
        .unwrap_err();
    assert_eq!(short.code, "bad_arguments");
    assert_eq!(
        short.message,
        "call_time_secs 要么是 0（恢复默认），要么在 10 到 600 之间"
    );
    let long = call(&context, json!({ "commands_at_once": 17 }))
        .await
        .unwrap_err();
    assert_eq!(long.code, "bad_arguments");
    let unknown = call(&context, json!({ "job_time_secs": 60 }))
        .await
        .unwrap_err();
    assert_eq!(unknown.code, "bad_arguments");
    assert!(events.try_recv().is_err(), "nothing reached the actor");

    let refused = call(&context, json!({ "commands_at_once": 2 }));
    let (out, _) = tokio::join!(
        refused,
        answer(&mut events, Err("这一轮已经结束了，没做".into()))
    );
    assert_eq!(
        out.unwrap_err(),
        Failure::new("not_configured", "这一轮已经结束了，没做")
    );

    let nobody = Context::check(Services::bare(pool.clone()), Arc::clone(&context.place));
    let out = call(&nobody, json!({})).await.unwrap_err();
    assert_eq!(out.code, "not_here");
}
