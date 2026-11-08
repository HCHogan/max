//! What only the programs Max keeps in the group's VM call, outside any
//! turn: `say`, which says something in the group as Max would, and
//! `wake`, which wakes Max. A turn says things in its own output, and is
//! awake. See "Resident programs" in docs/rust-rewrite.md.

use max_core::ids::PrincipalId;
use max_core::project;
use max_core::segment::Segmenter;
use max_db::platform;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};

/// The longest text either takes, in characters.
const LONGEST: u32 = 4000;

pub struct Say;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SayArgs {
    #[schemars(
        length(min = 1, max = LONGEST),
        description = "要说的话，写法和你自己回话一样：[reply#id]、[mention#id]、[sticker#id.n]、[image#id.n]、[split]，空行分条"
    )]
    text: String,
}

#[derive(Serialize, JsonSchema)]
pub struct Said {
    /// The messages it became, in order.
    messages: Vec<i64>,
}

impl Tool for Say {
    const NAME: &'static str = "say";
    const DESCRIPTION: &'static str =
        "以 Max 的身份在本群说话，写法和 Max 回话一样；返回发出去的消息编号。";
    const JOB: bool = false;
    const TURN: bool = false;

    type Args = SayArgs;
    type Output = Said;

    fn guide() -> String {
        "以 Max 的身份在本群说话，写法和 Max 回话一样，分成几条就是几条消息。".to_owned()
    }

    async fn run(context: &Context, SayArgs { text }: SayArgs) -> Result<Said, Failure> {
        let Some(poster) = context.caller.poster() else {
            return Err(Failure::new("unavailable", "这里说不了话。"));
        };
        // As the model's output is read: a handle of someone the group
        // doesn't know stays text.
        let mentioned: Vec<PrincipalId> = project::mentioned(&text).into_iter().collect();
        let mut conn = context.services.pool.acquire().await?;
        let known = platform::roster(&mut conn, context.place.endpoint, &mentioned).await?;
        drop(conn);
        let mut segmenter =
            Segmenter::new(known.into_iter().map(|known| known.principal).collect());
        let mut segments = segmenter.push(&text);
        segments.extend(segmenter.finish());
        if segments.is_empty() {
            return Err(Failure::new("nothing", "没有能发的东西"));
        }
        // Outside code, where it would be a placeholder; the shell
        // swallowing a script's `${…}` as Max writes it does this
        // (2026-11-05).
        let unfilled = segments.iter().flat_map(|segment| &segment.unfilled);
        if let Some(marker) = unfilled.into_iter().next() {
            return Err(Failure::new(
                "unfilled",
                format!("{marker} 的编号是空的或者不是数字：程序里的变量没填进去？这条没发。"),
            ));
        }
        // All handed over before any is waited for: a say goes out whole,
        // as Max's own reply does, even once the program has stopped
        // waiting for it. Each message still says how it went.
        let sendings: Vec<_> = segments
            .into_iter()
            .map(|segment| poster.say(segment.draft))
            .collect();
        let mut messages = Vec::new();
        let (mut unsent, mut why) = (0, None);
        for sending in sendings {
            let outcome = match sending {
                Ok(sending) => sending.sent().await,
                Err(why) => Err(why),
            };
            match outcome {
                Ok(id) => messages.push(id.0),
                Err(reason) => {
                    unsent += 1;
                    why.get_or_insert(reason);
                }
            }
        }
        let Some(why) = why else {
            return Ok(Said { messages });
        };
        if messages.is_empty() {
            return Err(Failure::new("not_sent", format!("没发出去：{why}")));
        }
        let sent: Vec<String> = messages.iter().map(|id| format!("#{id}")).collect();
        let message = format!("发了 {}，{unsent} 条没发出去：{why}", sent.join("、"));
        Err(Failure::new("not_sent", message))
    }
}

pub struct Wake;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WakeArgs {
    #[schemars(
        length(min = 1, max = LONGEST),
        description = "给 Max 看的话：发生了什么"
    )]
    text: String,
}

#[derive(Serialize, JsonSchema)]
pub struct Woken {
    /// That Max was woken.
    said: String,
}

impl Tool for Wake {
    const NAME: &'static str = "wake";
    const DESCRIPTION: &'static str = "叫醒 Max，给它看一段话；每次都是 Max 的一轮。";
    const JOB: bool = false;
    const TURN: bool = false;

    type Args = WakeArgs;
    type Output = Woken;

    fn guide() -> String {
        "叫醒 Max，给它看一段话。".to_owned()
    }

    async fn run(context: &Context, WakeArgs { text }: WakeArgs) -> Result<Woken, Failure> {
        let Some(poster) = context.caller.poster() else {
            return Err(Failure::new("unavailable", "这里叫不醒 Max。"));
        };
        let said = poster
            .wake(text)
            .await
            .map_err(|why| Failure::new("not_woken", why))?;
        Ok(Woken { said })
    }
}
