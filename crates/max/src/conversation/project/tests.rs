use max_core::message::{Draft, DraftNode};
use max_db::PgPool;
use max_db::ledger::Sent;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{at, from_xiaohong, from_xiaoming, group, offset, text};
use crate::inbound::{InNode, Quote};

fn direct(id: MessageId) -> Wake {
    Wake {
        ids: vec![id],
        reason: Reason::Direct,
        item: None,
    }
}

fn user_text(item: &Item) -> &str {
    match &item.kind {
        ItemKind::User { text, .. } | ItemKind::System { text } => text,
        other => panic!("{other:?}"),
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_core_sees_the_tail_and_its_trigger(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let morning = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(0, vec![text("早")]),
        at(0),
        offset(),
    )
    .await
    .unwrap();
    let a = morning.message.id;
    let reply = Draft {
        reply_to: Some(a),
        nodes: vec![DraftNode::Text {
            text: "早啊".into(),
        }],
    };
    let mine = ingest::said(&mut conn, &place, reply, None, None, at(1), offset())
        .await
        .unwrap();
    let failed = Sent::Failed { error: "500" };
    ledger::record_delivery(&mut conn, mine.id, place.endpoint, &failed, at(1))
        .await
        .unwrap();
    let mut ask = from_xiaohong(
        2,
        vec![
            InNode::MentionMe {
                display: "maxx".into(),
            },
            text("帮我看看这个"),
        ],
    );
    ask.quote = Some(Quote {
        quote_id: Some("IDX0".into()),
        text: None,
    });
    let ask = ingest::inbound(&mut conn, &place, &ask, at(2), offset())
        .await
        .unwrap();
    let later = from_xiaoming(3, vec![text("我也想知道")]);
    let later = ingest::inbound(&mut conn, &place, &later, at(3), offset())
        .await
        .unwrap();

    let (max, xiaoming, xiaohong) = (
        place.me.principal,
        morning.sender.principal,
        ask.sender.principal,
    );
    let (b, c, d) = (mine.id, ask.message.id, later.message.id);
    let mut projection = Projection {
        place: &place,
        system: "SYSTEM".into(),
        window: 100_000,
        cleared_upto: None,
        now: at(5),
        offset: offset(),
    };
    let first = [direct(c)];
    let (context, inputs) = projection.base(&mut conn, d, &first).await.unwrap();
    assert_eq!(inputs, [Input::Wake(direct(c))]);
    assert_eq!(context.roster, BTreeSet::from([max, xiaoming, xiaohong]));
    let texts: Vec<&str> = context.items.iter().map(user_text).collect();
    assert_eq!(
        texts,
        [
            "SYSTEM",
            &*format!(
                "--- 2026-10-29 周四 ---\n\
                 [12:00 小明 #{a}]: 早\n\
                 [12:01 maxx #{b}]: [reply#{a}] 早啊（没发出去）\n\
                 [12:03 小明 #{d}]: 我也想知道\n"
            ),
            &*format!(
                "[现在] 2026-10-29 周四 12:05\n\
                 \n[上下文里的人]\n\
                 [mention#{max}] maxx（你）\n\
                 [mention#{xiaoming}] 小明\n\
                 [mention#{xiaohong}] 小红（管理员）\n\
                 \n[新消息]\n\
                 [12:02 小红 #{c} @你]: [reply#{a}] [mention#{max}]帮我看看这个\n"
            ),
        ]
    );

    // Cleared up to the first row: it is quoted, not in the tail.
    projection.cleared_upto = Some(a);
    let (context, _) = projection.base(&mut conn, d, &first).await.unwrap();
    let volatile = user_text(context.items.last().unwrap());
    let quoted = format!("[引用的消息]\n--- 2026-10-29 周四 ---\n[12:00 小明 #{a}]: 早\n");
    assert!(volatile.contains(&quoted), "{volatile}");
    assert!(!user_text(&context.items[1]).contains("早\n"));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_judged_wake(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let said = from_xiaoming(0, vec![text("rust 的生命周期怎么理解")]);
    let said = ingest::inbound(&mut conn, &place, &said, at(0), offset())
        .await
        .unwrap();
    let id = said.message.id;
    let reason = Reason::Judged {
        note: "在问 Rust".into(),
    };
    let wake = Wake {
        ids: vec![id],
        item: judged(&reason),
        reason,
    };
    let projection = Projection {
        place: &place,
        system: "SYSTEM".into(),
        window: 100_000,
        cleared_upto: None,
        now: at(1),
        offset: offset(),
    };
    let (context, _) = projection.base(&mut conn, id, &[wake]).await.unwrap();
    // Nothing but the trigger, so no tail.
    assert_eq!(context.items.len(), 2);
    let volatile = user_text(&context.items[1]);
    let expected = format!(
        "[新消息]\n\
         --- 2026-10-29 周四 ---\n\
         [12:00 小明 #{id}]: rust 的生命周期怎么理解\n\
         [判定：在问 Rust]\n"
    );
    assert!(volatile.ends_with(&expected), "{volatile}");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn later_rows_introduce_new_people(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let first = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(0, vec![text("a")]),
        at(0),
        offset(),
    )
    .await
    .unwrap();
    let second = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaohong(
            1,
            vec![
                InNode::MentionMe {
                    display: "maxx".into(),
                },
                text("b"),
            ],
        ),
        at(1),
        offset(),
    )
    .await
    .unwrap();
    let seen = BTreeSet::from([place.me.principal, first.sender.principal]);
    let rows = [
        (first.message.clone(), Mark::None),
        (second.message.clone(), Mark::MentionsYou),
    ];
    let input = follow_up(
        &mut conn,
        &place,
        &rows,
        &seen,
        Some(at(0)),
        100_000,
        offset(),
    )
    .await
    .unwrap();
    let xiaohong = second.sender.principal;
    let (a, b, max) = (first.message.id, second.message.id, place.me.principal);
    let Input::Messages { ids, item, people } = input else {
        panic!("{input:?}");
    };
    assert_eq!(ids, [a, b]);
    assert_eq!(people, [xiaohong]);
    assert_eq!(
        user_text(&item),
        format!(
            "[上下文里的人] [mention#{xiaohong}] 小红（管理员）\n\
             [12:00 小明 #{a}]: a\n\
             [12:01 小红 #{b} @你]: [mention#{max}]b"
        )
    );
    assert!(item.tokens > 0);
}
