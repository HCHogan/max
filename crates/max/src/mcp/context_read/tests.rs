use std::sync::Arc;

use chrono::Utc;
use max_db::summaries::{self as stored, Summary};
use sqlx::PgPool;

use super::*;
use crate::conversation::testing::{
    at, from_xiaohong, from_xiaoming, group, group_named, offset, text,
};
use crate::conversation::{Place, ingest};
use crate::mcp::{Caller, Services};

fn context(pool: &PgPool, place: &Arc<Place>, page_tokens: u32) -> Context {
    Context {
        services: Arc::new(Services::bare(pool.clone())),
        place: Arc::clone(place),
        page_tokens,
        work: None,
        caller: Caller::Check,
    }
}

#[test]
fn pages_hold_the_text_in_order_and_under_the_cap() {
    let text: String = (0..3000).map(|n| format!("第{n}句。")).collect();
    let pages = pages(&text, 500);
    assert!(pages.len() > 1);
    assert!(pages.iter().all(|page| tokens::count(page) <= 500));
    assert_eq!(pages.concat(), text);
    assert_eq!(super::pages("短", 500), ["短"]);
    assert_eq!(super::pages("", 500), [""]);
}

#[test]
fn packed_pages_end_between_lines() {
    let lines: Vec<String> = (0..300)
        .map(|n| format!("[12:00 小明 #{n}]: 第{n}句"))
        .collect();
    let text = lines.join("\n");
    let pages = packed(&text, 200);
    assert!(pages.len() > 1);
    assert!(pages.iter().all(|page| tokens::count(page) <= 200));
    assert_eq!(pages.join("\n"), text);
    assert_eq!(packed("", 200), [""]);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_long_row_reads_page_by_page(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let long = "长".repeat(6000);
    let committed = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(1, vec![text(&long)]),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap();
    drop(conn);
    let id = committed.message.id.0;
    let context = context(&pool, &place, 2000);

    let first = run(&context, json!({ "id": id })).await.unwrap();
    let pages = first["pages"].as_u64().unwrap();
    assert!(pages > 1, "{first}");
    let mut whole = String::new();
    for page in 1..=pages {
        let read = run(&context, json!({ "id": id, "page": page }))
            .await
            .unwrap();
        assert_eq!(read["page"], page);
        whole.push_str(read["text"].as_str().unwrap());
    }
    assert!(
        whole.starts_with(&format!("[12:01 小明 #{id}]: 长")),
        "{whole}"
    );
    assert_eq!(whole.matches('长').count(), 6000);

    let past = run(&context, json!({ "id": id, "page": pages + 1 })).await;
    assert_eq!(past.unwrap_err().code, "no_page");
    let other = run(&context, json!({ "id": id + 100 })).await;
    assert_eq!(other.unwrap_err().code, "not_found");
    let wrong = run(&context, json!({ "id": "x" })).await;
    assert_eq!(wrong.unwrap_err().code, "bad_arguments");
    let typo = super::super::call("context_reed", &context, json!({})).await;
    assert_eq!(typo.unwrap_err().code, "unknown_tool");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_rows_around_one(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let elsewhere = Arc::new(group_named(&mut conn, "group:GROUP2").await);
    let mut ids = Vec::new();
    for n in 1..=5 {
        let said = format!("第{n}句");
        let inbound = from_xiaoming(n, vec![text(&said)]);
        let committed = ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap();
        ids.push(committed.message.id.0);
    }
    let mut far = from_xiaohong(9, vec![text("别的群")]);
    far.chat.native_id = "group:GROUP2".into();
    let far = ingest::inbound(&mut conn, &elsewhere, &far, at(9), offset())
        .await
        .unwrap()
        .message
        .id;
    drop(conn);
    let context = context(&pool, &place, 2000);

    let read = run(&context, json!({ "id": ids[2], "before": 1, "after": 1 }))
        .await
        .unwrap();
    assert_eq!(
        read["text"],
        format!(
            "--- 2026-10-29 周四 ---\n[12:02 小明 #{}]: 第2句\n[12:03 小明 #{}]: 第3句\n[12:04 小明 #{}]: 第4句",
            ids[1], ids[2], ids[3]
        )
    );
    assert_eq!(read["pages"], 1);
    // At most 50 a side, and no more than there are: a date line and the
    // five rows.
    let all = run(&context, json!({ "id": ids[1], "before": 200, "after": 9 }))
        .await
        .unwrap();
    assert_eq!(all["text"].as_str().unwrap().lines().count(), 6);

    let other = run(&context, json!({ "id": far.0, "after": 1 })).await;
    assert_eq!(other.unwrap_err().code, "not_found");
    for args in [
        json!({}),
        json!({ "id": ids[0], "summary": 1 }),
        json!({ "summary": 1, "after": 2 }),
        json!({ "id": ids[0], "after": 300 }),
    ] {
        let wrong = run(&context, args).await;
        assert_eq!(wrong.unwrap_err().code, "bad_arguments");
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_summary_in_full(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let mut committed = Vec::new();
    for n in 1..=3 {
        let inbound = from_xiaoming(n, vec![text("聊部署")]);
        committed.push(
            ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
                .await
                .unwrap(),
        );
    }
    let xiaoming = committed[0].sender.principal;
    let summary = Summary {
        first: committed[0].message.id,
        last: committed[2].message.id,
        started_at: at(1),
        ended_at: at(3),
        title: "部署方案".into(),
        kind: "decision".into(),
        importance: 60,
        full: format!("[mention#{xiaoming}] 定了用蓝绿部署。"),
        brief: None,
        line: None,
    };
    let id = stored::insert(&mut conn, place.conversation, &summary, "m", at(9))
        .await
        .unwrap();
    drop(conn);
    let context = context(&pool, &place, 2000);

    let read = run(&context, json!({ "summary": id.0 })).await.unwrap();
    assert_eq!(
        read["text"],
        format!(
            "[summary#{id} 2026-10-29 周四 12:01–12:03] 部署方案\n[mention#{xiaoming}] 定了用蓝绿部署。\n\
             （总结的是 #{} 到 #{}）\n\n[上下文里的人]\n[mention#{xiaoming}] 小明",
            committed[0].message.id, committed[2].message.id
        )
    );
    let missing = run(&context, json!({ "summary": id.0 + 1 })).await;
    assert_eq!(missing.unwrap_err().code, "not_found");
}
