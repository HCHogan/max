//! Records a real provider's responses for the tests: a two-step exchange
//! where the model calls `run_code`, gets a made-up result back and
//! answers. The second request replays the first response's items, so a
//! provider that rejects how they're lowered fails here. Each response's
//! raw stream is saved as `<dir>/<name>-1.sse` and `<name>-2.sse`, with
//! the fields that identify the account behind it blanked.
//!
//! ```sh
//! MAX_LLM_BASE_URL=… MAX_LLM_API_KEY=… MAX_LLM_MODEL=… MAX_LLM_PROTOCOL=chat \
//!   cargo run -p max-llm --example record -- crates/max-llm/tests/recorded chat-deepseek
//! ```

#![expect(
    clippy::print_stdout,
    reason = "reporting what was recorded is the point"
)]

use std::collections::BTreeSet;
use std::env::var;
use std::path::Path;

use max_core::ids::CallId;
use max_core::item::{Item, ItemKind, ModelOutput, ModelTag, Protocol, ToolOutput};
use max_core::run::Request;
use max_core::tools::TOOLS;
use max_llm::{Call, Error, Options, chat, responses};

type Failure = Box<dyn std::error::Error>;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Failure> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [dir, name] = args.as_slice() else {
        return Err("usage: record <dir> <name>".into());
    };
    let protocol = match var("MAX_LLM_PROTOCOL")?.as_str() {
        "responses" => Protocol::Responses,
        "chat" => Protocol::Chat,
        other => return Err(format!("unknown protocol {other}").into()),
    };
    let model = ModelTag {
        protocol,
        model: var("MAX_LLM_MODEL")?,
    };
    let options = Options {
        effort: var("MAX_LLM_EFFORT").ok(),
        ..Options::default()
    };
    let mut request = Request {
        model,
        items: vec![
            Item::new(
                ItemKind::System {
                    text: "你是 Max，群聊里的助手。要算数时用 run_code 工具，不要心算。".into(),
                },
                30,
            ),
            Item::new(ItemKind::user("[1] 小明：2 的 64 次方是多少？"), 20),
        ],
        tools: &TOOLS,
        max_output: Some(4000),
        roster: BTreeSet::new(),
    };

    let first = step(
        &request,
        &options,
        &Path::new(dir).join(format!("{name}-1.sse")),
    )
    .await?;
    request.items.extend(first.items.iter().cloned());
    for item in &first.items {
        if let ItemKind::ToolCall(call) = &item.kind {
            request.items.push(Item::new(
                ItemKind::ToolResult {
                    call: CallId(call.id.0.clone()),
                    output: ToolOutput::text("18446744073709551616", false, 8),
                },
                8,
            ));
        }
    }
    step(
        &request,
        &options,
        &Path::new(dir).join(format!("{name}-2.sse")),
    )
    .await?;
    Ok(())
}

/// Sends one request, saves the raw stream and reads it back.
async fn step(request: &Request, options: &Options, path: &Path) -> Result<ModelOutput, Failure> {
    let (endpoint, body) = match request.model.protocol {
        Protocol::Responses => ("responses", responses::body(request, options)),
        Protocol::Chat => ("chat/completions", chat::body(request, options)),
    };
    let base = var("MAX_LLM_BASE_URL")?;
    let response = reqwest::Client::new()
        .post(format!("{}/{endpoint}", base.trim_end_matches('/')))
        .bearer_auth(var("MAX_LLM_API_KEY")?)
        .json(&body)
        .send()
        .await?;
    let status = response.status();
    let raw = response.bytes().await?;
    if !status.is_success() {
        return Err(format!("{status}: {}", String::from_utf8_lossy(&raw)).into());
    }
    let raw = redact(&String::from_utf8(raw.to_vec())?);
    std::fs::write(path, &raw)?;

    let output = read(request.model.clone(), &raw).await?;
    println!("{}:", path.display());
    for item in &output.items {
        println!("  {:?}", item.kind);
    }
    println!("  {:?}", output.usage);
    Ok(output)
}

/// Fields the tests don't need that would say whose account this was.
const IDENTIFYING: [&str; 3] = ["safety_identifier", "prompt_cache_key", "user"];

fn redact(text: &str) -> String {
    let mut text = text.to_owned();
    for field in IDENTIFYING {
        let key = format!(r#""{field}":""#);
        let mut from = 0;
        while let Some(start) = text[from..].find(&key).map(|at| from + at + key.len()) {
            let Some(length) = text[start..].find('"') else {
                break;
            };
            text.replace_range(start..start + length, "redacted");
            from = start;
        }
    }
    text
}

async fn read(model: ModelTag, raw: &str) -> Result<ModelOutput, Error> {
    let mut call = Call::replay(model, raw.as_bytes().to_vec());
    while call.next().await?.is_some() {}
    call.finish()
}
