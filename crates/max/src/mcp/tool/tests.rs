use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;

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

#[test]
fn types_are_typescript() {
    assert_eq!(
        typescript(&schema::<Args>(true)),
        "{ name: string; limit?: number; at?: number; which?: string | number; items?: { n: number }[] }"
    );
    assert_eq!(
        typescript(&schema::<Output>(false)),
        "{ text: string; until: string | null; items?: { n: number }[]; which: (string | number)[]; rest: object }"
    );
    let either = schema::<Either>(false);
    assert_eq!(either["type"], "object", "MCP asks for an object");
    assert!(typescript(&either).starts_with("{ items: { n: number }[] } | { text: string;"));
}

#[test]
fn only_an_arguments_fields_are_described() {
    let args = Value::Object(schema::<Args>(true));
    assert_eq!(
        args,
        json!({
            "type": "object",
            "properties": {
                "name": { "description": "名字", "type": "string", "minLength": 1, "maxLength": 3 },
                "limit": { "type": ["integer", "null"], "minimum": 1, "maximum": 10 },
                "at": { "type": ["integer", "null"], "minimum": 0 },
                "which": { "anyOf": [
                    { "anyOf": [{ "type": "string" }, { "type": "integer", "minimum": 0 }] },
                    { "type": "null" },
                ] },
                "items": { "type": ["array", "null"], "items": {
                    "type": "object",
                    "properties": { "n": { "type": "integer", "maximum": 5 } },
                    "required": ["n"],
                } },
            },
            "additionalProperties": false,
            "required": ["name"],
        })
    );
    for tool in TOOLS.iter() {
        for (schema, arguments) in [(&tool.input, true), (&tool.output, false)] {
            assert_eq!(schema["type"], "object", "{}", tool.name);
            described(
                &Value::Object(Map::clone(schema)),
                false,
                arguments,
                tool.name,
            );
        }
        assert!(
            !tool.declaration.contains("unknown"),
            "{}",
            tool.declaration
        );
    }
}

/// Fails on a title, or a description that isn't an argument's.
fn described(schema: &Value, field: bool, arguments: bool, tool: &str) {
    let Value::Object(schema) = schema else {
        return;
    };
    assert!(!schema.contains_key("title"), "{tool}");
    assert!(
        field && arguments || !schema.contains_key("description"),
        "{tool}: {schema:?}"
    );
    for (key, value) in schema {
        match (key.as_str(), value) {
            ("properties", Value::Object(fields)) => {
                for field in fields.values() {
                    described(field, true, arguments, tool);
                }
            }
            ("anyOf", Value::Array(variants)) => {
                for variant in variants {
                    described(variant, false, arguments, tool);
                }
            }
            ("items", items) => described(items, false, arguments, tool),
            _ => {}
        }
    }
}

#[test]
fn arguments_keep_to_their_bounds() {
    let schema = schema::<Args>(true);
    let bounded = |args: Value| bounded(&schema, &args, "");
    assert_eq!(
        bounded(json!({ "name": "猫猫猫", "limit": 10, "at": 0 })),
        Ok(())
    );
    assert_eq!(bounded(json!({ "name": "" })).unwrap_err(), "name 是空的");
    assert_eq!(
        bounded(json!({ "name": "猫猫猫猫" })).unwrap_err(),
        "name 最多 3 个字"
    );
    assert_eq!(
        bounded(json!({ "name": "猫", "limit": 11 })).unwrap_err(),
        "limit 要在 1 到 10 之间"
    );
    assert_eq!(
        bounded(json!({ "name": "猫", "at": -1 })).unwrap_err(),
        "at 不能小于 0"
    );
    assert_eq!(
        bounded(json!({ "name": "猫", "items": [{ "n": 5 }, { "n": 6 }] })).unwrap_err(),
        "items[1].n 不能大于 5"
    );
    // The variant that is the value's type; serde finds the wrong types.
    assert_eq!(
        bounded(json!({ "name": "猫", "which": -1 })).unwrap_err(),
        "which 不能小于 0"
    );
    assert_eq!(bounded(json!({ "name": "猫", "which": "job#3" })), Ok(()));
    assert_eq!(bounded(json!({ "name": 3, "limit": null, "x": 1 })), Ok(()));

    let agent = &find("agent").unwrap().input;
    let title =
        |title: String| super::bounded(agent, &json!({ "task": "查票价", "title": title }), "");
    assert_eq!(title("票".repeat(40)), Ok(()));
    assert_eq!(title("票".repeat(41)).unwrap_err(), "title 最多 40 个字");
}

/// What the system prompt says of the tools; a change shows here.
#[test]
fn declarations() {
    insta::assert_snapshot!(DECLARATIONS.as_str());
}
