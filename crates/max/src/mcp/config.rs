//! `config`: the limits Max sets for its conversation, as `/config` does
//! for its people; the last to set one wins. The actor applies and saves
//! them. See "Settings a conversation sets" in docs/rust-rewrite.md.

use max_core::limits::Setting;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure, internal};
use crate::conversation::Configured;

pub struct Config;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        range(min = 0, max = *Setting::IdleWindowSecs.range().end()),
        description = "seconds a turn idles after it last spoke before it ends; 0 is back to the default"
    )]
    idle_window_secs: Option<u64>,
    #[schemars(
        range(min = 0, max = *Setting::CallTimeSecs.range().end()),
        description = "seconds a program or a command waits at most for each call of a Max tool; 0 is back to the default"
    )]
    call_time_secs: Option<u64>,
}

#[derive(Serialize, JsonSchema)]
pub struct Limits {
    idle_window_secs: Shown,
    call_time_secs: Shown,
}

/// A limit as it is now, and what it is when nobody has set it.
#[derive(Serialize, JsonSchema)]
pub struct Shown {
    value: u64,
    default: u64,
}

impl Tool for Config {
    const NAME: &'static str = "config";
    const DESCRIPTION: &'static str = "Shows or sets a few of this chat's settings: how long an idle turn lasts, and how long a tool call may take.";

    type Args = Args;
    type Output = Limits;

    fn guide() -> String {
        let range = |setting: Setting| {
            let range = setting.range();
            format!("{}–{}", range.start(), range.end())
        };
        format!(
            "Shows or sets a few of this chat's settings. Without arguments it only shows; one given is set, and 0 puts it back to the default. Returns each one's value now and its default. Whether to change one is yours to judge: when someone asks and the reason holds, or when you do need it; say so briefly afterwards. A group's admins can set them too, with /config, and the last to set one wins.\n  \
            idle_window_secs: how many seconds after you last spoke an idle turn ends ({}). Called again within the window, you still have what this turn found; called after it, a new turn starts and reads from the records again. The default follows the model. In force at once, for this turn too.\n  \
            call_time_secs: how many seconds a program or a command waits at most for each call of a Max tool, max.video and max.file among them ({}). Raise it when converting a long video or copying a big file runs out of time. In force from the next run_code or shell.",
            range(Setting::IdleWindowSecs),
            range(Setting::CallTimeSecs),
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Limits, Failure> {
        let Some(poster) = context.caller.poster() else {
            return Err(Failure::new(
                "not_here",
                "settings can't be changed from here",
            ));
        };
        let given = [
            (Setting::IdleWindowSecs, args.idle_window_secs),
            (Setting::CallTimeSecs, args.call_time_secs),
        ];
        let mut changes = Vec::new();
        for (setting, value) in given {
            let Some(value) = value else {
                continue;
            };
            let range = setting.range();
            if value != 0 && !range.contains(&value) {
                return Err(Failure::new(
                    "bad_arguments",
                    format!(
                        "{} is either 0 (back to the default) or from {} to {}",
                        setting.name(),
                        range.start(),
                        range.end()
                    ),
                ));
            }
            changes.push((setting, (value != 0).then_some(value)));
        }
        let configured = poster
            .configure(changes)
            .await
            .map_err(|message| Failure::new("not_configured", message))?;
        let shown = |setting: Setting| {
            let one = configured.iter().find(|one| one.setting == setting);
            one.map(|&Configured { value, default, .. }| Shown { value, default })
                .ok_or_else(internal)
        };
        Ok(Limits {
            idle_window_secs: shown(Setting::IdleWindowSecs)?,
            call_time_secs: shown(Setting::CallTimeSecs)?,
        })
    }
}

#[cfg(test)]
mod tests;
