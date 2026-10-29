//! The import of made-up old rows: tests/old_schema.sql and
//! tests/old_rows.sql, in a schema of their own next to the new tables.

use std::path::PathBuf;

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

/// A white pixel.
const PNG: &[u8] = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90\x77\x53\xde\x00\x00\x00\x0c\x49\x44\x41\x54\x78\x9c\x63\xf8\xff\xff\x3f\x00\x05\xfe\x02\xfe\x0d\xef\x46\xb8\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

/// The made-up files, by the letter their SHA-256 repeats.
fn files() -> Vec<(char, &'static [u8])> {
    vec![
        ('a', b"a"),
        ('b', b"b"),
        ('c', b"c"),
        ('d', b"d"),
        ('e', PNG),
    ]
}

/// The made-up rows in a schema of their own, and `files` in a content
/// store of the test's own; connections to read the one and write the
/// other.
async fn setup(pool: &PgPool, files: &[(char, &[u8])]) -> (PgConnection, PgConnection, PathBuf) {
    let mut tx = pool.begin().await.unwrap();
    for sql in [
        "create schema old; set local search_path = old",
        SCHEMA,
        ROWS,
    ] {
        sqlx::raw_sql(sql).execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();
    let database = pool
        .connect_options()
        .get_database()
        .unwrap_or("max")
        .to_owned();
    let store = std::env::temp_dir().join(format!("max-import-{database}"));
    for (letter, bytes) in files {
        let sha256 = letter.to_string().repeat(64);
        let dir = store.join("objects").join(&sha256[..2]);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(&sha256), bytes).unwrap();
    }
    let from = (*pool.connect_options())
        .clone()
        .options([("search_path", "old")]);
    let old = PgConnection::connect_with(&from).await.unwrap();
    let new = PgConnection::connect_with(&pool.connect_options())
        .await
        .unwrap();
    (old, new, store)
}

/// The made-up rows, imported into the test's database.
async fn imported(pool: &PgPool) -> PgConnection {
    let (mut old, mut new, store) = setup(pool, &files()).await;
    import(&mut old, &mut new, &store, &accounts())
        .await
        .unwrap();
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
    // 小红 has no name but the one 小红's messages carry.
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
        (
            row(1021, 200, 12, "明哥", None, Some("n1021")),
            "chat",
            None,
            None,
            None,
            "图[image][video][file: d.zip][image]",
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

type Summary = (
    i64,
    i64,
    i64,
    i64,
    String,
    i16,
    String,
    Option<String>,
    String,
);

type Setting = (
    i64,
    Option<String>,
    Option<String>,
    Option<String>,
    bool,
    Option<i64>,
);

#[sqlx::test]
async fn summaries_and_settings(pool: PgPool) {
    let mut new = imported(&pool).await;
    let summaries: Vec<Summary> = sqlx::query_as(
        "select id, conversation_id, first_message_id, last_message_id, kind, importance, p1, p2,
                model
         from summaries order by id",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    let expected = [
        (
            1,
            100,
            1001,
            1006,
            "social",
            51,
            "[mention#2] 打招呼",
            Some("打招呼"),
            "gemini",
        ),
        (
            3,
            100,
            1011,
            1022,
            "mixed",
            100,
            "[mention#2] 转发了聊天记录",
            None,
            "qwen",
        ),
    ]
    .map(
        |(id, conversation, first, last, kind, importance, p1, p2, model)| {
            (
                id,
                conversation,
                first,
                last,
                kind.to_owned(),
                importance,
                p1.to_owned(),
                p2.map(str::to_owned),
                model.to_owned(),
            )
        },
    );
    assert_eq!(summaries, expected);
    let times: (String, String) =
        sqlx::query_as("select started_at::text, created_at::text from summaries where id = 1")
            .fetch_one(&mut new)
            .await
            .unwrap();
    assert_eq!(
        times,
        (
            "2026-01-02 02:00:00+00".into(),
            "2026-01-02 16:01:00+00".into()
        )
    );

    let settings: Vec<Setting> = sqlx::query_as(
        "select conversation_id, model, effort, persona, proactive, cleared_upto
             from conversation_settings order by conversation_id",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    assert_eq!(
        settings,
        [
            (100, None, None, Some("猫".into()), false, Some(1004)),
            (101, None, None, None, true, None),
        ]
    );
}

#[sqlx::test]
async fn media(pool: PgPool) {
    let mut new = imported(&pool).await;
    let media: Vec<(String, Option<String>, i64, String)> =
        sqlx::query_as("select sha256, mime, size, first_seen_at::text from media order by sha256")
            .fetch_all(&mut new)
            .await
            .unwrap();
    let file = |letter: char, mime: &str, size, at: &str| {
        (
            letter.to_string().repeat(64),
            Some(mime.to_owned()),
            size,
            at.to_owned(),
        )
    };
    assert_eq!(
        media,
        [
            file('a', "image/jpeg", 10, "2025-12-30 16:00:00+00"),
            file('b', "video/mp4", 12, "2025-12-30 16:00:00+00"),
            file('c', "image/jpeg", 11, "2025-12-30 16:00:00+00"),
            file('d', "application/zip", 13, "2026-01-02 02:09:00+00"),
            // Only its node and the store know it.
            file('e', "image/png", 69, "2026-01-02 02:09:00+00"),
        ]
    );
    let links: Vec<(i64, i16, String)> = sqlx::query_as(
        "select message_id, ordinal, left(sha256, 1) from message_media order by 1, 2",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    let expected = [
        (1011, 0, "a"),
        (1021, 0, "c"),
        (1021, 1, "b"),
        (1021, 2, "d"),
        (1021, 3, "e"),
    ]
    .map(|(id, ordinal, letter)| (id, ordinal, letter.to_owned()));
    // The forwarded picture is the container's.
    assert_eq!(links, expected);
}

#[sqlx::test]
async fn the_models_copies_of_pictures(pool: PgPool) {
    let (mut old, mut new, store) = setup(&pool, &files()).await;
    import(&mut old, &mut new, &store, &accounts())
        .await
        .unwrap();
    pictures::run(&mut new, &store).await.unwrap();
    let pictures: Vec<(String, Option<i32>, Option<String>)> = sqlx::query_as(
        "select left(sha256, 1), width, left(model_sha256, 1) from media order by sha256",
    )
    .fetch_all(&mut new)
    .await
    .unwrap();
    // The pixel is small enough as it is; "a" and "c" only say they are
    // pictures, and videos and files aren't looked at.
    let expected = [
        ("a", None, None),
        ("b", None, None),
        ("c", None, None),
        ("d", None, None),
        ("e", Some(1), Some("e")),
    ]
    .map(|(sha256, width, model)| (sha256.to_owned(), width, model.map(str::to_owned)));
    assert_eq!(pictures, expected);
}

#[sqlx::test]
async fn every_file_has_to_be_in_the_store(pool: PgPool) {
    let mut files = files();
    files.retain(|(letter, _)| *letter != 'e');
    let (mut old, mut new, store) = setup(&pool, &files).await;
    let error = import(&mut old, &mut new, &store, &accounts())
        .await
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("1 files aren't in the content store"),
        "{error}"
    );
}

#[sqlx::test]
async fn only_into_an_empty_database(pool: PgPool) {
    let (mut old, mut new, store) = setup(&pool, &files()).await;
    import(&mut old, &mut new, &store, &accounts())
        .await
        .unwrap();
    let again = import(&mut old, &mut new, &store, &accounts()).await;
    assert!(again.is_err());
}

#[sqlx::test]
async fn captions_after(pool: PgPool) {
    let (mut old, mut new, store) = setup(&pool, &files()).await;
    import(&mut old, &mut new, &store, &accounts())
        .await
        .unwrap();
    captions::import(&mut old, &mut new).await.unwrap();
    let written = "select left(sha256, 1), kind, text, skip, model is null
                   from media_captions order by sha256";
    let captions: Vec<(String, String, String, bool, bool)> =
        sqlx::query_as(written).fetch_all(&mut new).await.unwrap();
    let caption = |letter: &str, kind: &str, text: &str, skip| {
        (letter.into(), kind.into(), text.into(), skip, true)
    };
    // c's sticker caption wins; its blank picture caption is none anyway.
    let expected = vec![
        caption("a", "image", "一只猫 趴着", false),
        caption("c", "sticker", "翻白眼的猫，表示无语", false),
        caption("e", "sticker", "", true),
    ];
    assert_eq!(captions, expected);

    // Again: what's there stays.
    sqlx::raw_sql("update old.images set description = '两只猫'")
        .execute(&pool)
        .await
        .unwrap();
    captions::import(&mut old, &mut new).await.unwrap();
    let again: Vec<(String, String, String, bool, bool)> =
        sqlx::query_as(written).fetch_all(&mut new).await.unwrap();
    assert_eq!(again, expected);
}
