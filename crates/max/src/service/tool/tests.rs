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
    assert_eq!(either["type"], "object", "a tool's result is an object");
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
    assert_eq!(bounded(json!({ "name": "" })).unwrap_err(), "name is empty");
    assert_eq!(
        bounded(json!({ "name": "猫猫猫猫" })).unwrap_err(),
        "name is at most 3 characters"
    );
    assert_eq!(
        bounded(json!({ "name": "猫", "limit": 11 })).unwrap_err(),
        "limit is from 1 to 10"
    );
    assert_eq!(
        bounded(json!({ "name": "猫", "at": -1 })).unwrap_err(),
        "at is at least 0"
    );
    assert_eq!(
        bounded(json!({ "name": "猫", "items": [{ "n": 5 }, { "n": 6 }] })).unwrap_err(),
        "items[1].n is at most 5"
    );
    // The variant that is the value's type; serde finds the wrong types.
    assert_eq!(
        bounded(json!({ "name": "猫", "which": -1 })).unwrap_err(),
        "which is at least 0"
    );
    assert_eq!(bounded(json!({ "name": "猫", "which": "job#3" })), Ok(()));
    assert_eq!(bounded(json!({ "name": 3, "limit": null, "x": 1 })), Ok(()));

    let ask = &find("ask").unwrap().input;
    let question =
        |question: String| super::bounded(ask, &json!({ "to": 9, "question": question }), "");
    assert_eq!(question("票".repeat(2000)), Ok(()));
    assert_eq!(
        question("票".repeat(2001)).unwrap_err(),
        "question is at most 2000 characters"
    );
}

/// The keywords a tool's arguments' schema may use: those something
/// checks, serde as it reads the arguments or `bounded`, and those that
/// only tell. Another one would be shown to the model and checked by
/// nothing: `pattern`, `maxItems`, `oneOf`.
const CHECKED: [&str; 13] = [
    // serde
    "type",
    "properties",
    "required",
    "additionalProperties",
    "items",
    "anyOf",
    "enum",
    // bounded
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
    // telling
    "description",
    "default",
];

#[test]
fn arguments_use_only_what_is_checked() {
    for spec in TOOLS.iter() {
        assert_eq!(
            checked(&spec.input, &format!("{}(args)", spec.name)),
            Ok(())
        );
    }
}

/// Whether `schema` uses only what is checked, or what at `path` doesn't.
fn checked(schema: &Map<String, Value>, path: &str) -> Result<(), String> {
    for (key, value) in schema {
        if !CHECKED.contains(&key.as_str()) {
            return Err(format!("{path} has {key}"));
        }
        let nested: Vec<(String, &Value)> = match (key.as_str(), value) {
            ("properties", Value::Object(fields)) => fields
                .iter()
                .map(|(name, field)| (format!("{path}.{name}"), field))
                .collect(),
            ("items", item) => vec![(format!("{path}[]"), item)],
            ("anyOf", Value::Array(variants)) => variants
                .iter()
                .map(|variant| (path.to_owned(), variant))
                .collect(),
            // A map's values, whose bounds `bounded` doesn't look into.
            ("additionalProperties", other) if !other.is_boolean() => {
                return Err(format!("{path} is a map"));
            }
            _ => Vec::new(),
        };
        for (path, nested) in nested {
            if let Value::Object(nested) = nested {
                checked(nested, &path)?;
            }
        }
    }
    // `bounded` checks a value against the first variant of its type: of
    // two of the same, as two objects, the second's bounds go unchecked.
    if let Some(Value::Array(variants)) = schema.get("anyOf") {
        let mut seen = Vec::new();
        for variant in variants {
            let types =
                types(variant).ok_or_else(|| format!("{path} has a variant of any type"))?;
            for name in types {
                if seen.contains(&name) {
                    return Err(format!("{path} has two variants of {name}"));
                }
                seen.push(name);
            }
        }
    }
    Ok(())
}

/// The JSON types `schema` admits, as `admits` tells them, an integer a
/// number; None for any.
fn types(schema: &Value) -> Option<Vec<&str>> {
    if let Some(Value::Array(variants)) = schema.get("anyOf") {
        let each: Option<Vec<Vec<&str>>> = variants.iter().map(types).collect();
        return each.map(|each| each.concat());
    }
    fn number(name: &str) -> &str {
        if name == "integer" { "number" } else { name }
    }
    match schema.get("type")? {
        Value::Array(names) => Some(names.iter().filter_map(Value::as_str).map(number).collect()),
        Value::String(name) => Some(vec![number(name)]),
        _ => None,
    }
}

#[test]
fn what_isnt_checked_is_caught() {
    let checked = |schema: Value| {
        let Value::Object(schema) = schema else {
            unreachable!("a schema is an object")
        };
        checked(&schema, "t(args)")
    };
    // An optional one of two.
    let job = json!({ "anyOf": [{ "type": "string" }, { "type": "integer", "minimum": 0 }] });
    let job = json!({ "anyOf": [job, { "type": "null" }] });
    assert_eq!(checked(json!({ "properties": { "job": job } })), Ok(()));
    let code = json!({ "type": "string", "pattern": "^\\d+$" });
    assert_eq!(
        checked(json!({ "properties": { "code": code } })),
        Err("t(args).code has pattern".to_owned())
    );
    let to = json!({ "anyOf": [
        { "type": "object", "properties": { "id": { "type": "integer" } } },
        { "type": "object", "properties": { "name": { "type": "string", "maxLength": 8 } } },
    ] });
    assert_eq!(
        checked(json!({ "properties": { "to": to } })),
        Err("t(args).to has two variants of object".to_owned())
    );
}

/// A name is the host's or the guest's, and maxx and a program know which
/// by the guest's table alone.
#[test]
fn the_guests_tools_have_names_of_their_own() {
    let mut names: Vec<&str> = TOOLS.iter().map(|tool| tool.name).collect();
    names.extend(LOCAL.iter().map(|tool| tool.name.as_str()));
    let all = names.len();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), all, "{names:?}");
}

/// What the system prompt says of the tools; a change shows here.
#[test]
fn declarations() {
    insta::assert_snapshot!(DECLARATIONS.as_str());
}
