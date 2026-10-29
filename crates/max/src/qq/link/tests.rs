use max_core::message::Role;
use max_db::platform;
use sqlx::PgPool;
use tokio::sync::mpsc;

use super::*;
use crate::conversation::testing::{at, from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};
use crate::inbound::Person;
use crate::qq::avatar::testing::{Faces, face, serve};
use crate::scope::Scope;

/// `who` says something in `place` as `name`; what it was.
async fn says(pool: &PgPool, place: &Place, n: u32, who: &str, name: &str) -> Row {
    let mut said = from_xiaoming(n, vec![text("在")]);
    said.platform = place.platform;
    said.chat.native_id = place.native_id.clone();
    said.native_id = format!("{who}{n}");
    said.quote_id = None;
    said.sender = Person {
        native_user_id: who.into(),
        name: name.into(),
        role: Some(Role::Member),
    };
    let mut conn = pool.acquire().await.unwrap();
    let committed = ingest::inbound(&mut conn, place, &said, at(n), offset())
        .await
        .unwrap();
    Row {
        place: Arc::new(place.clone()),
        message: Arc::new(committed.message),
    }
}

/// The old group the test group goes on from.
async fn old_group(pool: &PgPool, place: &Place) -> Place {
    let mut conn = pool.acquire().await.unwrap();
    let old_me = platform::account(&mut conn, Platform::QqLegacy, "10000", "Max")
        .await
        .unwrap();
    let native_id = "group:OLD1";
    let kind = ConversationKind::Group;
    let endpoint = platform::attach(
        &mut conn,
        Some(place.conversation),
        Platform::QqLegacy,
        native_id,
        old_me.identity,
        kind,
    )
    .await
    .unwrap();
    Place {
        conversation: endpoint.conversation,
        kind,
        endpoint: endpoint.id,
        platform: Platform::QqLegacy,
        native_id: native_id.into(),
        me: old_me,
        my_name: "Max".into(),
    }
}

/// Each account checked: what came of it, and the number it showed.
async fn outcomes(pool: &PgPool) -> Vec<(String, String, Option<String>)> {
    sqlx::query_as(
        "select i.native_user_id, c.outcome, n.native_user_id
         from avatar_checks c
         join identities i on i.id = c.identity_id
         left join identities n on n.id = c.number_id
         order by i.native_user_id",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

/// Each QQ account merged into someone, and that one's old number.
async fn merged(pool: &PgPool) -> Vec<(String, String)> {
    sqlx::query_as(
        "select i.native_user_id, n.native_user_id
         from identities i
         join principals p on p.id = i.principal_id
         join identities n on n.principal_id = p.merged_into and n.platform = 'qq_legacy'
         where i.platform = 'qq'
         order by i.native_user_id",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

fn owned<const N: usize>(
    rows: [(&str, &str, Option<&str>); N],
) -> Vec<(String, String, Option<String>)> {
    rows.into_iter()
        .map(|(a, b, c)| (a.to_owned(), b.to_owned(), c.map(str::to_owned)))
        .collect()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn accounts_are_linked_to_the_one_number_they_show(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    // 小明 owns Max; 30000 was his old number.
    let xiaoming = platform::account(&mut conn, Platform::Qq, "XIAOMING", "小明")
        .await
        .unwrap();
    sqlx::query(
        "insert into identities (principal_id, platform, native_user_id)
         values ($1, 'qq_legacy', '30000')",
    )
    .bind(xiaoming.principal.0)
    .execute(&mut *conn)
    .await
    .unwrap();
    drop(conn);
    let old = old_group(&pool, &place).await;
    let numbers = [
        ("20001", "老红"),
        ("20002", "老王"),
        ("20004", "老赵"),
        ("20005", "老钱"),
        ("20006", "老孙"),
        ("30000", "老明"),
    ];
    for (n, (number, name)) in (0..).zip(numbers) {
        says(&pool, &old, n, number, name).await;
    }
    let accounts = [
        ("XIAOMING", "小明"),
        ("XIAOHONG", "小红"),
        ("XIAOGANG", "小刚"),
        ("XIAOLI", "小李"),
        ("XIAOZHAO", "小赵"),
        ("XIAOQIAN", "小钱"),
        ("XIAOSUN", "小孙"),
        ("XIAOWU", "小吴"),
        ("XIAOZHOU", "小周"),
    ];
    for (n, (openid, name)) in (10..).zip(accounts) {
        says(&pool, &place, n, openid, name).await;
    }
    let faces = [
        // What QQ shows for an openid that is no one's.
        ("/openid/0", face(2, 640)),
        ("/number/20001", face(0, 100)),
        ("/number/20002", face(1, 100)),
        // 老赵 and 老钱 had one picture, and 老孙 none.
        ("/number/20004", face(3, 100)),
        ("/number/20005", face(3, 100)),
        ("/number/20006", face(2, 100)),
        ("/number/30000", face(4, 100)),
        ("/openid/XIAOHONG", face(0, 640)),
        // 小刚 put 老王's picture up, and 小李 is 老王.
        ("/openid/XIAOGANG", face(1, 640)),
        ("/openid/XIAOLI", face(1, 640)),
        ("/openid/XIAOZHAO", face(3, 640)),
        // 小钱 put the owner's up.
        ("/openid/XIAOQIAN", face(4, 640)),
        ("/openid/XIAOSUN", face(2, 640)),
        ("/openid/XIAOWU", face(5, 640)),
        ("/openid/XIAOFENG", face(0, 640)),
        // 小周's can't be fetched, and neither can the old Max's.
    ];
    let faces: Faces = faces
        .into_iter()
        .map(|(path, bytes)| (path.to_owned(), bytes))
        .collect();
    let mut scope = Scope::new();
    let avatars = Arc::new(serve(faces, &mut scope).await);
    let linker = || Linker {
        pool: pool.clone(),
        avatars: Arc::clone(&avatars),
        barred: BTreeSet::from([xiaoming.principal]),
    };

    let failed = linker().sweep(place.conversation).await.unwrap();
    assert_eq!(failed.len(), 1, "小周's");
    let checked = [
        ("XIAOGANG", "taken", Some("20002")),
        ("XIAOHONG", "linked", Some("20001")),
        ("XIAOLI", "taken", Some("20002")),
        ("XIAOQIAN", "barred", Some("30000")),
        ("XIAOSUN", "default", None),
        ("XIAOWU", "none", None),
        ("XIAOZHAO", "ambiguous", None),
    ];
    assert_eq!(outcomes(&pool).await, owned(checked));
    let linked = vec![("XIAOHONG".to_owned(), "20001".to_owned())];
    assert_eq!(merged(&pool).await, linked);
    let prints: i64 = sqlx::query_scalar("select count(*) from legacy_avatars")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(prints, 6, "all but the old Max's");

    // The worker: what is left at the start, then each account when it
    // first speaks. 小冯 shows a number 小红 is linked to there already.
    let (rows, inbox) = mpsc::unbounded_channel();
    let stop = CancellationToken::new();
    let worker = linker().run(inbox, stop.clone());
    let test = async {
        rows.send(says(&pool, &place, 20, "XIAOFENG", "小冯").await)
            .unwrap();
        for _ in 0..100 {
            if outcomes(&pool).await.len() == 8 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        stop.cancel();
    };
    tokio::join!(worker, test);
    let mut checked = owned(checked);
    checked.insert(0, ("XIAOFENG".into(), "taken".into(), Some("20001".into())));
    assert_eq!(outcomes(&pool).await, checked);
    assert_eq!(merged(&pool).await, linked);
    scope.close(Duration::from_secs(5)).await;
}
