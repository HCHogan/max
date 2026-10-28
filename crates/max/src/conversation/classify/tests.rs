use std::sync::Arc;

use max_db::PgPool;
use tokio::sync::mpsc;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{at, from_xiaohong, from_xiaoming, group, offset, text};
use crate::llm::testing::{Answer, Script, models};

async fn job(pool: &PgPool, script: &Arc<Script>) -> Job {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let mut batch = Vec::new();
    for n in 0..4 {
        let said = format!("第{n}句");
        let inbound = if n % 2 == 0 {
            from_xiaoming(n, vec![text(&said)])
        } else {
            from_xiaohong(n, vec![text(&said)])
        };
        let committed = ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap();
        if n >= 2 {
            batch.push(committed.message.id);
        }
    }
    Job {
        pool: pool.clone(),
        place: Arc::new(place),
        chosen: models(script).intent().unwrap(),
        persona: "人设".into(),
        batch,
        status: max_core::intent::Intent::new(Default::default()).status(std::time::Instant::now()),
        context_lines: 1,
        offset: offset(),
    }
}

async fn verdict(job: Job) -> Option<Verdict> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    classify(job, TaskId(3), tx).await;
    let Ok(Event::Verdict { task, verdict }) = rx.try_recv() else {
        panic!("no Verdict");
    };
    assert_eq!(task, TaskId(3));
    assert!(rx.try_recv().is_err());
    verdict
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_classifier_reads_the_context(pool: PgPool) {
    let script = Arc::new(Script::default());
    let answer =
        r#"好的：{"trigger": true, "kind": "followup", "reason": "在追问", "dismiss": false}"#;
    script.push(Answer::says(answer));
    let verdict = verdict(job(&pool, &script).await).await.unwrap();
    assert!(verdict.trigger);
    assert_eq!(verdict.reason, "在追问");
    let text = match &script.requests.lock().unwrap()[0].items[1].kind {
        ItemKind::User { text } => text.clone(),
        other => panic!("{other:?}"),
    };
    assert!(text.starts_with("[上下文]\n[12:01 小红 #"), "{text}");
    assert!(text.contains("]: 第1句\n\n[本群情况]\n近 1 小时"), "{text}");
    assert!(text.ends_with("]: 第3句"), "{text}");
    assert!(text.contains("[新消息]\n[12:02 小明 #"), "{text}");
    let mut conn = pool.acquire().await.unwrap();
    let calls: i64 = sqlx::query_scalar("select count(*) from llm_usage where purpose = 'intent'")
        .fetch_one(&mut *conn)
        .await
        .unwrap();
    assert_eq!(calls, 1);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn no_verdict_from_prose(pool: PgPool) {
    let script = Arc::new(Script::default());
    script.push(Answer::says("我觉得应该接话"));
    assert_eq!(verdict(job(&pool, &script).await).await, None);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn no_verdict_from_a_failed_call(pool: PgPool) {
    let script = Arc::new(Script::default());
    script.push(Answer::Fails(max_llm::Error::Truncated));
    assert_eq!(verdict(job(&pool, &script).await).await, None);
}
