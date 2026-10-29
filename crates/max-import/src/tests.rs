//! The import of made-up old rows: tests/old_schema.sql and
//! tests/old_rows.sql, in a schema of their own next to the new tables.

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
    let names = [(1, "maxx"), (2, "小明"), (3, "某人"), (4, "主人")];
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
