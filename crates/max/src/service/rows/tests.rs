use std::sync::Arc;

use chrono::Utc;
use max_core::message::{Draft, DraftNode};
use serde_json::{Value, json};
use sqlx::PgPool;

use super::*;
use crate::conversation::testing::{from_xiaohong, from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};
use crate::service::Services;

/// Calls the tool as a program does, its arguments checked.
async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    crate::service::call(Rows::NAME, context, args).await
}

/// Three rows of people's and one of Max's, a reply to the second: their
/// ids, and the group.
async fn talked(pool: &PgPool) -> (Arc<Place>, Vec<i64>) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let mut ids = Vec::new();
    for inbound in [
        from_xiaoming(1, vec![text("早")]),
        from_xiaohong(2, vec![text("ping")]),
        from_xiaoming(3, vec![text("在吗")]),
    ] {
        let committed = ingest::inbound(&mut conn, &place, inbound, Utc::now(), offset());
        ids.push(committed.await.unwrap().message.id.0);
    }
    let draft = Draft {
        reply_to: Some(MessageId(ids[1])),
        nodes: vec![DraftNode::Text {
            text: "pong".into(),
        }],
    };
    let by = ingest::By::Program;
    let said = ingest::said(
        &mut conn,
        &place,
        draft,
        None,
        None,
        by,
        Utc::now(),
        offset(),
    );
    ids.push(said.await.unwrap().unwrap().id.0);
    (place, ids)
}

fn ids(read: &Value) -> Vec<i64> {
    let rows = read["rows"].as_array().unwrap();
    rows.iter().map(|row| row["id"].as_i64().unwrap()).collect()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_reads_the_rows_as_they_are_stored(pool: PgPool) {
    let (place, said) = talked(&pool).await;
    let context = Context::check(Services::bare(pool), Arc::clone(&place));

    // The newest, in the timeline's order, each whole.
    let read = run(&context, json!({})).await.unwrap();
    assert_eq!(ids(&read), said);
    assert_eq!(read["head"], said[3]);
    let first = &read["rows"][0];
    let identity = first["sender"]["identity"].as_i64().unwrap();
    assert_eq!(
        first,
        &json!({
            "id": said[0],
            "conversation": place.conversation.0,
            "sender": { "identity": identity, "name": "小明", "role": "member" },
            "at": first["at"],
            "content": {
                "type": "message",
                "reply_to": null,
                "nodes": [{ "type": "text", "text": "早" }],
            },
            "turn": null,
            "raw": null,
            "command": false,
            "delivery": null,
        })
    );
    // The schema names a row's fields, these and no others.
    let schema = &crate::service::tool::find(Rows::NAME).unwrap().output;
    let declared = schema["properties"]["rows"]["items"]["properties"]
        .as_object()
        .unwrap();
    let mut declared: Vec<&String> = declared.keys().collect();
    let mut written: Vec<&String> = first.as_object().unwrap().keys().collect();
    declared.sort();
    written.sort();
    assert_eq!(declared, written);
    // What a program of Max's said: whose it is, and what it replies to.
    let last = &read["rows"][3];
    assert_eq!(last["raw"], json!({ "said_by": "program" }));
    assert_eq!(last["content"]["reply_to"], said[1]);
    // Whose each account is: a person each, the two who spoke and Max.
    let people = read["people"].as_object().unwrap();
    assert_eq!(people.len(), 3, "{people:?}");
    assert!(people[&identity.to_string()].is_i64(), "{people:?}");

    // On from a row, the first of them; back from one, the newest.
    let on = run(&context, json!({ "after": said[0], "limit": 2 }));
    assert_eq!(ids(&on.await.unwrap()), said[1..3]);
    let back = run(&context, json!({ "before": said[3], "limit": 2 }));
    assert_eq!(ids(&back.await.unwrap()), said[1..3]);
    let between = run(&context, json!({ "after": said[0], "before": said[3] }));
    assert_eq!(ids(&between.await.unwrap()), said[1..3]);
    let past = run(&context, json!({ "after": said[3] })).await.unwrap();
    assert_eq!((ids(&past), &past["head"]), (vec![], &json!(said[3])));

    let wrong = run(&context, json!({ "limit": 0 })).await.unwrap_err();
    assert_eq!(wrong.code, "bad_arguments", "{wrong:?}");
    let wrong = run(&context, json!({ "who": "小明" })).await.unwrap_err();
    assert_eq!(wrong.code, "bad_arguments", "{wrong:?}");
}
