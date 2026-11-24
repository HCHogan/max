use std::sync::Arc;

use max_core::ids::CallId;
use max_core::item::{Item, ItemKind, ModelTag, Part, Protocol, ToolCall, ToolOutput};
use max_core::run::{Context, Outcome, RunRecord, RunSpec};
use sqlx::PgPool;

use super::*;
use crate::testing::{self, at};
use crate::turns;

fn call(id: &str, name: &str, arguments: &str) -> Arc<Item> {
    Arc::new(Item::new(
        ItemKind::ToolCall(ToolCall {
            id: CallId::new(id),
            name: name.into(),
            arguments: arguments.into(),
        }),
        10,
    ))
}

fn result(id: &str, texts: &[&str]) -> Arc<Item> {
    let parts = texts
        .iter()
        .map(|text| Part::Text {
            text: (*text).into(),
        })
        .collect();
    Arc::new(Item::new(
        ItemKind::ToolResult {
            call: CallId::new(id),
            output: ToolOutput {
                parts,
                error: false,
                tokens: 10,
            },
        },
        10,
    ))
}

/// A turn's calls, in its run as the core keeps them, read back as text:
/// the arguments a line each, the result's text, and a call that never
/// got a result or wasn't JSON as it was written. A search finds them by
/// either.
#[sqlx::test]
async fn a_runs_tool_calls_read_back_as_text(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = testing::group(&mut conn, "group:30001").await?;
    let max = testing::sender(group.max, "Max", None);
    let from = testing::commit(&mut conn, &group, &max, &testing::said("早"), 0).await?;
    let conversation = group.endpoint.conversation;
    let spec = RunSpec {
        model: ModelTag {
            protocol: Protocol::Chat,
            model: "qwen".into(),
        },
        window: 128_000,
        max_output: None,
    };
    let base = Context {
        items: Vec::new(),
        roster: Default::default(),
    };
    let transcript = [
        Arc::new(Item::new(
            ItemKind::Reasoning {
                text: Some("先算一下".into()),
            },
            5,
        )),
        call(
            "a",
            "run_code",
            r#"{"code": "return 1 + 1;\n", "timeout_ms": 5000}"#,
        ),
        result("a", &["returned:", "2"]),
        call("b", "shell", "{not json"),
        Arc::new(Item::new(
            ItemKind::Assistant {
                text: "是 2".into(),
            },
            5,
        )),
    ];
    let run = RunRecord {
        spec: &spec,
        base: &base,
        transcript: &transcript,
    };
    let started = turns::start(&mut conn, conversation, &[], from, at(1)).await?;
    turns::finish(&mut conn, started.turn, &run, &Outcome::Answered, at(2)).await?;
    let lost = turns::start(&mut conn, conversation, &[], from, at(3)).await?;
    turns::close(&mut conn, lost.turn, &Outcome::Lost, at(4)).await?;

    let first = Call {
        turn: started.ordinal,
        n: 1,
        name: "run_code".into(),
        arguments: "code: return 1 + 1;\n\ntimeout_ms: 5000".into(),
        output: "returned:\n2".into(),
        started: at(1),
    };
    let second = Call {
        turn: started.ordinal,
        n: 2,
        name: "shell".into(),
        arguments: "{not json".into(),
        output: String::new(),
        started: at(1),
    };
    let read = |n| call_of(&pool, conversation, started.ordinal, n);
    assert_eq!(read(1).await?, Some(first.clone()));
    assert_eq!(read(2).await?, Some(second.clone()));
    assert_eq!(read(3).await?, None);
    assert_eq!(call_of(&pool, conversation, lost.ordinal, 1).await?, None);

    let patterns = ["%not json%".to_owned(), "%returned%".to_owned()];
    let query = Query {
        conversation,
        patterns: &patterns,
        from: None,
        until: None,
        sender: None,
        limit: 10,
    };
    let found = matching(&mut conn, &query).await?;
    assert_eq!(found, [(second, vec![0]), (first, vec![1])]);
    Ok(())
}

async fn call_of(
    pool: &PgPool,
    conversation: ConversationId,
    turn: i32,
    n: i32,
) -> sqlx::Result<Option<Call>> {
    let mut conn = pool.acquire().await?;
    super::call(&mut conn, conversation, turn, n).await
}
