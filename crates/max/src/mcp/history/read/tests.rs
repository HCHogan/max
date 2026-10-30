use std::sync::Arc;

use chrono::Utc;
use sqlx::PgPool;

use super::*;
use crate::conversation::testing::{
    at, from_xiaohong, from_xiaoming, group, group_named, offset, text,
};
use crate::conversation::{Place, ingest};
use crate::mcp::history::run;
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

    let first = run(&context, json!({ "around": id, "before": 0, "after": 0 }))
        .await
        .unwrap();
    let pages = first["pages"].as_u64().unwrap();
    assert!(pages > 1, "{first}");
    let mut whole = String::new();
    for page in 1..=pages {
        let read = run(
            &context,
            json!({ "around": id, "before": 0, "after": 0, "page": page }),
        )
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

    let past = json!({ "around": id, "before": 0, "after": 0, "page": pages + 1 });
    assert_eq!(run(&context, past).await.unwrap_err().code, "no_page");
    let other = json!({ "around": id + 100, "before": 0, "after": 0 });
    assert_eq!(run(&context, other).await.unwrap_err().code, "not_found");
    let wrong = run(&context, json!({ "around": "x" })).await;
    assert_eq!(wrong.unwrap_err().code, "bad_arguments");
    let typo = crate::mcp::call("histroy", &context, json!({})).await;
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

    let read = run(
        &context,
        json!({ "around": ids[2], "before": 1, "after": 1 }),
    )
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
    let all = run(
        &context,
        json!({ "around": ids[1], "before": 200, "after": 9 }),
    )
    .await
    .unwrap();
    assert_eq!(all["text"].as_str().unwrap().lines().count(), 6);

    let other = run(&context, json!({ "around": far.0, "after": 1 })).await;
    assert_eq!(other.unwrap_err().code, "not_found");
    // Ten a side by default.
    let around = run(&context, json!({ "around": ids[0] })).await.unwrap();
    assert_eq!(around["text"].as_str().unwrap().lines().count(), 6);

    for args in [
        json!({ "around": ids[0], "who": "小明" }),
        json!({ "around": ids[0], "limit": 3 }),
        json!({ "around": ids[0], "after": 300 }),
        json!({ "from": "2026-10-29", "after": 1 }),
    ] {
        let wrong = run(&context, args).await;
        assert_eq!(wrong.unwrap_err().code, "bad_arguments");
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_stretch_by_time_and_sender(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let mut ids = Vec::new();
    for n in 1..=6 {
        let said = format!("第{n}句");
        // 小红 says the even ones.
        let inbound = if n % 2 == 0 {
            from_xiaohong(n, vec![text(&said)])
        } else {
            from_xiaoming(n, vec![text(&said)])
        };
        let committed = ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap();
        ids.push(committed.message.id.0);
    }
    drop(conn);
    let context = context(&pool, &place, 2000);
    let line = |n: usize| {
        let who = if n.is_multiple_of(2) {
            "小红"
        } else {
            "小明"
        };
        format!("[12:0{n} {who} #{}]: 第{n}句", ids[n - 1])
    };
    let text = |lines: &[usize]| {
        let lines: Vec<String> = lines.iter().map(|&n| line(n)).collect();
        format!("--- 2026-10-29 周四 ---\n{}", lines.join("\n"))
    };

    // From a moment on, the first; and how to go on.
    let read = run(&context, json!({ "from": "2026-10-29 12:03", "limit": 2 }))
        .await
        .unwrap();
    assert_eq!(read["text"], text(&[3, 4]));
    let next = read["next"].clone();
    assert_eq!(
        next,
        json!({ "from": format!("#{}", ids[3] + 1), "limit": 2 })
    );
    let read = run(&context, next).await.unwrap();
    assert_eq!(read["text"], text(&[5, 6]));
    assert_eq!(read.get("next"), None);

    // With no start, the newest, in order; going on goes back.
    let read = run(&context, json!({ "who": "红", "limit": 2 }))
        .await
        .unwrap();
    assert_eq!(read["text"], text(&[4, 6]));
    let next = read["next"].clone();
    assert_eq!(
        next,
        json!({ "who": "红", "to": format!("#{}", ids[3]), "limit": 2 })
    );
    let read = run(&context, next).await.unwrap();
    assert_eq!(read["text"], text(&[2]));

    // A whole day, up to a row, or a moment before any row.
    let day = run(
        &context,
        json!({ "from": "2026-10-29", "to": "2026-10-29" }),
    )
    .await
    .unwrap();
    assert_eq!(day["text"], text(&[1, 2, 3, 4, 5, 6]));
    let upto = format!("#{}", ids[2]);
    let read = run(&context, json!({ "to": upto })).await.unwrap();
    assert_eq!(read["text"], text(&[1, 2]));
    let none = run(&context, json!({ "from": "2026-10-30" }))
        .await
        .unwrap();
    assert_eq!(none["text"], "（没有这样的消息）");

    for args in [
        json!({}),
        json!({ "limit": 3 }),
        json!({ "from": "10-29 12:00" }),
        json!({ "to": "#x" }),
        json!({ "summary": 1 }),
    ] {
        let wrong = run(&context, args).await;
        assert_eq!(wrong.unwrap_err().code, "bad_arguments");
    }
}
