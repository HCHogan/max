use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::*;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[expect(dead_code, reason = "only its schema")]
struct Args {
    /// Code's documentation, not the model's.
    #[schemars(length(min = 1, max = 3), description = "名字")]
    name: String,
    #[schemars(range(min = 1, max = 10))]
    limit: Option<u8>,
    #[schemars(range(min = 0))]
    at: Option<i64>,
    which: Option<Which>,
    items: Option<Vec<Item>>,
}

/// Code's documentation, not the model's.
#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
enum Which {
    Text(String),
    Number(u32),
}

#[derive(Deserialize, Serialize, JsonSchema)]
struct Item {
    #[schemars(range(max = 5))]
    n: i64,
}

#[derive(Serialize, JsonSchema)]
struct Output {
    text: String,
    until: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    items: Option<Vec<Item>>,
    which: Vec<Which>,
    rest: Map<String, Value>,
}

#[derive(Serialize, JsonSchema)]
#[serde(untagged)]
#[expect(dead_code, reason = "only its schema")]
enum Either {
    Found { items: Vec<Item> },
    Read(Output),
}

/// What the system prompt says of the tools; a change shows here.
#[test]
fn declarations() {
    insta::assert_snapshot!(DECLARATIONS.as_str());
}
