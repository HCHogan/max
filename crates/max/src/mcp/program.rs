//! What only the programs Max keeps in the group's VM call, outside any
//! turn: `say`, which says something in the group as Max would, and
//! `wake`, which wakes Max. A turn says things in its own output, and is
//! awake. See "常驻程序" in docs/rust-rewrite.md.

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
        let mut messages = Vec::new();
        for segment in segments {
            match poster.post(segment.draft).await {
                Ok(id) => messages.push(id.0),
                Err(why) if messages.is_empty() => {
                    return Err(Failure::new("not_sent", format!("没发出去：{why}")));
                }
                Err(why) => {
                    let sent: Vec<String> = messages.iter().map(|id| format!("#{id}")).collect();
                    let message = format!("发了 {}，后面的没发出去：{why}", sent.join("、"));
                    return Err(Failure::new("not_sent", message));
                }
            }
        }
        Ok(Said { messages })
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
