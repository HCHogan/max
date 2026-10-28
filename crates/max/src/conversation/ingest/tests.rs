use max_core::ids::FaceId;
use max_db::PgPool;

use super::*;
use crate::conversation::testing::{at, from_xiaoming, group, offset, text};

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
    let first = inbound(&mut conn, &place, &hello, at(0), offset())
        .await
        .unwrap();
    assert_eq!(first.direct, Some(Direct::MentionsMe));
    assert_eq!(first.text, "在吗 @小红");
    assert!(!first.command);
    let row = ledger::row(&mut conn, place.conversation, first.message.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.message, first.message);

    let draft = Draft {
        reply_to: Some(first.message.id),
        nodes: vec![
            DraftNode::Text {
                text: "在的，说吧".into(),
            },
            DraftNode::Face { face: FaceId(14) },
        ],
    };
    let (mine, sent) = said(
        &mut conn,
        &place,
        draft.clone(),
        None,
        None,
        at(1),
        offset(),
    )
    .await
    .unwrap();
    assert_eq!(sent, draft);
    assert_eq!(mine.sender.identity, place.me.identity);

    // Quoted by an id QQ never gave us, found by its text.
    let mut reply = from_xiaoming(2, vec![text("!status")]);
    reply.quote = Some(Quote {
        quote_id: Some("UNKNOWN".into()),
        text: Some("在的， 说吧[微笑]".into()),
    });
    let second = inbound(&mut conn, &place, &reply, at(2), offset())
        .await
        .unwrap();
    assert_eq!(
        second.message.content,
        Content::Message {
            reply_to: Some(mine.id),
            nodes: vec![Node::Text {
                text: "!status".into()
            }],
        }
    );
    assert_eq!(second.direct, Some(Direct::RepliesToMe));
    assert!(second.command);

    // Quoted by its quote id.
    let mut again = from_xiaoming(3, vec![text("嗯")]);
    again.quote = Some(Quote {
        quote_id: Some("IDX0".into()),
        text: None,
    });
    let third = inbound(&mut conn, &place, &again, at(3), offset())
        .await
        .unwrap();
    assert_eq!(third.direct, None);
    let Content::Message { reply_to, .. } = &third.message.content else {
        panic!("{:?}", third.message.content);
    };
    assert_eq!(*reply_to, Some(first.message.id));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn what_max_says_is_checked(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let hello = from_xiaoming(0, vec![text("hi")]);
    let first = inbound(&mut conn, &place, &hello, at(0), offset())
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
    let (mine, sent) = said(&mut conn, &place, draft, None, None, at(1), offset())
        .await
        .unwrap();
    assert_eq!(sent.reply_to, None);
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
    let me = platform::account(&mut conn, Platform::Qq, "BOT", "maxx")
        .await
        .unwrap();
    let kind = ConversationKind::Direct;
    let endpoint = platform::endpoint(&mut conn, Platform::Qq, "c2c:U", me.identity, kind, None)
        .await
        .unwrap();
    let place = Place {
        conversation: endpoint.conversation,
        kind,
        endpoint: endpoint.id,
        platform: Platform::Qq,
        native_id: "c2c:U".into(),
        me,
        my_name: "maxx".into(),
    };
    let committed = inbound(
        &mut conn,
        &place,
        &from_xiaoming(0, vec![text("hi")]),
        at(0),
        offset(),
    )
    .await
    .unwrap();
    assert_eq!(committed.direct, Some(Direct::Private));
}
