use std::sync::Arc;

use max_core::ids::TurnId;
use max_db::PgPool;
use serde_json::json;
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use super::*;
use crate::conversation::testing::group_named;
use crate::conversation::{Event, Request};
use crate::mcp::{Caller, Services};

/// A turn's context whose conversation is `mailbox`, which a test
/// answers.
async fn context(pool: &PgPool) -> (Context, UnboundedReceiver<Event>) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group_named(&mut conn, "group:GROUP1").await);
    let (mailbox, events) = unbounded_channel();
    let context = Context {
        caller: Caller::Turn(Poster::new(mailbox, TurnId(1))),
        ..Context::check(Services::bare(pool.clone()), place)
    };
    (context, events)
}

/// The next request the conversation is sent, and the turn it is from.
async fn next(events: &mut UnboundedReceiver<Event>) -> (Request, Option<TurnId>) {
    match events.recv().await {
        Some(Event::Request { request, origin }) => (request, origin),
        other => panic!("{other:?}"),
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_turn_asks_and_answers_through_its_conversation(pool: PgPool) {
    let (context, mut events) = context(&pool).await;
    let asking = json!({ "to": 9, "question": "明天的活动几点开始？" });
    let asked = crate::mcp::call(Ask::NAME, &context, asking);
    let actor = async {
        let (request, origin) = next(&mut events).await;
        let Request::Ask {
            to,
            question,
            by,
            reply,
        } = request
        else {
            panic!("{request:?}");
        };
        reply.send(Ok(3)).unwrap();
        (to, question, by, origin)
    };
    let (out, sent) = tokio::join!(asked, actor);
    assert_eq!(out.unwrap(), json!({ "ask": "ask#3" }));
    let question = "明天的活动几点开始？".to_owned();
    assert_eq!(
        sent,
        (Some(ConversationId(9)), question, None, Some(TurnId(1)))
    );

    let answering = json!({ "to": 5, "text": "晚上八点" });
    let answered = crate::mcp::call(Answer::NAME, &context, answering);
    let actor = async {
        let (request, _) = next(&mut events).await;
        let Request::Answer {
            to,
            text,
            by,
            reply,
        } = request
        else {
            panic!("{request:?}");
        };
        reply.send(Ok("c#7 hank".to_owned())).unwrap();
        (to, text, by)
    };
    let (out, sent) = tokio::join!(answered, actor);
    assert_eq!(out.unwrap(), json!({ "to": "c#7 hank" }));
    assert_eq!(sent, (5, "晚上八点".to_owned(), None));

    // Why the conversation didn't take it is the tool's failure.
    let answering = json!({ "to": 5, "text": "九点" });
    let answered = crate::mcp::call(Answer::NAME, &context, answering);
    let actor = async {
        let (request, _) = next(&mut events).await;
        let Request::Answer { reply, .. } = request else {
            panic!("{request:?}");
        };
        reply
            .send(Err("nobody waits for an answer to ask#5".to_owned()))
            .unwrap();
    };
    let (out, ()) = tokio::join!(answered, actor);
    let refused = Failure::new("not_answered", "nobody waits for an answer to ask#5");
    assert_eq!(out.unwrap_err(), refused);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_long_or_empty_question_never_leaves(pool: PgPool) {
    let (context, mut events) = context(&pool).await;
    let most = "问".repeat(ASK_CHARS as usize);
    for (tool, args, wrong) in [
        (
            Ask::NAME,
            json!({ "to": 9, "question": format!("{most}问") }),
            "ask: question is at most 2000 characters",
        ),
        (
            Answer::NAME,
            json!({ "to": 5, "text": format!("{most}问") }),
            "answer: text is at most 2000 characters",
        ),
        (
            Ask::NAME,
            json!({ "to": 9, "question": " \n" }),
            "question is empty",
        ),
        (
            Answer::NAME,
            json!({ "to": 5, "text": "" }),
            "answer: text is empty",
        ),
        (
            Answer::NAME,
            json!({ "to": 0, "text": "八点" }),
            "answer: to is at least 1",
        ),
    ] {
        let refused = crate::mcp::call(tool, &context, args).await.unwrap_err();
        assert_eq!(refused, Failure::new("bad_arguments", wrong));
    }
    assert!(events.try_recv().is_err(), "nothing reached the actor");
    // As long as may be, it goes.
    let asked = crate::mcp::call(Ask::NAME, &context, json!({ "to": 9, "question": most }));
    let actor = async {
        let (request, _) = next(&mut events).await;
        let Request::Ask { reply, .. } = request else {
            panic!("{request:?}");
        };
        reply.send(Ok(1)).unwrap();
    };
    let (out, ()) = tokio::join!(asked, actor);
    assert_eq!(out.unwrap(), json!({ "ask": "ask#1" }));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_call_from_no_conversation_is_refused(pool: PgPool) {
    let (turn, _events) = context(&pool).await;
    let nowhere = Context::check(Services::bare(pool.clone()), Arc::clone(&turn.place));
    let asking = json!({ "to": 9, "question": "在吗" });
    let refused = crate::mcp::call(Ask::NAME, &nowhere, asking).await;
    assert_eq!(refused.unwrap_err().code, "not_here");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_agent_asks_as_itself(pool: PgPool) {
    let (turn, _events) = context(&pool).await;
    let (mailbox, mut events) = unbounded_channel();
    let (hooks, _hooked) = unbounded_channel();
    let link = crate::job::Link {
        upstream: Arc::new(crate::llm::Upstream {
            provider: "cliproxy".into(),
            protocol: max_core::item::Protocol::Chat,
            base_url: "http://127.0.0.1:9/v1".into(),
            api_key: None,
            headers: Vec::new(),
            model: "m".into(),
            window: 1_000_000,
            max_output: None,
            effort: None,
            idle: std::time::Duration::from_secs(120),
        }),
        called: unbounded_channel().0,
        hooks,
        stop: tokio_util::sync::CancellationToken::new(),
        poster: Poster::for_agent(mailbox, 3),
    };
    let context = Context {
        caller: Caller::Job(Arc::new(link)),
        ..Context::check(Services::bare(pool.clone()), Arc::clone(&turn.place))
    };
    let asking = json!({ "question": "选火锅还是烧烤？" });
    let asked = crate::mcp::call(Ask::NAME, &context, asking);
    let actor = async {
        let (request, origin) = next(&mut events).await;
        let Request::Ask { to, by, reply, .. } = request else {
            panic!("{request:?}");
        };
        reply.send(Ok(4)).unwrap();
        (to, by, origin)
    };
    let (out, sent) = tokio::join!(asked, actor);
    assert_eq!(out.unwrap(), json!({ "ask": "ask#4" }));
    assert_eq!(sent, (None, Some(3), None));
}
