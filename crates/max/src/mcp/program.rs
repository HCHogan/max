//! What the programs Max keeps in the group's VM are for, and the system
//! prompt doesn't declare: `say`, which says something in the group as
//! Max would, and `wake`, which wakes Max. A turn says things in its own
//! output, and is awake; its programs may call these all the same. See
//! "Resident programs" in docs/rust-rewrite.md.

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
        description = "what to say, written as your own replies are: [reply#id], [mention#id], [sticker#id.n], [image#id.n], [split], and a blank line between messages"
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
    const DESCRIPTION: &'static str = "Says something in this chat as Max, written as Max's replies are; returns the numbers of the messages sent.";
    const TURN: bool = false;

    type Args = SayArgs;
    type Output = Said;

    fn guide() -> String {
        "Says something in this chat as Max, written as Max's replies are; as many messages as it is split into.".to_owned()
    }

    async fn run(context: &Context, SayArgs { text }: SayArgs) -> Result<Said, Failure> {
        let Some(poster) = &context.poster else {
            return Err(Failure::new("unavailable", "nothing can be said from here"));
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
            return Err(Failure::new("nothing", "there was nothing in it to send"));
        }
        // Outside code, where it would be a placeholder; the shell
        // swallowing a script's `${…}` as Max writes it does this
        // (2026-11-05).
        let unfilled = segments.iter().flat_map(|segment| &segment.unfilled);
        if let Some(marker) = unfilled.into_iter().next() {
            return Err(Failure::new(
                "unfilled",
                format!(
                    "{marker} has an empty id, or one that isn't a number: a variable the program didn't fill in? Nothing was sent."
                ),
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
            return Err(Failure::new("not_sent", format!("not sent: {why}")));
        }
        let sent: Vec<String> = messages.iter().map(|id| format!("#{id}")).collect();
        let message = format!("sent {}; {unsent} not sent: {why}", sent.join(", "));
        Err(Failure::new("not_sent", message))
    }
}

pub struct Wake;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WakeArgs {
    #[schemars(
        length(min = 1, max = LONGEST),
        description = "what Max is shown: what happened"
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
    const DESCRIPTION: &'static str =
        "Wakes Max and shows it some text; each wake is a turn of Max's.";
    const TURN: bool = false;

    type Args = WakeArgs;
    type Output = Woken;

    fn guide() -> String {
        "Wakes Max and shows it some text.".to_owned()
    }

    async fn run(context: &Context, WakeArgs { text }: WakeArgs) -> Result<Woken, Failure> {
        let Some(poster) = &context.poster else {
            return Err(Failure::new("unavailable", "Max can't be woken from here"));
        };
        let said = poster
            .wake(text)
            .await
            .map_err(|why| Failure::new("not_woken", why))?;
        Ok(Woken { said })
    }
}
