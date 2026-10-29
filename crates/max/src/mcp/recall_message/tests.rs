use std::sync::Arc;
use std::time::Duration;

use chrono::DateTime;
use max_core::ids::TurnId;
use max_core::message::{Draft, DraftNode};
use max_db::ledger::Sent;
use sqlx::PgPool;
use tokio::sync::mpsc;

use super::*;
use crate::conversation::testing::{from_xiaohong, from_xiaoming, group, offset, text};
use crate::conversation::{Act, Event, Place, Poster, ingest};
use crate::mcp::{Caller, Services};
use crate::scope::Scope;

/// What a call is told when it is refused.
async fn code(context: &Context, id: MessageId) -> &'static str {
    run(context, json!({ "id": id.0 })).await.unwrap_err().code
}

/// Someone's message, sent `at`.
async fn heard(pool: &PgPool, place: &Place, admin: bool, n: u32, at: DateTime<Utc>) -> MessageId {
    let mut inbound = if admin {
        from_xiaohong(n, vec![text("加群领红包")])
    } else {
        from_xiaoming(n, vec![text("加群领红包")])
    };
    inbound.at = at;
    let mut conn = pool.acquire().await.unwrap();
    let committed = ingest::inbound(&mut conn, place, &inbound, Utc::now(), offset());
    committed.await.unwrap().message.id
}

/// Something Max said, and what became of it.
async fn said(pool: &PgPool, place: &Place, sent: &Sent<'_>, at: DateTime<Utc>) -> MessageId {
    let draft = Draft {
        reply_to: None,
        nodes: vec![DraftNode::Text { text: "一".into() }],
    };
    let mut conn = pool.acquire().await.unwrap();
    let said = ingest::said(&mut conn, place, draft, None, None, at, offset());
    let id = said.await.unwrap().unwrap().id;
    ledger::record_delivery(&mut conn, id, place.endpoint, sent, at)
        .await
        .unwrap();
    id
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn what_qq_would_refuse_is_refused_here(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    // The actor's part: commit each unsend, and answer as QQ would, which
    // refuses the second.
    let (mailbox, mut posts) = mpsc::unbounded_channel();
    let committing = Arc::clone(&place);
    let actor_pool = pool.clone();
    let mut scope = Scope::new();
    scope.spawn(move |_| async move {
        let mut conn = actor_pool.acquire().await.unwrap();
        let mut answers = [Ok(()), Err("QQ 说没有权限".to_owned())].into_iter();
        while let Some(Event::Post(post)) = posts.recv().await {
            let Act::Unsend(target) = post.act else {
                continue;
            };
            let unsend = ingest::unsend(&mut conn, &committing, target, None, Utc::now(), offset());
            let row = unsend.await.unwrap().unwrap();
            let answer = answers.next().unwrap_or(Ok(()));
            if answer.is_err() {
                let refused = Sent::Failed { error: "40062003" };
                let endpoint = committing.endpoint;
                ledger::record_delivery(&mut conn, row.id, endpoint, &refused, Utc::now())
                    .await
                    .unwrap();
            }
            let _ = post.receipt.unwrap().send(answer.map(|()| row.id));
        }
    });
    let context = Context {
        services: Arc::new(Services::bare(pool.clone())),
        place: Arc::clone(&place),
        page_tokens: 2000,
        work: None,
        caller: Caller::Turn(Poster::new(mailbox, TurnId(1))),
    };
    let now = Utc::now();
    let long_ago = now - TimeDelta::minutes(3);

    // 小明's, just now: recalled, and then it is done.
    let spam = heard(&pool, &place, false, 0, now).await;
    let recalled = run(&context, json!({ "id": spam.0 })).await.unwrap();
    assert_eq!(recalled, json!({ "recalled": spam.0 }));
    assert_eq!(code(&context, spam).await, "refused");
    // QQ refuses another: the program hears why.
    let more = heard(&pool, &place, false, 1, now).await;
    let failure = run(&context, json!({ "id": more.0 })).await.unwrap_err();
    assert_eq!(failure.code, "not_recalled");
    assert!(failure.message.contains("没有权限"), "{failure:?}");
    // An admin's, or anyone's too old: no unsend is even tried.
    let admins = heard(&pool, &place, true, 2, now).await;
    assert_eq!(code(&context, admins).await, "refused");
    let old = heard(&pool, &place, false, 3, long_ago).await;
    assert_eq!(code(&context, old).await, "refused");

    // Max's: one QQ has, one too old, one that didn't go out.
    let delivered = Sent::Delivered {
        native_id: "SENT1",
        quote_id: None,
    };
    let fresh = said(&pool, &place, &delivered, now).await;
    assert!(run(&context, json!({ "id": fresh.0 })).await.is_ok());
    let delivered = Sent::Delivered {
        native_id: "SENT2",
        quote_id: None,
    };
    let stale = said(&pool, &place, &delivered, long_ago).await;
    assert_eq!(code(&context, stale).await, "refused");
    let failed = said(&pool, &place, &Sent::Failed { error: "风控" }, now).await;
    assert_eq!(code(&context, failed).await, "refused");

    // No such message here; an unsend is none either.
    assert_eq!(code(&context, MessageId(i64::MAX)).await, "not_found");
    let unsend: i64 = sqlx::query_scalar("select max(id) from messages where event = 'unsend'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(code(&context, MessageId(unsend)).await, "not_found");
    let elsewhere = Context {
        caller: Caller::Check,
        ..context
    };
    assert_eq!(code(&elsewhere, fresh).await, "unavailable");
    // The poster is gone, so the actor's part ends.
    scope.close(Duration::from_secs(5)).await;
}
