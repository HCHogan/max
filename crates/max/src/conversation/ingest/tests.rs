use max_db::PgPool;

use super::*;
use crate::conversation::testing::{
    at, from_xiaohong, from_xiaoming, group, group_named, offset, private, text,
};

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn mentions_quotes_and_commands(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let hello = from_xiaoming(
        0,
        vec![
            InNode::MentionMe {
                display: "maxx".into(),
            },
            text(" 在吗 "),
            InNode::Mention {
                user: "XIAOHONG".into(),
                display: "小红".into(),
            },
        ],
    );
    let first = inbound(&mut conn, &place, hello, at(0), offset())
        .await
        .unwrap();
    assert_eq!(first.direct, Some(Direct::MentionsMe));
    assert_eq!(first.text, "在吗 @小红");
    assert!(first.command.is_none());
    let row = ledger::row(&mut conn, place.conversation, first.message.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.message, *first.message);

    let draft = Draft {
        reply_to: Some(first.message.id),
        nodes: vec![DraftNode::Text {
            text: "在的，说吧".into(),
        }],
    };
    let mine = said(
        &mut conn,
        &place,
        draft,
        None,
        None,
        By::Max,
        at(1),
        offset(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(mine.sender.identity, place.me.identity);

    // Quoted by an id QQ never gave us, found by its text.
    let mut reply = from_xiaoming(2, vec![text("/status")]);
    reply.quote = Some(Quote {
        quote_id: Some("UNKNOWN".into()),
        text: Some("在的， 说吧[微笑]".into()),
        files: Vec::new(),
    });
    let second = inbound(&mut conn, &place, reply, at(2), offset())
        .await
        .unwrap();
    assert_eq!(
        second.message.content,
        Content::Message {
            reply_to: Some(mine.id),
            nodes: vec![Node::Text {
                text: "/status".into()
            }],
        }
    );
    assert_eq!(second.direct, Some(Direct::RepliesToMe));
    // Not a command: in a group, other bots take `/` too.
    assert!(second.command.is_none());

    // Quoted by its quote id.
    let mut again = from_xiaoming(3, vec![text("嗯")]);
    again.quote = Some(Quote {
        quote_id: Some("IDX0".into()),
        text: None,
        files: Vec::new(),
    });
    let third = inbound(&mut conn, &place, again, at(3), offset())
        .await
        .unwrap();
    assert_eq!(third.direct, None);
    let Content::Message { reply_to, .. } = &third.message.content else {
        panic!("{:?}", third.message.content);
    };
    assert_eq!(*reply_to, Some(first.message.id));

    let me = InNode::MentionMe {
        display: "maxx".into(),
    };
    let status = from_xiaoming(4, vec![me, text(" /status")]);
    let fourth = inbound(&mut conn, &place, status, at(4), offset())
        .await
        .unwrap();
    assert!(fourth.command.is_some());
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn quotes_by_an_index_qq_never_gave(pool: PgPool) {
    use max_core::message::{MediaKind, MediaMeta, MediaRef};

    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let picture = InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://q.example/p".into())),
        meta: MediaMeta {
            kind: MediaKind::Image,
            mime: Some("image/png".into()),
            size: Some(1024),
            name: Some("0A1B2C3D4E5F60718293A4B5C6D7E8F9.png".into()),
            description: None,
        },
    });
    let posted = from_xiaoming(0, vec![picture]);
    let posted = inbound(&mut conn, &place, posted, at(0), offset())
        .await
        .unwrap();
    let asked = from_xiaohong(1, vec![text("明天几点开会\n在哪个教室")]);
    let asked = inbound(&mut conn, &place, asked, at(1), offset())
        .await
        .unwrap();
    let quoting = async |conn: &mut PgConnection, n, quote| {
        let mut row = from_xiaoming(n, vec![text("嗯")]);
        row.quote = Some(quote);
        let row = inbound(conn, &place, row, at(n), offset()).await.unwrap();
        let Content::Message { reply_to, .. } = row.message.content else {
            panic!("{:?}", row.message.content);
        };
        (reply_to, row.direct)
    };

    // A picture, by its file name.
    let by_file = Quote {
        quote_id: Some("UNKNOWN".into()),
        text: None,
        files: vec!["0A1B2C3D4E5F60718293A4B5C6D7E8F9.png".into()],
    };
    let found = quoting(&mut conn, 2, by_file).await;
    assert_eq!(found, (Some(posted.message.id), None));
    // Someone's words, not only Max's, across a line break.
    let by_text = Quote {
        quote_id: Some("UNKNOWN".into()),
        text: Some("明天几点开会\n在哪个教室".into()),
        files: Vec::new(),
    };
    let found = quoting(&mut conn, 3, by_text).await;
    assert_eq!(found, (Some(asked.message.id), None));
    // Nothing like it: no quote.
    let unknown = Quote {
        quote_id: Some("UNKNOWN".into()),
        text: Some("后天".into()),
        files: vec!["FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF.png".into()],
    };
    assert_eq!(quoting(&mut conn, 4, unknown).await, (None, None));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn what_max_says_is_checked(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let hello = from_xiaoming(0, vec![text("hi")]);
    let first = inbound(&mut conn, &place, hello, at(0), offset())
        .await
        .unwrap();
    let xiaoming = first.sender.principal;
    let nobody = PrincipalId(9999);
    let draft = Draft {
        reply_to: Some(MessageId(424242)),
        nodes: vec![
            DraftNode::Mention {
                principal: xiaoming,
            },
            DraftNode::Mention { principal: nobody },
            DraftNode::Text {
                text: " 好".into()
            },
        ],
    };
    let mine = said(
        &mut conn,
        &place,
        draft,
        None,
        None,
        By::Max,
        at(1),
        offset(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        mine.content,
        Content::Message {
            reply_to: None,
            nodes: vec![
                Node::Mention {
                    target: MentionTarget::Identity(first.sender.identity),
                    display: "小明".into(),
                },
                Node::Text {
                    text: "@某人".into()
                },
                Node::Text {
                    text: " 好".into()
                },
            ],
        }
    );
    let text: String = sqlx::query_scalar("select text from messages where id = $1")
        .bind(mine.id.0)
        .fetch_one(&mut *conn)
        .await
        .unwrap();
    assert_eq!(text, format!("[mention#{xiaoming}]@某人 好"));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn everything_in_a_private_chat_is_for_max(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = private(&mut conn).await;
    let committed = inbound(
        &mut conn,
        &place,
        from_xiaoming(0, vec![text("hi")]),
        at(0),
        offset(),
    )
    .await
    .unwrap();
    assert_eq!(committed.direct, Some(Direct::Private));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn pictures_max_sends_again(pool: PgPool) {
    use max_core::message::{MediaKind, MediaMeta, MediaRef};
    use max_db::media::{self, Blob};

    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let elsewhere = group_named(&mut conn, "group:GROUP2").await;
    let medium = |kind| {
        InNode::Node(Node::Media {
            media: Some(MediaRef::Remote("https://q.example/x".into())),
            meta: MediaMeta {
                kind,
                mime: None,
                size: None,
                name: None,
                description: None,
            },
        })
    };
    let nodes = vec![
        medium(MediaKind::Image),
        medium(MediaKind::Sticker),
        medium(MediaKind::File),
        medium(MediaKind::Image),
    ];
    let row = inbound(&mut conn, &place, from_xiaoming(0, nodes), at(0), offset())
        .await
        .unwrap()
        .message
        .id;
    // The last isn't downloaded.
    for (ordinal, byte) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        let blob = Blob {
            sha256: byte.to_string().repeat(64),
            mime: Some("image/gif".into()),
            size: 3,
            width: None,
            height: None,
            model_sha256: None,
        };
        media::record(&mut conn, row, ordinal, &blob, at(0))
            .await
            .unwrap();
    }
    let picture = |ordinal| Draft {
        reply_to: None,
        nodes: vec![DraftNode::Picture {
            message: row,
            ordinal,
        }],
    };
    let mut say = async |place, ordinal| {
        said(
            &mut conn,
            place,
            picture(ordinal),
            None,
            None,
            By::Max,
            at(1),
            offset(),
        )
        .await
        .unwrap()
    };

    let here: Vec<bool> = [
        say(&place, 0).await,
        say(&place, 1).await,
        say(&place, 2).await,
        say(&place, 3).await,
    ]
    .iter()
    .map(Option::is_some)
    .collect();
    assert_eq!(here, [true, true, false, false]);
    // Elsewhere, only the sticker.
    assert!(say(&elsewhere, 0).await.is_none());
    let sticker = say(&elsewhere, 1).await.unwrap();
    let b = "b".repeat(64);
    assert_eq!(
        sticker.content,
        Content::Message {
            reply_to: None,
            nodes: vec![Node::Media {
                media: Some(MediaRef::Blob(b.clone())),
                meta: MediaMeta {
                    kind: MediaKind::Sticker,
                    mime: Some("image/gif".into()),
                    size: Some(3),
                    name: None,
                    description: None,
                },
            }],
        }
    );
    assert_eq!(sticker.conversation, elsewhere.conversation);
    // Its own handle now, to send again in turn.
    assert_eq!(
        media::downloaded(&mut conn, sticker.id).await.unwrap(),
        [(0, b)]
    );
}
