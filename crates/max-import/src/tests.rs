//! The import of made-up old rows: tests/old_schema.sql and
//! tests/old_rows.sql, in a schema of their own next to the new tables.

use serde_json::{Value, json};
use sqlx::{Connection, PgPool};

use super::*;

const SCHEMA: &str = include_str!("tests/old_schema.sql");
const ROWS: &str = include_str!("tests/old_rows.sql");

fn accounts() -> Accounts {
    Accounts {
        bot_openid: "OPENID_BOT".into(),
        owner_qq: "20003".into(),
        owner_openid: "OPENID_OWNER".into(),
    }
}

/// The made-up rows, imported into the test's database.
async fn imported(pool: &PgPool) -> PgConnection {
    let mut tx = pool.begin().await.unwrap();
    for sql in [
        "create schema old; set local search_path = old",
        SCHEMA,
        ROWS,
    ] {
        sqlx::raw_sql(sql).execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();
    let from = (*pool.connect_options())
        .clone()
        .options([("search_path", "old")]);
    let mut old = PgConnection::connect_with(&from).await.unwrap();
    let mut new = PgConnection::connect_with(&pool.connect_options())
        .await
        .unwrap();
    import(&mut old, &mut new, &accounts()).await.unwrap();
    new
}

#[sqlx::test]
async fn people_and_places(pool: PgPool) {
    let mut new = imported(&pool).await;
    let people: Vec<(i64, String)> =
        sqlx::query_as("select id, display_name from principals order by id")
            .fetch_all(&mut new)
            .await
            .unwrap();
    // 小红 has no name but what she said something as.
    let names = [(1, "maxx"), (2, "小明"), (3, "小红红"), (4, "主人")];
    assert_eq!(people, names.map(|(id, name)| (id, name.to_owned())));

    let identities: Vec<(i64, i64, String, String)> = sqlx::query_as(
        "select id, principal_id, platform, native_user_id from identities order by id",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    let expected = [
        (11, 1, "qq_legacy", "20000"),
        (12, 2, "qq_legacy", "20001"),
        (13, 3, "qq_legacy", "20002"),
        (14, 4, "qq_legacy", "20003"),
        // After every old id.
        (16, 1, "qq", "OPENID_BOT"),
        (17, 4, "qq", "OPENID_OWNER"),
    ];
    let expected = expected
        .map(|(id, principal, platform, native)| (id, principal, platform.into(), native.into()));
    assert_eq!(identities, expected);

    let endpoints: Vec<(i64, i64, String, String, i64)> = sqlx::query_as(
        "select id, conversation_id, platform, native_id, self_identity_id from endpoints order by id",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    let expected = [
        (200, 100, "qq_legacy", "group:10001", 11),
        (201, 101, "qq_legacy", "private:20003", 11),
        (203, 102, "qq_legacy", "private:20001", 11),
        // The owner's old private chat goes on with the bot.
        (205, 101, "qq", "c2c:OPENID_OWNER", 16),
    ];
    let expected = expected.map(|(id, conversation, platform, native, me)| {
        (id, conversation, platform.into(), native.into(), me)
    });
    assert_eq!(endpoints, expected);

    let conversations: Vec<(i64, String, Option<String>)> =
        sqlx::query_as("select id, kind, title from conversations order by id")
            .fetch_all(&mut new)
            .await
            .unwrap();
    assert_eq!(
        conversations,
        [
            (100, "group".into(), Some("测试群".into())),
            (101, "direct".into(), None),
            (102, "direct".into(), None),
        ]
    );

    // Principal 6 had nothing and stayed behind; its id isn't reused.
    let next: i64 =
        sqlx::query_scalar("insert into principals (display_name) values ('新人') returning id")
            .fetch_one(&mut new)
            .await
            .unwrap();
    assert_eq!(next, 7);
}

type Message = (
    i64,
    i64,
    i64,
    String,
    Option<String>,
    Option<String>,
    String,
    Option<String>,
    Option<i64>,
    Option<i64>,
    String,
);

#[sqlx::test]
async fn messages(pool: PgPool) {
    let mut new = imported(&pool).await;
    let rows: Vec<Message> = sqlx::query_as(
        "select id, endpoint_id, sender_identity_id, sender_name, sender_role, native_id, kind,
                event, reply_to_id, target_id, text
         from messages order by id",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    let row = |id, endpoint, sender, name: &str, role: Option<&str>, native: Option<&str>| {
        (
            id,
            endpoint,
            sender,
            name.to_owned(),
            role.map(str::to_owned),
            native.map(str::to_owned),
        )
    };
    let some = |text: &str| Some(text.to_owned());
    let expected: Vec<Message> = [
        (
            row(1001, 200, 12, "明哥", Some("admin"), Some("n1001")),
            "chat",
            None,
            None,
            None,
            "大家好 [mention#3] @Max",
        ),
        (
            row(1002, 200, 11, "maxx", None, None),
            "chat",
            None,
            Some(1001),
            None,
            "[reply#1001] 你好",
        ),
        (
            row(1004, 200, 13, "小红红", None, Some("n1004")),
            "chat",
            None,
            None,
            None,
            "[face: 微笑][card: 哔哩哔哩 | 视频][语音]",
        ),
        (
            row(1005, 200, 12, "明哥", None, Some("n1005")),
            "command",
            None,
            None,
            None,
            "/status",
        ),
        // Max's answers to commands are chat.
        (
            row(1006, 200, 11, "maxx", None, None),
            "chat",
            None,
            None,
            None,
            "在跑",
        ),
        (
            row(1011, 200, 12, "明哥", None, Some("n1011")),
            "chat",
            None,
            None,
            None,
            "看这个[forward: 2 条] ⏎ 甲：第一句[image] ⏎ 乙：[forward: 1 条] ⏎   某人：里面",
        ),
        (
            row(1015, 200, 13, "某人", None, Some("n1015")),
            "event",
            some("unsend"),
            None,
            Some(1001),
            "[unsend#1001]",
        ),
        // Set once 1018 was in.
        (
            row(1017, 200, 12, "明哥", None, Some("n1017")),
            "chat",
            None,
            Some(1018),
            None,
            "[reply#1018] 对",
        ),
        (
            row(1018, 200, 13, "某人", None, Some("n1018")),
            "chat",
            None,
            None,
            None,
            "后来的",
        ),
        // The owner's private chat, its two endpoints one.
        (
            row(1019, 201, 14, "主人", None, Some("n1019")),
            "chat",
            None,
            None,
            None,
            "在吗",
        ),
        // What it replied to stayed behind.
        (
            row(1022, 200, 12, "明哥", None, Some("n1022")),
            "chat",
            None,
            None,
            None,
            "啥",
        ),
    ]
    .into_iter()
    .map(
        |((id, endpoint, sender, name, role, native), kind, event, reply_to, target, text)| {
            (
                id,
                endpoint,
                sender,
                name,
                role,
                native,
                kind.to_owned(),
                event,
                reply_to,
                target,
                text.to_owned(),
            )
        },
    )
    .collect();
    assert_eq!(rows, expected);

    let raw: Vec<(i64, Value)> =
        sqlx::query_as("select id, raw from messages where id in (1001, 1004, 1015) order by id")
            .fetch_all(&mut new)
            .await
            .unwrap();
    assert_eq!(raw[0].1["sender"]["role"], "admin");
    assert_eq!(raw[1].1, json!([]));
    assert_eq!(raw[2].1, json!({"recalled": "n1001"}));

    let next: i64 = sqlx::query_scalar(
        "insert into messages (conversation_id, endpoint_id, sender_identity_id, sender_name,
             sent_at, received_at, kind, nodes, raw, text)
         values (100, 200, 12, '小明', now(), now(), 'chat', '[]', '{}', '') returning id",
    )
    .fetch_one(&mut new)
    .await
    .unwrap();
    assert_eq!(next, 1023);
}

#[sqlx::test]
async fn only_into_an_empty_database(pool: PgPool) {
    let mut new = imported(&pool).await;
    let from = (*pool.connect_options())
        .clone()
        .options([("search_path", "old")]);
    let mut old = PgConnection::connect_with(&from).await.unwrap();
    let again = import(&mut old, &mut new, &accounts()).await;
    assert!(again.is_err());
}
