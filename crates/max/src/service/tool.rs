//! A Max tool, declared once, in Rust: its arguments and its result are
//! types, their bounds schemars attributes, and next to them how it is
//! used and how it runs. The JSON Schemas max's service lists, the
//! checks on a call's arguments and the TypeScript the system prompt
//! declares it with all come from there. See "Tool contract" in
//! docs/rust-rewrite.md. The guest has tools of its own, which need no
//! host: those are declared once too, in nix/local.json ([`LOCAL`]).

use std::future::Future;
use std::sync::LazyLock;

use futures_util::future::BoxFuture;
use schemars::JsonSchema;
use schemars::generate::SchemaSettings;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tracing::warn;

use super::ask::{Answer, Ask};
use super::chat_file::File;
use super::config::Config;
use super::find_stickers::FindStickers;
use super::history::History;
use super::mute_member::MuteMember;
use super::program::{Say, Wake};
use super::recall_message::RecallMessage;
use super::rows::Rows;
use super::send_file::SendFile;
use super::send_image::SendImage;
use super::web_search::WebSearch;
use super::{Context, Failure, arguments, internal};

/// A Max tool: what a program calls as `tools.<name>(args)`.
pub trait Tool: 'static {
    const NAME: &'static str;
    /// One line for the list of tools, which is what `maxx` shows of it,
    /// with its arguments' descriptions.
    const DESCRIPTION: &'static str;
    /// Whether the system prompt declares it. Those it doesn't, `say` and
    /// `wake`, are for the programs Max keeps in the group's VM: a turn
    /// says things in its own output, and is awake. Anything in the VM
    /// may call either all the same. See "Resident programs" in
    /// docs/rust-rewrite.md.
    const TURN: bool = true;

    type Args: DeserializeOwned + JsonSchema;
    type Output: Serialize + JsonSchema;

    /// How it is used: the comment over its declaration in the system
    /// prompt, lines after the first indented by two spaces.
    fn guide() -> String;

    fn run(
        context: &Context,
        args: Self::Args,
    ) -> impl Future<Output = Result<Self::Output, Failure>> + Send;
}

/// A tool with its types gone: what max's service lists and calls, and
/// what the system prompt declares.
pub struct Spec {
    pub name: &'static str,
    pub description: &'static str,
    /// How it is used, as its declaration says it: `maxx <name> --help`
    /// shows it, which is all an agent is told of a tool.
    pub guide: String,
    pub turn: bool,
    /// JSON Schemas.
    pub input: Map<String, Value>,
    pub output: Map<String, Value>,
    /// TypeScript, for the system prompt.
    pub declaration: String,
    run: for<'a> fn(&'a Context, Value) -> BoxFuture<'a, Result<Value, Failure>>,
}

/// Every Max tool, the system prompt's in the order it declares them. The
/// prompt is the same for every request, so that it stays cached: the
/// list is fixed.
pub static TOOLS: LazyLock<Vec<Spec>> = LazyLock::new(|| {
    vec![
        spec::<History>(),
        spec::<WebSearch>(),
        spec::<File>(),
        spec::<SendImage>(),
        spec::<SendFile>(),
        spec::<RecallMessage>(),
        spec::<MuteMember>(),
        spec::<FindStickers>(),
        spec::<Ask>(),
        spec::<Answer>(),
        spec::<Config>(),
        spec::<Say>(),
        spec::<Wake>(),
        spec::<Rows>(),
    ]
});

/// One of the guest's own tools, as nix/local.json has it: what `maxx`
/// and a program call in the VM without the host, which the guest's
/// systemd or its runner does. Here for the system prompt alone, which
/// declares them with the host's.
#[derive(Deserialize)]
pub struct Local {
    pub name: String,
    /// Whether the system prompt declares it, as [`Tool::TURN`] says of
    /// one of the host's.
    pub turn: bool,
    guide: String,
    #[serde(rename = "inputSchema")]
    input: Map<String, Value>,
    #[serde(rename = "outputSchema")]
    output: Map<String, Value>,
}

impl Local {
    /// As [`Spec::declaration`]; one that takes nothing is called with
    /// nothing.
    fn declaration(&self) -> String {
        let properties = self.input.get("properties").and_then(Value::as_object);
        let takes = match properties {
            Some(properties) if !properties.is_empty() => {
                format!("args: {}", typescript(&self.input))
            }
            _ => String::new(),
        };
        format!(
            "/** {} */\n{}({takes}): Promise<{}>;",
            self.guide,
            self.name,
            typescript(&self.output)
        )
    }
}

/// The guest's own tools, in the order the system prompt declares them.
pub static LOCAL: LazyLock<Vec<Local>> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../../../nix/local.json"))
        .expect("nix/local.json is the guest's own tools")
});

/// The declarations of a turn's tools, for the system prompt: the host's,
/// and then the guest's own.
pub static DECLARATIONS: LazyLock<String> = LazyLock::new(|| {
    let host = TOOLS
        .iter()
        .filter(|tool| tool.turn)
        .map(|tool| tool.declaration.clone());
    let guest = LOCAL
        .iter()
        .filter(|tool| tool.turn)
        .map(Local::declaration);
    host.chain(guest).collect::<Vec<_>>().join("\n\n")
});

pub fn find(name: &str) -> Option<&'static Spec> {
    TOOLS.iter().find(|spec| spec.name == name)
}

impl Spec {
    /// Runs it, once its arguments keep to its schema's bounds.
    pub async fn call(&self, context: &Context, args: Value) -> Result<Value, Failure> {
        bounded(&self.input, &args, "")
            .map_err(|wrong| Failure::new("bad_arguments", format!("{}: {wrong}", self.name)))?;
        (self.run)(context, args).await
    }
}

fn spec<T: Tool>() -> Spec {
    let (input, output) = (schema::<T::Args>(true), schema::<T::Output>(false));
    let guide = T::guide();
    let declaration = format!(
        "/** {guide} */\n{}(args: {}): Promise<{}>;",
        T::NAME,
        typescript(&input),
        typescript(&output),
    );
    Spec {
        name: T::NAME,
        description: T::DESCRIPTION,
        guide,
        turn: T::TURN,
        input,
        output,
        declaration,
        run: run::<T>,
    }
}

fn run<T: Tool>(context: &Context, args: Value) -> BoxFuture<'_, Result<Value, Failure>> {
    Box::pin(async move {
        let args = arguments(T::NAME, args)?;
        let output = T::run(context, args).await?;
        serde_json::to_value(output).map_err(|error| {
            warn!(%error, tool = T::NAME, "a tool's result isn't JSON");
            internal()
        })
    })
}

/// `T`'s JSON Schema, as read for the arguments or written for a result:
/// inline, its root an object, as a tool's arguments and result are, and only its fields'
/// descriptions, of the arguments'.
fn schema<T: JsonSchema>(arguments: bool) -> Map<String, Value> {
    let settings = SchemaSettings::draft2020_12().with(|settings| {
        settings.inline_subschemas = true;
        settings.meta_schema = None;
    });
    let settings = if arguments {
        settings.for_deserialize()
    } else {
        settings.for_serialize()
    };
    let Value::Object(mut schema) = settings.into_generator().into_root_schema_for::<T>().into()
    else {
        unreachable!("a tool's types are objects");
    };
    tidy(&mut schema, false, arguments);
    // One of several objects.
    if !schema.contains_key("type") {
        schema.shift_insert(0, "type".into(), "object".into());
    }
    schema
}

/// Without titles, formats (the integers' widths, which serde checks), and
/// the descriptions of what isn't a field: the types' own documentation.
fn tidy(schema: &mut Map<String, Value>, field: bool, described: bool) {
    schema.shift_remove("title");
    schema.shift_remove("format");
    if !(field && described) {
        schema.shift_remove("description");
    }
    for (key, value) in schema.iter_mut() {
        let fields = key == "properties";
        let schemas: Vec<&mut Value> = match value {
            Value::Object(nested) if fields => nested.values_mut().collect(),
            Value::Array(variants) if key == "anyOf" => variants.iter_mut().collect(),
            nested @ Value::Object(_) if key == "items" => vec![nested],
            _ => Vec::new(),
        };
        for nested in schemas {
            if let Value::Object(nested) = nested {
                tidy(nested, fields, described);
            }
        }
    }
}

/// The TypeScript type of a schema, as far as Max's tools go: objects,
/// arrays, unions, strings, numbers, booleans and null.
fn typescript(schema: &Map<String, Value>) -> String {
    members(schema).join(" | ")
}

/// The types a schema is one of.
fn members(schema: &Map<String, Value>) -> Vec<String> {
    if let Some(Value::Array(variants)) = schema.get("anyOf") {
        return variants
            .iter()
            .filter_map(Value::as_object)
            .flat_map(members)
            .collect();
    }
    let one = |name: &Value| match name.as_str() {
        Some("string") => "string".to_owned(),
        Some("integer" | "number") => "number".to_owned(),
        Some("boolean") => "boolean".to_owned(),
        Some("null") => "null".to_owned(),
        Some("array") => array(schema),
        Some("object") => object(schema),
        _ => "unknown".to_owned(),
    };
    match schema.get("type") {
        Some(Value::Array(names)) => names.iter().map(one).collect(),
        Some(name) => vec![one(name)],
        None => vec!["unknown".to_owned()],
    }
}

fn array(schema: &Map<String, Value>) -> String {
    let items = schema.get("items").and_then(Value::as_object);
    match items.map(members).unwrap_or_default().as_slice() {
        [one] => format!("{one}[]"),
        [] => "unknown[]".to_owned(),
        many => format!("({})[]", many.join(" | ")),
    }
}

fn object(schema: &Map<String, Value>) -> String {
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return "object".to_owned();
    };
    let required = schema.get("required").and_then(Value::as_array);
    let fields: Vec<String> = properties
        .iter()
        .map(|(name, property)| {
            // A schema that is `true` takes any JSON.
            let types = property
                .as_object()
                .map_or_else(|| vec!["unknown".to_owned()], members);
            if required.is_some_and(|required| required.iter().any(|field| field == name)) {
                format!("{name}: {}", types.join(" | "))
            } else {
                // Left out, or null: the same to a program.
                let types: Vec<String> = types.into_iter().filter(|name| name != "null").collect();
                format!("{name}?: {}", types.join(" | "))
            }
        })
        .collect();
    format!("{{ {} }}", fields.join("; "))
}

/// Whether `value` keeps to the lengths and ranges `schema` bounds it
/// with, or what at `path` doesn't. serde checks the rest as it reads the
/// arguments.
fn bounded(schema: &Map<String, Value>, value: &Value, path: &str) -> Result<(), String> {
    if let Some(Value::Array(variants)) = schema.get("anyOf") {
        let mut variants = variants.iter().filter_map(Value::as_object);
        return match variants.find(|variant| admits(variant, value)) {
            Some(variant) => bounded(variant, value, path),
            None => Ok(()),
        };
    }
    let bound = |key: &str| schema.get(key).filter(|bound| bound.is_number());
    match value {
        Value::String(text) => {
            // In characters, as JSON Schema counts.
            let length = text.chars().count() as u64;
            let (least, most) = (bound("minLength"), bound("maxLength"));
            if let Some(least) = least.and_then(Value::as_u64)
                && length < least
            {
                return Err(match least {
                    1 => format!("{path} is empty"),
                    _ => format!("{path} is at least {least} characters"),
                });
            }
            if let Some(most) = most.and_then(Value::as_u64)
                && length > most
            {
                return Err(format!("{path} is at most {most} characters"));
            }
        }
        Value::Number(number) => {
            let number = number.as_f64().unwrap_or_default();
            let (least, most) = (bound("minimum"), bound("maximum"));
            let below = least
                .and_then(Value::as_f64)
                .is_some_and(|least| number < least);
            let above = most
                .and_then(Value::as_f64)
                .is_some_and(|most| number > most);
            match (least, most) {
                (Some(least), Some(most)) if below || above => {
                    return Err(format!("{path} is from {least} to {most}"));
                }
                (Some(least), None) if below => return Err(format!("{path} is at least {least}")),
                (None, Some(most)) if above => return Err(format!("{path} is at most {most}")),
                _ => {}
            }
        }
        Value::Object(fields) => {
            let properties = schema.get("properties").and_then(Value::as_object);
            for (name, field) in fields {
                let property = properties.and_then(|properties| properties.get(name));
                if let Some(property) = property.and_then(Value::as_object) {
                    let path = if path.is_empty() {
                        name.clone()
                    } else {
                        format!("{path}.{name}")
                    };
                    bounded(property, field, &path)?;
                }
            }
        }
        Value::Array(items) => {
            if let Some(schema) = schema.get("items").and_then(Value::as_object) {
                for (index, item) in items.iter().enumerate() {
                    bounded(schema, item, &format!("{path}[{index}]"))?;
                }
            }
        }
        Value::Null | Value::Bool(_) => {}
    }
    Ok(())
}

/// Whether a value is of one of the schema's types.
fn admits(schema: &Map<String, Value>, value: &Value) -> bool {
    if let Some(Value::Array(variants)) = schema.get("anyOf") {
        return variants
            .iter()
            .filter_map(Value::as_object)
            .any(|variant| admits(variant, value));
    }
    let is = |name: &Value| match (name.as_str(), value) {
        (Some("string"), Value::String(_))
        | (Some("number"), Value::Number(_))
        | (Some("boolean"), Value::Bool(_))
        | (Some("null"), Value::Null)
        | (Some("array"), Value::Array(_))
        | (Some("object"), Value::Object(_)) => true,
        (Some("integer"), Value::Number(number)) => number.is_i64() || number.is_u64(),
        _ => false,
    };
    match schema.get("type") {
        Some(Value::Array(names)) => names.iter().any(is),
        Some(name) => is(name),
        None => true,
    }
}

#[cfg(test)]
mod tests;
