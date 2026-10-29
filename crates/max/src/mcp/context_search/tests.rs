use std::sync::Arc;

use chrono::TimeDelta;
use max_core::message::{MediaKind, MediaMeta, MediaRef, Node};
use max_db::captions::{self, Caption};
use max_db::media::{self, Blob};
use max_db::platform;
use max_db::summaries::{self as stored, Summary};
use max_db::vectors::{self, Key};
use sqlx::{PgConnection, PgPool};

use super::*;
use crate::conversation::testing::{at, from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};
use crate::embedding::testing::{serve, vector};
use crate::inbound::InNode;
use crate::scope::Scope;

fn hit(kind: Kind, n: i64, score: f32, key: &str) -> Hit {
    Hit {
        kind,
        handle: format!("{n}"),
        time: String::new(),
        text: String::new(),
        read: Value::Null,
        score,
        at: at(0) + TimeDelta::minutes(n),
        key: key.into(),
    }
}

fn handles(hits: &[Hit]) -> Vec<&str> {
    hits.iter().map(|hit| hit.handle.as_str()).collect()
}

#[test]
fn terms_are_words_between_spaces_lowercased_once() {
    assert_eq!(
        terms(" GitHub  部署\u{3000}github 方案 ").unwrap(),
        ["github", "部署", "方案"]
    );
    assert_eq!(terms("  ").unwrap_err().code, "bad_arguments");
    assert!(terms("一 二 三 四 五 六 七 八").is_ok());
    assert_eq!(
        terms("一 二 三 四 五 六 七 八 九").unwrap_err().code,
        "bad_arguments"
    );
    assert_eq!(terms(&"长".repeat(51)).unwrap_err().code, "bad_arguments");
    assert_eq!(pattern(r"100%_a\b"), r"%100\%\_a\\b%");
}

#[test]
fn snippets_center_on_the_first_hit() {
    assert_eq!(snippet("短的一句", &["一"]), "短的一句");
    let long = format!("{}Deploy 了{}", "前".repeat(100), "后".repeat(300));
    let cut = snippet(&long, &["后后", "deploy"]);
    assert!(
        cut.starts_with(&format!("…{}Deploy 了", "前".repeat(40))),
        "{cut}"
    );
    assert!(cut.ends_with('…'));
    assert_eq!(cut.chars().count(), SNIPPET + 2);
    // A hit at the start, or none, shows the start; one at the end, the end.
    let start = snippet(&long, &["前前"]);
    assert!(start.starts_with("前前") && start.ends_with('…'));
    assert_eq!(snippet(&long, &["没有"]), start);
    let last = format!("{}末尾", "前".repeat(300));
    let end = snippet(&last, &["末尾"]);
    assert!(end.starts_with('…') && end.ends_with("末尾"), "{end}");
}

#[test]
fn dates_are_whole_local_days() {
    let (from, until) = window(Some("2026-10-03"), Some("2026-10-04"), offset()).unwrap();
    assert_eq!(from.unwrap().to_rfc3339(), "2026-10-02T16:00:00+00:00");
    assert_eq!(until.unwrap().to_rfc3339(), "2026-10-04T16:00:00+00:00");
    assert_eq!(window(None, None, offset()).unwrap(), (None, None));
    for (from, to) in [
        (Some("10-03"), None),
        (Some("2026-10-05"), Some("2026-10-04")),
    ] {
        assert_eq!(
            window(from, to, offset()).unwrap_err().code,
            "bad_arguments"
        );
    }
}

#[test]
fn no_kind_takes_more_than_two_thirds_while_another_has_hits() {
    let messages = (0..5).map(|n| hit(Kind::Message, n, 1.0, &n.to_string()));
    let mut hits: Vec<Hit> = messages.collect();
    hits.push(hit(Kind::Summary, 10, 0.5, "s10"));
    hits.push(hit(Kind::Summary, 11, 0.5, "s11"));
    assert_eq!(handles(&choose(hits, 3)), ["4", "3", "11"]);

    // With nothing else, one kind fills them all.
    let hits = (0..5).map(|n| hit(Kind::Message, n, 1.0, &n.to_string()));
    assert_eq!(handles(&choose(hits.collect(), 3)), ["4", "3", "2"]);

    // A message said again is one result: the best of them.
    let hits = vec![
        hit(Kind::Message, 1, 0.5, "哈哈"),
        hit(Kind::Message, 2, 1.0, "部署"),
        hit(Kind::Message, 3, 0.5, "哈哈"),
    ];
    assert_eq!(handles(&choose(hits, 10)), ["2", "3"]);
}

#[test]
fn found_both_ways_a_candidate_takes_the_higher_score() {
    let terms = ["上线".to_owned(), "时间".to_owned()];
    let words = vec![(1, vec![0]), (2, vec![0, 1])];
    let near = vec![(1, 0.8), (2, 0.9), (3, 0.6), (4, 0.4)];
    let found = merged(words, near, &terms);
    let mut scores: Vec<(i32, f32)> = found.iter().map(|(id, found)| (*id, found.score)).collect();
    scores.sort_by_key(|(id, _)| *id);
    // 4 isn't near enough.
    assert_eq!(scores, [(1, 0.8), (2, 1.0), (3, 0.6)]);
    assert_eq!(found[&2].has, [0, 1]);
    assert!(found[&3].has.is_empty());
}

/// A picture from 小明, with the caption worker's words for it.
async fn picture(conn: &mut PgConnection, place: &Place, n: u32, caption: &str) -> i64 {
    let node = InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://example.com/p".into())),
        meta: MediaMeta {
            kind: MediaKind::Image,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    });
    let inbound = from_xiaoming(n, vec![node]);
    let row = ingest::inbound(conn, place, &inbound, at(n), offset())
        .await
        .unwrap()
        .message
        .id;
    let sha256 = "e".repeat(64);
    let blob = Blob {
        sha256: sha256.clone(),
        mime: Some("image/png".into()),
        size: 3,
        width: None,
        height: None,
        model_sha256: Some(sha256.clone()),
    };
    media::record(conn, row, 0, &blob, at(n)).await.unwrap();
    let caption = Caption {
        sha256: &sha256,
        kind: captions::Kind::Image,
        text: caption,
        skip: false,
        model: None,
        at: at(n),
    };
    captions::write(conn, &caption).await.unwrap();
    row.0
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn rows_and_summaries_with_their_read(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let mut said = async |n: u32, words: &str| {
        let inbound = from_xiaoming(n, vec![text(words)]);
        ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap()
            .message
            .id
            .0
    };
    let early = said(1, "部署方案还没定").await;
    let chat = said(2, "中午吃什么").await;
    let again = said(3, "部署方案还没定").await;
    let script = format!(
        "{}GitHub 上的部署脚本{}",
        "啊".repeat(200),
        "吧".repeat(200)
    );
    let long = said(4, &script).await;
    let screenshot = picture(&mut conn, &place, 6, "服务器报错的截图").await;
    let summary = Summary {
        first: MessageId(early),
        last: MessageId(chat),
        started_at: at(1),
        ended_at: at(2),
        title: "部署".into(),
        kind: "decision".into(),
        importance: 50,
        full: "大家讨论了部署方案。".into(),
        brief: None,
        line: None,
    };
    let summary = stored::insert(&mut conn, place.conversation, &summary, "m", at(9))
        .await
        .unwrap();
    drop(conn);
    let context = Context {
        pool: pool.clone(),
        place: Arc::clone(&place),
        offset: offset(),
        page_tokens: 2000,
        search: None,
        work: None,
        store: None,
        poster: None,
        embedder: None,
        admin: None,
    };

    let found = run(&context, json!({ "query": "部署 方案" }))
        .await
        .unwrap();
    let results = found["results"].as_array().unwrap();
    // The message said twice shows once, the later; then the summary,
    // which is newer than the first; then the script, with one term.
    assert_eq!(
        results[0],
        json!({
            "kind": "message",
            "ref": format!("#{again}"),
            "time": "2026-10-29 周四 12:03",
            "text": "小明：部署方案还没定",
            "read": { "id": again, "before": 10, "after": 10 },
        })
    );
    assert_eq!(
        results[1],
        json!({
            "kind": "summary",
            "ref": format!("summary#{summary}"),
            "time": "2026-10-29 周四 12:01–12:02",
            "text": "部署：大家讨论了部署方案。",
            "read": { "summary": summary.0 },
        })
    );
    assert_eq!(results[2]["ref"], format!("#{long}"));
    let text = results[2]["text"].as_str().unwrap();
    assert!(
        text.starts_with("小明：…啊") && text.contains("GitHub 上的部署脚本"),
        "{text}"
    );
    assert_eq!(results.len(), 3);

    // A picture by its caption, as the row shows it.
    let found = run(&context, json!({ "query": "服务器" })).await.unwrap();
    assert_eq!(
        found["results"][0]["text"],
        format!("小明：[image#{screenshot}.0: 服务器报错的截图]")
    );
    // From the day after, nothing.
    let later = run(&context, json!({ "query": "部署", "from": "2026-10-30" })).await;
    assert_eq!(later.unwrap()["results"], json!([]));
    let one = run(&context, json!({ "query": "部署", "limit": 1 })).await;
    assert_eq!(one.unwrap()["results"].as_array().unwrap().len(), 1);

    // /clear --all hides rows from the context, not from a search.
    let refs = async || -> Vec<Value> {
        let found = run(&context, json!({ "query": "部署" })).await.unwrap();
        let results = found["results"].as_array().unwrap().iter();
        results.map(|result| result["ref"].clone()).collect()
    };
    let before = refs().await;
    assert_eq!(before.len(), 3);
    let mut conn = pool.acquire().await.unwrap();
    let mut settings = platform::settings(&mut conn, place.conversation)
        .await
        .unwrap();
    settings.cleared_upto = Some(MessageId(again));
    platform::save_settings(&mut conn, place.conversation, &settings, at(9))
        .await
        .unwrap();
    drop(conn);
    assert_eq!(refs().await, before);

    let empty = super::super::call("context_search", &context, json!({ "query": " " })).await;
    assert_eq!(empty.unwrap_err().code, "bad_arguments");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn by_meaning_too(pool: PgPool) {
    let mut scope = Scope::new();
    let (embedder, _) = serve(&mut scope).await;
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let mut said = async |n: u32, words: &str| {
        let inbound = from_xiaoming(n, vec![text(words)]);
        let id = ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap()
            .message
            .id;
        // The vector the worker would make of it.
        let made = [(Key::Message(id), place.conversation, vector(words))];
        vectors::write(&mut conn, "test-m3", &made, at(n))
            .await
            .unwrap();
        id
    };
    said(1, "时间上线了吗").await;
    said(2, "中午吃什么").await;
    said(3, "上线时间定了").await;
    drop(conn);
    let context = Context {
        pool: pool.clone(),
        place: Arc::clone(&place),
        offset: offset(),
        page_tokens: 2000,
        search: None,
        work: None,
        store: None,
        poster: None,
        embedder: Some(embedder),
        admin: None,
    };
    let texts = async |query: &str| -> Vec<Value> {
        let found = run(&context, json!({ "query": query })).await.unwrap();
        let results = found["results"].as_array().unwrap().iter();
        results.map(|result| result["text"].clone()).collect()
    };

    // The words found one; the meaning another, nearly as good, and not
    // what has nothing to do with it.
    assert_eq!(
        texts("上线时间").await,
        [json!("小明：上线时间定了"), json!("小明：时间上线了吗")]
    );
    // Without the query's vector, the words alone.
    assert_eq!(texts("上线时间 挂").await, [json!("小明：上线时间定了")]);
    scope.close(Duration::ZERO).await;
}
