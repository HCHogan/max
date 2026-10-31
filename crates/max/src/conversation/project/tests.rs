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
        .unwrap()
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
        historian: false,
        memory: String::new(),
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
async fn the_tail_is_cut_at_a_mark_that_stays(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let mut ids = Vec::new();
    for n in 0..12 {
        let said = format!("第{n}条：{}", "字".repeat(40));
        // Only 小红's row is cut, and she isn't in the roster.
        let said = if n == 0 {
            from_xiaohong(n, vec![text(&said)])
        } else {
            from_xiaoming(n, vec![text(&said)])
        };
        let said = ingest::inbound(&mut conn, &place, &said, at(n), offset())
            .await
            .unwrap();
        ids.push(said.message.id);
    }
    let last = *ids.last().unwrap();
    // A tail of at most 100 tokens, cut back to 50 or a little more.
    let projection = Projection {
        place: &place,
        system: "SYSTEM".into(),
        window: 800,
        cleared_upto: None,
        historian: false,
        memory: String::new(),
        now: at(20),
        offset: offset(),
    };
    let (context, _) = projection.base(&mut conn, last, &[]).await.unwrap();
    let mark = platform::tail_after(&mut conn, place.conversation)
        .await
        .unwrap()
        .expect("the tail was cut");
    let cut = ids.iter().position(|id| *id == mark).unwrap();
    assert!(cut < ids.len() - 1);
    let tail = user_text(&context.items[1]).to_owned();
    assert!(!tail.contains(&format!("#{mark}]")), "{tail}");
    assert!(tail.contains(&format!("#{}]", ids[cut + 1])), "{tail}");
    assert!(tail.contains(&format!("#{last}]")), "{tail}");
    let volatile = user_text(context.items.last().unwrap());
    assert!(!volatile.contains("小红"), "{volatile}");

    // The next core starts at the mark.
    let (context, _) = projection.base(&mut conn, last, &[]).await.unwrap();
    assert_eq!(user_text(&context.items[1]), tail);
    let again = platform::tail_after(&mut conn, place.conversation)
        .await
        .unwrap();
    assert_eq!(again, Some(mark));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn where_the_historian_is_on_the_tail_starts_after_its_summaries(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let mut ids = Vec::new();
    let mut xiaohong = None;
    for n in 0..6 {
        let said = if n == 0 {
            from_xiaohong(n, vec![text("示波器探头怎么补偿")])
        } else {
            from_xiaoming(n, vec![text(&format!("第{n}条"))])
        };
        let said = ingest::inbound(&mut conn, &place, &said, at(n), offset())
            .await
            .unwrap();
        xiaohong.get_or_insert(said.sender.principal);
        ids.push(said.message.id);
    }
    let xiaohong = xiaohong.unwrap();
    let summary = summaries::Summary {
        first: ids[0],
        last: ids[2],
        started_at: at(0),
        ended_at: at(2),
        title: "探头补偿".into(),
        kind: "support".into(),
        importance: 40,
        full: format!("[mention#{xiaohong}] 问探头补偿。"),
        brief: None,
        line: None,
    };
    let id = summaries::insert(&mut conn, place.conversation, &summary, "m", at(3))
        .await
        .unwrap();
    let mut projection = Projection {
        place: &place,
        system: "SYSTEM".into(),
        window: 100_000,
        cleared_upto: None,
        historian: true,
        memory: String::new(),
        now: at(10),
        offset: offset(),
    };
    let last = *ids.last().unwrap();
    let (context, _) = projection.base(&mut conn, last, &[]).await.unwrap();
    let texts: Vec<&str> = context.items.iter().map(user_text).collect();
    assert_eq!(texts.len(), 4, "{texts:?}");
    assert_eq!(
        texts[1],
        format!(
            "[早先的聊天，摘要]\n\
             [summary#{id} 2026-10-29 周四 12:00–12:02] 探头补偿\n\
             [mention#{xiaohong}] 问探头补偿。\n"
        )
    );
    assert!(!texts[2].contains(&format!("#{}]", ids[2])), "{}", texts[2]);
    assert!(texts[2].contains(&format!("#{}]", ids[3])), "{}", texts[2]);
    // Named in a summary, so in the roster.
    assert!(context.roster.contains(&xiaohong));

    // Off: no summaries, and the tail from the first row.
    projection.historian = false;
    let (context, _) = projection.base(&mut conn, last, &[]).await.unwrap();
    assert_eq!(context.items.len(), 3);
    assert!(user_text(&context.items[1]).contains(&format!("#{}]", ids[0])));
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
        historian: false,
        memory: String::new(),
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

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_trigger_and_what_it_quotes_show_their_pictures(pool: PgPool) {
    use max_core::item::Image;
    use max_core::message::{MediaKind, MediaMeta, MediaRef};

    let picture = || {
        InNode::Node(Node::Media {
            media: Some(MediaRef::Remote("https://q.example/x".into())),
            meta: MediaMeta {
                kind: MediaKind::Image,
                mime: None,
                size: None,
                name: None,
                description: None,
            },
        })
    };
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let mut ids = Vec::new();
    for (n, nodes) in [(0, vec![picture()]), (1, vec![text("看"), picture()])] {
        let row = from_xiaoming(n, nodes);
        let row = ingest::inbound(&mut conn, &place, &row, at(n), offset()).await;
        ids.push(row.unwrap().message.id);
    }
    let mut ask = from_xiaohong(
        2,
        vec![
            InNode::MentionMe {
                display: "maxx".into(),
            },
            text("这两张呢"),
            picture(),
        ],
    );
    ask.quote = Some(Quote {
        quote_id: Some("IDX0".into()),
        text: None,
    });
    let ask = ingest::inbound(&mut conn, &place, &ask, at(2), offset())
        .await
        .unwrap()
        .message
        .id;
    let projection = Projection {
        place: &place,
        system: "SYSTEM".into(),
        window: 100_000,
        // The first picture is cleared from the tail, so it is quoted.
        cleared_upto: Some(ids[0]),
        historian: false,
        memory: String::new(),
        now: at(3),
        offset: offset(),
    };
    let (context, _) = projection
        .base(&mut conn, ask, &[direct(ask)])
        .await
        .unwrap();
    let volatile = context.items.last().unwrap();
    let ItemKind::User { images, .. } = &volatile.kind else {
        panic!("{volatile:?}")
    };
    // Not the tail's.
    let handles: Vec<String> = images.iter().map(Image::handle).collect();
    assert_eq!(
        handles,
        [format!("image#{ask}.0"), format!("image#{}.0", ids[0])]
    );
    let text_only = tokens::count(user_text(volatile));
    assert_eq!(volatile.tokens, text_only + 2 * project::PICTURE_TOKENS);
}

/// A turn starts, as the actor starts one, and its base context's texts.
async fn turn(
    conn: &mut PgConnection,
    projection: &Projection<'_>,
    from: MessageId,
    woke: MessageId,
) -> Vec<String> {
    let conversation = projection.place.conversation;
    turns::start(
        conn,
        conversation,
        &[Input::Wake(direct(woke))],
        from,
        at(30),
    )
    .await
    .unwrap();
    let (context, _) = projection.base(conn, from, &[direct(woke)]).await.unwrap();
    context
        .items
        .iter()
        .map(|item| user_text(item).to_owned())
        .collect()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_turn_starts_with_the_first_call_of_the_turn_before(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let mut said = Vec::new();
    let words = [
        "早",
        "吃了吗",
        "在吗",
        "刚才那个",
        "还有这个",
        "再看看",
        "看下",
        "顺便",
    ];
    for (n, words) in (0..).zip(words) {
        let inbound = from_xiaoming(n, vec![text(words)]);
        let row = ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap();
        said.push(row.message.id);
    }
    let projection = Projection {
        place: &place,
        system: "SYSTEM".into(),
        window: 100_000,
        cleared_upto: None,
        historian: false,
        memory: String::new(),
        now: at(30),
        offset: offset(),
    };
    let all_but_volatile = |texts: &[String]| texts[..texts.len() - 1].to_vec();

    let first = turn(&mut conn, &projection, said[2], said[2]).await;
    assert_eq!(first.len(), 3, "{first:?}");
    let second = turn(&mut conn, &projection, said[5], said[5]).await;
    assert!(second.starts_with(&all_but_volatile(&first)), "{second:?}");
    assert_eq!(
        second[2],
        format!(
            "[12:02 小明 #{}]: 在吗\n[12:03 小明 #{}]: 刚才那个\n[12:04 小明 #{}]: 还有这个\n",
            said[2], said[3], said[4]
        ),
        "the second piece starts where the first turn's tail ended, with no date line"
    );
    // Woken by a row that someone talked after: its tail ends before that
    // row and goes on after it, so the turn after this one won't start
    // with its first call, and the cache misses once.
    let third = turn(&mut conn, &projection, said[7], said[6]).await;
    assert!(third.starts_with(&all_but_volatile(&second)), "{third:?}");
    assert_eq!(third.len(), 6, "{third:?}");
    assert_eq!(third[4], format!("[12:07 小明 #{}]: 顺便\n", said[7]));
}
