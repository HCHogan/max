//! The limits a conversation sets for itself: with `/config`, or by Max
//! with its `config` tool, the last to set one winning over the other and
//! over the configuration file. See "Settings a conversation sets" in
//! docs/rust-rewrite.md.

use std::fmt::Write;

use max_core::limits::Setting;

use super::*;
use crate::conversation::Configured;

impl Conversation {
    /// How long `a` waits idle before it ends: this conversation's window,
    /// or its model's. A change applies to a running core at once.
    pub(super) fn idle_window(&self, a: &Active) -> Duration {
        self.settings
            .overrides
            .idle_window_secs
            .map_or(a.chosen.idle_window, Duration::from_secs)
    }

    /// The wall clock of a Max tool's call, for the programs and commands
    /// started now and the resident programs' calls.
    pub(super) fn call_time(&self) -> Duration {
        Duration::from_secs(self.value(Setting::CallTimeSecs))
    }

    /// How many background commands may run at once.
    pub(super) fn commands_at_once(&self) -> usize {
        usize::try_from(self.value(Setting::CommandsAtOnce)).unwrap_or(usize::MAX)
    }

    fn value(&self, setting: Setting) -> u64 {
        self.settings
            .overrides
            .get(setting)
            .unwrap_or_else(|| self.default_of(setting))
    }

    /// What `setting` is had nobody set it: the configuration file's, and
    /// the idle window the running core's model's, or the next one's.
    fn default_of(&self, setting: Setting) -> u64 {
        self.shared.limits.default_of(setting).unwrap_or_else(|| {
            let window = match &self.core {
                Some(a) => a.chosen.idle_window,
                None => self
                    .shared
                    .models
                    .idle_window(self.settings.model.as_deref()),
            };
            window.as_secs()
        })
    }

    /// Every limit as it is now.
    pub(super) fn configured(&self) -> Vec<Configured> {
        Setting::ALL
            .into_iter()
            .map(|setting| Configured {
                setting,
                value: self.value(setting),
                default: self.default_of(setting),
            })
            .collect()
    }

    /// Sets each of `changes`, None back to the default, as `by` asked;
    /// saved, so it outlasts a restart. The values are within their
    /// ranges: the command and the tool check them.
    pub(super) async fn configure(
        &mut self,
        changes: &[(Setting, Option<u64>)],
        by: &str,
    ) -> Result<()> {
        for &(setting, value) in changes {
            self.settings.overrides.set(setting, value);
            let name = setting.name();
            info!(conversation = %self.place.conversation, setting = name, ?value, by, "configured");
        }
        self.save_settings().await
    }

    /// `/config`: every limit; `/config <name>`: one; `/config <name>
    /// <value>` or `default` sets it, as `by` asked.
    pub(super) async fn config(
        &mut self,
        name: Option<&str>,
        value: Option<&str>,
        by: &str,
    ) -> Result<String> {
        let Some(name) = name else {
            let lines: Vec<String> = self
                .configured()
                .iter()
                .map(|configured| self.config_line(configured))
                .collect();
            return Ok(format!("this conversation's limits\n{}", lines.join("\n")));
        };
        let Some(setting) = Setting::find(name) else {
            let names: Vec<&str> = Setting::ALL.into_iter().map(Setting::name).collect();
            return Ok(format!(
                "error: no such setting; there are {}",
                names.join(", ")
            ));
        };
        let Some(value) = value else {
            let configured = self.configured();
            let one = configured.iter().find(|one| one.setting == setting);
            return Ok(one.map(|one| self.config_line(one)).unwrap_or_default());
        };
        let range = setting.range();
        let value = match value {
            "default" => None,
            number => match number.parse::<u64>() {
                Ok(number) if range.contains(&number) => Some(number),
                _ => {
                    return Ok(format!(
                        "error: {name} takes a number from {} to {}, or default",
                        range.start(),
                        range.end()
                    ));
                }
            },
        };
        self.configure(&[(setting, value)], by).await?;
        let now = self.value(setting);
        let set = match value {
            Some(_) => format!("{name} set to {now}"),
            None => format!("{name} back to the default, {now}"),
        };
        let effect = match setting {
            Setting::IdleWindowSecs | Setting::CommandsAtOnce => "takes effect now",
            Setting::CallTimeSecs => "takes effect from Max's next program or command",
        };
        Ok(format!("{set}; {effect}"))
    }

    /// A limit and its value, and its default when someone set it.
    fn config_line(&self, configured: &Configured) -> String {
        let Configured {
            setting,
            value,
            default,
        } = configured;
        let mut line = format!("{:<18}{value}", setting.name());
        if self.settings.overrides.get(*setting).is_some() {
            let _ = write!(line, " (default {default})");
        }
        line
    }

    /// The limits someone set, for `/status`.
    pub(super) fn config_status(&self) -> Option<String> {
        let set: Vec<String> = Setting::ALL
            .into_iter()
            .filter_map(|setting| {
                let value = self.settings.overrides.get(setting)?;
                Some(format!("{} {value}", setting.name()))
            })
            .collect();
        (!set.is_empty()).then(|| set.join(" · "))
    }
}
