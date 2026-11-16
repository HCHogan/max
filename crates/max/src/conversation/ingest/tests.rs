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
