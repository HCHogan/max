use std::sync::Arc;

use max_core::ids::TurnId;
use max_db::PgPool;
use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use super::*;
use crate::conversation::Event;
use crate::conversation::testing::group_named;
use crate::mcp::tool::TOOLS;
use crate::mcp::{Call, Caller, Services};

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

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_turn_asks_and_answers_through_its_conversation(pool: PgPool) {
    let (context, mut events) = context(&pool).await;
    let asking = json!({ "to": "c#9", "question": "明天的活动几点开始？" });
    let asked = crate::mcp::call(Ask::NAME, &context, asking);
    let actor = async {
        let Some(Event::Ask {
            to,
            question,
            origin,
            reply,
        }) = events.recv().await
        else {
            panic!("no Ask");
        };
        reply.send(Ok(3)).unwrap();
        (to, question, origin)
    };
    let (out, sent) = tokio::join!(asked, actor);
    assert_eq!(out.unwrap(), json!({ "job": "job#3" }));
    let question = "明天的活动几点开始？".to_owned();
    assert_eq!(sent, (ConversationId(9), question, Some(TurnId(1))));

    let answering = json!({ "to": "#501", "text": "晚上八点" });
    let answered = crate::mcp::call(Answer::NAME, &context, answering);
    let actor = async {
        let Some(Event::Answer {
            to, text, reply, ..
        }) = events.recv().await
        else {
            panic!("no Answer");
        };
        reply.send(Ok("c#7 hank".to_owned())).unwrap();
        (to, text)
    };
    let (out, sent) = tokio::join!(answered, actor);
    assert_eq!(out.unwrap(), json!({ "to": "c#7 hank" }));
    assert_eq!(sent, (MessageId(501), "晚上八点".to_owned()));

    // Why the conversation didn't take it is the tool's failure.
    let answering = json!({ "to": 501, "text": "九点" });
    let answered = crate::mcp::call(Answer::NAME, &context, answering);
    let actor = async {
        let Some(Event::Answer { reply, .. }) = events.recv().await else {
            panic!("no Answer");
        };
        reply
            .send(Err("没有人在等 #501 的回答".to_owned()))
            .unwrap();
    };
    let (out, ()) = tokio::join!(answered, actor);
    let refused = Failure::new("not_answered", "没有人在等 #501 的回答");
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
            "ask 的 question 最多 2000 个字",
        ),
        (
            Answer::NAME,
            json!({ "to": 501, "text": format!("{most}问") }),
            "answer 的 text 最多 2000 个字",
        ),
        (
            Ask::NAME,
            json!({ "to": 9, "question": " \n" }),
            "question 是空的",
        ),
        (
            Answer::NAME,
            json!({ "to": 501, "text": "" }),
            "answer 的 text 是空的",
        ),
        (
            Ask::NAME,
            json!({ "to": "示波器同好会", "question": "在吗" }),
            "示波器同好会 不是会话的编号，要 c#9 或 9",
        ),
    ] {
        let refused = crate::mcp::call(tool, &context, args).await.unwrap_err();
        assert_eq!(refused, Failure::new("bad_arguments", wrong));
    }
    assert!(events.try_recv().is_err(), "nothing reached the actor");
    // As long as may be, it goes.
    let asked = crate::mcp::call(Ask::NAME, &context, json!({ "to": 9, "question": most }));
    let actor = async {
        let Some(Event::Ask { reply, .. }) = events.recv().await else {
            panic!("no Ask");
        };
        reply.send(Ok(1)).unwrap();
    };
    let (out, ()) = tokio::join!(asked, actor);
    assert_eq!(out.unwrap(), json!({ "job": "job#1" }));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn only_a_turn_asks_and_answers(pool: PgPool) {
    let (turn, _events) = context(&pool).await;
    let (mailbox, mut events) = unbounded_channel();
    let program = Context {
        caller: Caller::Program(Poster::program(mailbox)),
        ..Context::check(Services::bare(pool.clone()), Arc::clone(&turn.place))
    };
    // A program Max keeps in the VM has every tool but these two, and a
    // background agent has neither.
    for tool in TOOLS.iter() {
        let asks = [Ask::NAME, Answer::NAME].contains(&tool.name);
        assert_eq!(
            program.caller.allows(Call::Tool(tool)),
            !asks,
            "{}",
            tool.name
        );
        assert!(turn.caller.allows(Call::Tool(tool)), "{}", tool.name);
        assert!(!(asks && tool.job), "{}", tool.name);
    }
    let args = || -> Value { json!({ "to": 9, "question": "在吗" }) };
    let refused = crate::mcp::program_call(Ask::NAME, &program, args()).await;
    let not_allowed = Failure::new("not_allowed", "常驻程序用不了 ask");
    assert_eq!(refused.unwrap_err(), not_allowed);
    // Nor does the tool itself take another caller's word.
    for context in [
        &program,
        &Context::check(Services::bare(pool.clone()), Arc::clone(&turn.place)),
    ] {
        let refused = crate::mcp::call(Ask::NAME, context, args())
            .await
            .unwrap_err();
        assert_eq!(refused.code, "not_here");
    }
    assert!(events.try_recv().is_err(), "nothing reached the actor");
}

#[test]
fn a_conversation_and_a_line_are_named_either_way() {
    let handle = |value: Value| serde_json::from_value::<Handle>(value).unwrap();
    for to in [json!("c#9"), json!(" C#9 "), json!("9"), json!(9)] {
        let named = handle(to.clone()).conversation();
        assert_eq!(named.unwrap(), ConversationId(9), "{to}");
    }
    for to in [json!("#501"), json!(" 501 "), json!(501)] {
        assert_eq!(handle(to.clone()).line().unwrap(), MessageId(501), "{to}");
    }
    for to in [json!("群"), json!("#501"), json!("c#"), json!(0), json!(-9)] {
        let wrong = handle(to.clone()).conversation().unwrap_err();
        assert_eq!(wrong.code, "bad_arguments", "{to}");
        assert!(wrong.message.ends_with("要 c#9 或 9"), "{}", wrong.message);
    }
    for to in [
        json!("c#9"),
        json!("#"),
        json!("#-5"),
        json!("+5"),
        json!(0),
    ] {
        let wrong = handle(to.clone()).line().unwrap_err();
        assert_eq!(wrong.code, "bad_arguments", "{to}");
    }
}
