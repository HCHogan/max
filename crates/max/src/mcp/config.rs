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
        description = "说完话后空闲多少秒结束这一轮；0 是恢复默认"
    )]
    idle_window_secs: Option<u64>,
    #[schemars(
        range(min = 0, max = *Setting::CallTimeSecs.range().end()),
        description = "程序和命令每次调 Max 的工具最多等多少秒；0 是恢复默认"
    )]
    call_time_secs: Option<u64>,
    #[schemars(
        range(min = 0, max = *Setting::CommandsAtOnce.range().end()),
        description = "最多同时跑几个后台命令；0 是恢复默认"
    )]
    commands_at_once: Option<u64>,
}

#[derive(Serialize, JsonSchema)]
pub struct Limits {
    idle_window_secs: Shown,
    call_time_secs: Shown,
    commands_at_once: Shown,
}

/// A limit as it is now, and what it is when nobody has set it.
#[derive(Serialize, JsonSchema)]
pub struct Shown {
    value: u64,
    default: u64,
}

impl Tool for Config {
    const NAME: &'static str = "config";
    const DESCRIPTION: &'static str =
        "看或改本群的几项设置：一轮空闲多久结束、调工具最多等多久、最多同时跑几个后台命令。";
    const JOB: bool = false;

    type Args = Args;
    type Output = Limits;

    fn guide() -> String {
        let range = |setting: Setting| {
            let range = setting.range();
            format!("{}–{}", range.start(), range.end())
        };
        format!(
            "看或改本群的几项设置。不给参数就只看；给了就改，0 是恢复默认。返回每项现在的值和默认值。改不改由你判断：有人请你改、理由说得通，或者你确实需要时再改，改完简短说一声。群管理员也能用 /config 改，谁后改算谁的。\n  \
            idle_window_secs：你说完话后空闲多少秒结束这一轮（{}）。窗口里再被叫，你还拿着这一轮查到的东西；结束后再被叫是新的一轮，从记录重新读起。默认跟着模型走。马上生效，这一轮也算。\n  \
            call_time_secs：程序和命令里每次调 Max 的工具（包括 max.video、max.file）最多等多少秒（{}）。转长视频、拷大文件超时了就调大。从下一次 run_code、shell 起生效。\n  \
            commands_at_once：最多同时跑几个后台命令（{}）。马上生效。",
            range(Setting::IdleWindowSecs),
            range(Setting::CallTimeSecs),
            range(Setting::CommandsAtOnce),
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Limits, Failure> {
        let Some(poster) = context.caller.poster() else {
            return Err(Failure::new("not_here", "这里改不了设置"));
        };
        let given = [
            (Setting::IdleWindowSecs, args.idle_window_secs),
            (Setting::CallTimeSecs, args.call_time_secs),
            (Setting::CommandsAtOnce, args.commands_at_once),
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
                        "{} 要么是 0（恢复默认），要么在 {} 到 {} 之间",
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
            commands_at_once: shown(Setting::CommandsAtOnce)?,
        })
    }
}

#[cfg(test)]
mod tests;
