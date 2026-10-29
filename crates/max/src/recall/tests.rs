use max_core::ids::{MessageId, SummaryId};
use max_db::summaries::{self, Summary};
use sqlx::PgPool;
use tokio::sync::mpsc;

use super::*;
use crate::conversation::testing::{at, from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};
use crate::embedding::testing::{Asked, serve, vector};

async fn said(pool: &PgPool, place: &Place, n: u32, words: &str) -> MessageId {
    let mut conn = pool.acquire().await.unwrap();
    let inbound = from_xiaoming(n, vec![text(words)]);
    ingest::inbound(&mut conn, place, &inbound, at(n), offset())
        .await
        .unwrap()
        .message
        .id
}

async fn summarized(pool: &PgPool, place: &Place, row: MessageId, full: &str) -> SummaryId {
    let summary = Summary {
        first: row,
        last: row,
        started_at: at(0),
        ended_at: at(0),
        title: "部署".into(),
        kind: "decision".into(),
        importance: 50,
        full: full.into(),
        brief: None,
        line: None,
    };
    let mut conn = pool.acquire().await.unwrap();
    summaries::insert(&mut conn, place.conversation, &summary, "m", at(9))
        .await
        .unwrap()
}

/// The vectors: rows' by id, summaries' by the negative of theirs.
async fn stored(pool: &PgPool) -> Vec<(i64, String, Vec<f32>)> {
    sqlx::query_as(
        "select message_id, model, embedding::real[] from message_embeddings
         union all
         select -summary_id, model, embedding::real[] from summary_embeddings
         order by 1",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

async fn place(pool: &PgPool) -> Place {
    let mut conn = pool.acquire().await.unwrap();
    group(&mut conn).await
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn rows_and_summaries_get_vectors(pool: PgPool) {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let worker = Vectors {
        pool: pool.clone(),
        embedder,
    };
    let place = place(&pool).await;
    let plan = said(&pool, &place, 1, "今晚部署新版本").await;
    let short = said(&pool, &place, 2, "好的").await;
    let down = said(&pool, &place, 3, "服务器挂了吗").await;
    let summary = summarized(&pool, &place, plan, "定了今晚部署。").await;

    worker.embed(&[Key::Message(plan)]).await.unwrap();
    worker.embed(&[Key::Summary(summary)]).await.unwrap();
    let expected = vec![
        (
            -summary.0,
            "test-m3".to_owned(),
            vector("部署\n定了今晚部署。"),
        ),
        (plan.0, "test-m3".to_owned(), vector("今晚部署新版本")),
    ];
    assert_eq!(stored(&pool).await, expected);
    // Done: the service isn't asked again; nor for a row too short.
    let again = [Key::Message(plan), Key::Message(short)];
    worker.embed(&again).await.unwrap();
    assert_eq!(asked.lock().unwrap().len(), 2);

    // A failure writes nothing; a scan still finds it.
    assert!(worker.embed(&[Key::Message(down)]).await.is_err());
    assert_eq!(stored(&pool).await, expected);
    let mut conn = pool.acquire().await.unwrap();
    let missing = vectors::unembedded(&mut conn, "test-m3", None, 10)
        .await
        .unwrap();
    assert_eq!(missing, [Key::Message(down)]);
    scope.close(Duration::ZERO).await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_worker_embeds_what_comes_and_what_it_finds(pool: PgPool) {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let worker = Vectors {
        pool: pool.clone(),
        embedder,
    };
    // There before the worker starts: its first scan finds them, in two
    // pages.
    let place = place(&pool).await;
    let mut first = None;
    for n in 0..17 {
        let row = said(&pool, &place, n, &format!("第{n}次说部署")).await;
        first.get_or_insert(row);
    }
    summarized(&pool, &place, first.unwrap(), "定了。").await;
    let (keys, inbox) = mpsc::unbounded_channel();
    let stop = CancellationToken::new();
    let running = worker.run(inbox, stop.clone());
    let wait = async |count: usize| {
        for _ in 0..100 {
            if stored(&pool).await.len() == count {
                return;
            }
            sleep(Duration::from_millis(50)).await;
        }
    };
    let test = async {
        wait(18).await;
        let row = said(&pool, &place, 20, "部署完了没出问题").await;
        keys.send(Key::Message(row)).unwrap();
        wait(19).await;
        stop.cancel();
        row
    };
    let ((), row) = tokio::join!(running, test);
    let vectors = stored(&pool).await;
    assert_eq!(vectors.len(), 19);
    assert_eq!(
        vectors.last().unwrap(),
        &(row.0, "test-m3".to_owned(), vector("部署完了没出问题"))
    );
    let asked: Vec<usize> = asked
        .lock()
        .unwrap()
        .iter()
        .map(|(_, body)| body["input"].as_array().unwrap().len())
        .collect();
    assert_eq!(asked, [16, 2, 1]);
    scope.close(Duration::ZERO).await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_text_turned_down_holds_up_nothing(pool: PgPool) {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let worker = Vectors {
        pool: pool.clone(),
        embedder,
    };
    let place = place(&pool).await;
    let old = said(&pool, &place, 1, "上周部署过").await;
    let down = said(&pool, &place, 2, "服务器挂了吗").await;
    let new = said(&pool, &place, 3, "今晚部署新版本").await;
    let slots = Semaphore::new(AT_ONCE);

    // The page fails, and its texts one by one get the rest done.
    assert_eq!(worker.scan(&slots).await.unwrap(), 1);
    let ids: Vec<i64> = stored(&pool).await.iter().map(|(id, ..)| *id).collect();
    assert_eq!(ids, [old.0, new.0]);
    let sizes = |asked: &Asked| -> Vec<usize> {
        let asked = asked.lock().unwrap();
        let inputs = asked
            .iter()
            .map(|(_, body)| body["input"].as_array().unwrap().len());
        inputs.collect()
    };
    assert_eq!(sizes(&asked), [3, 1, 1, 1]);
    // Then it is all there is, and none goes through: the scan ends.
    assert_eq!(worker.scan(&slots).await.unwrap(), 0);
    assert_eq!(sizes(&asked), [3, 1, 1, 1, 1, 1]);
    let mut conn = pool.acquire().await.unwrap();
    let missing = vectors::unembedded(&mut conn, "test-m3", None, 10)
        .await
        .unwrap();
    assert_eq!(missing, [Key::Message(down)]);
    scope.close(Duration::ZERO).await;
}
