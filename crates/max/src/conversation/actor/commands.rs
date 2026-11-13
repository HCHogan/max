//! Running commands. The answer is said in the same conversation, as a row
//! of Max's outside any turn: QQ gives no way from a group member's id to a
//! private chat with them. It doesn't quote the command, which is right
//! above it, and reads like a log: terse, in English, the result alone,
//! in a code block (see `command::answer`). Like the command, it is in the
//! next core's context, as the host's words.

use std::fmt::Write;
use std::time::Duration;

use chrono::TimeDelta;

use max_core::message::{Platform, Role};
use max_db::platform::ConversationKind;
use tokio::time::timeout;

use super::*;
use crate::bind::Pending;
use crate::command::{self, Command, Persona};
use crate::conversation::ingest::Committed;

mod spent;

use self::spent::Spent;

/// How long `/status` waits for the guest to say how it is, and for
/// /work to be counted: the actor does nothing else meanwhile.
const VM_WAIT: Duration = Duration::from_secs(2);
/// The units `/status` gives a line each; of more, it says how many.
const UNITS_SHOWN: usize = 12;

/// What the conversation's VM said when `/status` asked how it is.
enum Guest {
    Up(vm::About),
    /// It isn't running, and wasn't started for the asking.
    Off,
    /// It runs, or is booting, and didn't say in time.
    Silent,
}

/// Who may run what. Commands that change one conversation are also its
/// group's owner's and admins'; those that cost money are also the other
/// person's in a private chat, which is theirs; binding a group, and
/// linking two conversations, is only for Max's owners.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Rank {
    Anyone,
    Admin,
    /// The other person in a private chat.
    ChatOwner,
    Owner,
}

impl Conversation {
    pub(super) async fn command(&mut self, committed: &Committed, command: Command) -> Result<()> {
        let rank = if self.shared.owners.contains(&committed.sender.principal) {
            Rank::Owner
        } else if self.place.kind == ConversationKind::Direct {
            Rank::ChatOwner
        } else if matches!(
            committed.message.sender.role,
            Some(Role::Owner | Role::Admin)
        ) {
            Rank::Admin
        } else {
            Rank::Anyone
        };
        let needs = match &command {
            Command::Status => Rank::Anyone,
            Command::Model(None) | Command::Effort(None) | Command::Proactive(None) => Rank::Anyone,
            Command::Persona(Persona::Show) | Command::Clear { all: false } => Rank::Anyone,
            Command::Model(Some(argument)) if argument == "list" => Rank::Anyone,
            Command::Config { value: None, .. } => Rank::Anyone,
            Command::Kill
            | Command::Stop
            | Command::Start
            | Command::Persona(_)
            | Command::Clear { .. }
            | Command::Unclear
            | Command::Config { .. } => Rank::Admin,
            Command::Model(_) | Command::Effort(_) | Command::Proactive(_) => Rank::ChatOwner,
            Command::Bind(_) | Command::Link(_) | Command::Unlink(_) => Rank::Owner,
        };
        if rank < needs {
            let who = if needs >= Rank::ChatOwner {
                "Max's owners"
            } else {
                "the group owner and admins"
            };
            return self.answer(&format!("refused: {who} only")).await;
        }
        let answer = match command {
            Command::Status => self.status().await?,
            // Not answered: whoever ran it sees Max stop.
            Command::Kill => return self.kill(committed, "kill").await,
            Command::Stop => self.stop_replying(committed).await?,
            Command::Start => self.start_replying().await?,
            Command::Model(argument) => self.model(argument.as_deref()).await?,
            Command::Effort(argument) => self.effort(argument).await?,
            Command::Proactive(on) => self.proactive(on).await?,
            Command::Persona(persona) => self.persona(persona).await?,
            Command::Clear { all: false } => {
                let how = command::how(self.place.kind, &self.place.my_name, "/clear --all");
                format!("confirm: send {how} to clear the context")
            }
            Command::Clear { all: true } => {
                self.settings.cleared_upto = Some(committed.message.id);
                self.save_settings().await?;
                let how = command::how(self.place.kind, &self.place.my_name, "/unclear");
                format!("cleared: earlier messages are out of the context; {how} brings them back")
            }
            Command::Unclear => self.unclear().await?,
            Command::Config { name, value } => {
                let by = &committed.message.sender.name;
                self.config(name.as_deref(), value.as_deref(), by).await?
            }
            Command::Bind(argument) => self.bind(committed, argument.as_deref()).await?,
            Command::Link(code) => self.link(code.as_deref()).await?,
            Command::Unlink(handle) => self.unlink(handle.as_deref()).await?,
        };
        self.answer(&answer).await
    }

    /// Ends the running core quietly, for `/kill` and `/stop`, the command
    /// `name`. The background commands and agents are the guest's units,
    /// and it is told to stop them: a person's way to stop what runs
    /// without asking Max.
    async fn kill(&mut self, committed: &Committed, name: &str) -> Result<()> {
        // Nothing the model has seen wakes it again, held or not.
        self.seen = self.head;
        if self.core.is_some() {
            let reason = format!("{} ran /{name}", committed.message.sender.name);
            self.end(End::Kill(reason)).await?;
        }
        self.stop_commands();
        Ok(())
    }

    /// Has the guest stop every background command, if the VM runs: one
    /// stopped on request tells nobody. In a task of its own: the actor
    /// waits on a guest only for `/status`, and not for long.
    fn stop_commands(&mut self) {
        let Some(vms) = self.shared.vms.clone() else {
            return;
        };
        let conversation = self.place.conversation;
        self.side.spawn(move |_| async move {
            let Some(vm) = vms.running(conversation).await else {
                return;
            };
            match vm.ask("maxx units stop-all '{}'").await {
                Ok(said) => {
                    // The last line: the group's .bashrc may write first.
                    let stopped = said
                        .lines()
                        .last()
                        .and_then(|line| serde_json::from_str::<vm::Stopped>(line).ok())
                        .map(|stopped| stopped.stopped)
                        .unwrap_or_default();
                    if !stopped.is_empty() {
                        info!(%conversation, ?stopped, "the guest's jobs are stopped");
                    }
                }
                Err(error) => {
                    warn!(%conversation, error = format!("{error:#}"), "couldn't stop the guest's jobs");
                }
            }
        });
    }

    /// `/stop`: `/kill`, and then nothing starts a turn until `/start`,
    /// though every message is still recorded. Saved, so it outlasts a
    /// restart.
    async fn stop_replying(&mut self, committed: &Committed) -> Result<String> {
        if self.settings.stopped {
            return Ok("skipped: already stopped".to_owned());
        }
        self.settings.stopped = true;
        self.save_settings().await?;
        // An @ held for the rest of its sentence, and chatter waiting for
        // the classifier, wake nobody now.
        self.intent.forget();
        // Nor is anything another conversation asked answered.
        self.refuse_questions(asking::STOPPED_THERE);
        self.kill(committed, "stop").await?;
        let how = command::how(self.place.kind, &self.place.my_name, "/start");
        Ok(format!(
            "stopped: messages are still recorded, but Max won't reply until {how}"
        ))
    }

    /// `/start`: what was said while stopped isn't answered, but it is in
    /// the next turn's context.
    async fn start_replying(&mut self) -> Result<String> {
        if !self.settings.stopped {
            return Ok("skipped: not stopped".to_owned());
        }
        self.settings.stopped = false;
        self.save_settings().await?;
        Ok("started: Max replies again".to_owned())
    }

    /// Takes `/clear --all` back: what came before its mark is in the
    /// context again, as far back as the tail goes.
    async fn unclear(&mut self) -> Result<String> {
        if self.settings.cleared_upto.take().is_none() {
            return Ok("skipped: never cleared".to_owned());
        }
        self.save_settings().await?;
        Ok("uncleared: the messages before the clear are back in the context".to_owned())
    }

    async fn answer(&mut self, body: &str) -> Result<()> {
        let draft = Draft {
            reply_to: None,
            nodes: vec![DraftNode::Text {
                text: command::answer(body),
            }],
        };
        self.say(draft, None, None, By::Host, None).await?;
        Ok(())
    }

    pub(super) async fn save_settings(&mut self) -> Result<()> {
        let mut conn = self.shared.services.pool.acquire().await?;
        platform::save_settings(
            &mut conn,
            self.place.conversation,
            &self.settings,
            Utc::now(),
        )
        .await?;
        Ok(())
    }

    /// A card like the Haskell version's `!version`, in English: maxx and
    /// its commit, then a key and its value a line, a line under a key's
    /// first one going without the key. `/model` and `/persona` show
    /// those.
    async fn status(&self) -> Result<String> {
        let [may_ask, asked_by] = self.linked().await?;
        let settings = &self.settings;
        let mut lines = vec![format!("maxx {}", crate::COMMIT)];
        let mut line = |key: &str, value: String| lines.push(format!("{key:<10}{value}"));
        for (key, value) in self.machine().await {
            line(key, value);
        }
        // What the next reply uses; a running core keeps the one it began with.
        let next = self
            .shared
            .models
            .turn(settings.model.as_deref(), settings.effort.as_deref())
            .ok()
            .map(|chosen| model(&chosen));
        let configured = settings.model.as_deref().unwrap_or("default");
        line(
            "model",
            next.clone()
                .unwrap_or_else(|| format!("{configured} (not configured)")),
        );
        let proactive = if settings.proactive { "on" } else { "off" };
        line("proactive", proactive.to_owned());
        if settings.stopped {
            line("state", "stopped".to_owned());
        }
        if let Some(set) = self.config_status() {
            line("config", set);
        }
        if let Some(peers) = may_ask {
            line("may ask", peers);
        }
        if let Some(peers) = asked_by {
            line("asked by", peers);
        }
        line(
            "core",
            match &self.core {
                Some(a) => {
                    let mut core = format!(
                        "t#{} · {} · round {}",
                        a.ordinal,
                        span(a.started.elapsed()),
                        a.run.round()
                    );
                    let running = model(&a.chosen);
                    if next.as_ref() != Some(&running) {
                        let _ = write!(core, " · {running}");
                    }
                    core
                }
                None => "idle".to_owned(),
            },
        );
        if let Some(woken) = self.woken.summary(Instant::now()) {
            line("woken", woken);
        }
        if let Some(mark) = settings.cleared_upto {
            line("context", format!("after #{mark}"));
        }
        for (key, spent) in self.spent().await? {
            line(key, spent.to_string());
        }
        let mut up = span(self.shared.started.elapsed());
        if let Some(host) = host_uptime() {
            let _ = write!(up, " · host {}", span(host));
        }
        line("uptime", up);
        Ok(lines.join("\n"))
    }

    /// The lines of `/status` about the conversation's VM: the NixOS its
    /// guest runs and the memory in use there, as the guest says them
    /// when it runs; how much of the disk /work takes, which the host
    /// counts on its own side; and Max's units, the files in /work, each
    /// as the guest's systemd has it, or by name alone when nothing says.
    /// The guest is asked while /work is counted, and neither is waited
    /// for longer than `VM_WAIT`.
    async fn machine(&self) -> Vec<(&'static str, String)> {
        let conversation = self.place.conversation;
        let work = self.shared.vm_dir.as_deref();
        let work = work.map(|dir| vm::work(dir, conversation));
        let names = work.as_deref().map(vm::units).unwrap_or_default();
        let guest = async {
            let vms = self.shared.vms.as_ref()?;
            let asked = async {
                let Some(vm) = vms.running(conversation).await else {
                    return Guest::Off;
                };
                match vm.about(&names).await {
                    Ok(about) => Guest::Up(about),
                    Err(error) => {
                        warn!(%conversation, error = format!("{error:#}"), "the guest didn't say how it is");
                        Guest::Silent
                    }
                }
            };
            Some(timeout(VM_WAIT, asked).await.unwrap_or(Guest::Silent))
        };
        let taken = async {
            let work = work.clone()?;
            let until = std::time::Instant::now() + VM_WAIT;
            let counted = tokio::task::spawn_blocking(move || vm::taken(&work, until));
            counted.await.ok().flatten()
        };
        let (guest, taken) = tokio::join!(guest, taken);

        let mut lines = Vec::new();
        let mut units = Vec::new();
        match guest {
            Some(Guest::Up(about)) => {
                let arch = std::env::consts::ARCH;
                lines.push(("vm", format!("NixOS {} · {arch}", about.version)));
                let memory = format!("{} of {}", size(about.used), size(about.memory));
                lines.push(("memory", memory));
                units = about.units;
            }
            Some(Guest::Off) => lines.push(("vm", "off".to_owned())),
            Some(Guest::Silent) => lines.push(("vm", "no answer".to_owned())),
            None => {}
        }
        match taken {
            Some((bytes, true)) => lines.push(("/work", size(bytes))),
            // Not all of it was counted in time.
            Some((bytes, false)) => lines.push(("/work", format!("over {}", size(bytes)))),
            None => {}
        }
        let mut key = "units";
        for name in names.iter().take(UNITS_SHOWN) {
            let said = units.iter().find(|unit| unit.name == *name);
            lines.push((key, said.map_or_else(|| name.clone(), unit)));
            key = "";
        }
        if let Some(more) = names
            .len()
            .checked_sub(UNITS_SHOWN)
            .filter(|more| *more > 0)
        {
            lines.push(("", format!("and {more} more")));
        }
        lines
    }

    /// What this conversation's model calls used in the last day and
    /// week.
    async fn spent(&self) -> Result<Vec<(&'static str, Spent)>> {
        let mut conn = self.shared.services.pool.acquire().await?;
        let models = &self.shared.models;
        let mut spent = Vec::new();
        for (key, days) in [("24h", 1), ("7d", 7)] {
            let since = Utc::now() - TimeDelta::days(days);
            let used = usage::used(&mut conn, self.place.conversation, since).await?;
            let price = |provider: &str, model: &str| models.price(provider, model);
            spent.push((key, Spent::sum(&used, price)));
        }
        Ok(spent)
    }

    async fn model(&mut self, argument: Option<&str>) -> Result<String> {
        let models = &self.shared.models;
        let list = models.references().join(", ");
        let current = self.settings.model.clone();
        let Some(reference) = argument.filter(|argument| *argument != "list") else {
            let current = match models.turn(current.as_deref(), None) {
                Ok(chosen) => chosen.reference(),
                Err(_) => current.unwrap_or_default(),
            };
            return Ok(format!("current: {current}\navailable: {list}"));
        };
        if let Err(error) = models.choose(reference, None) {
            return Ok(format!("error: no such model ({error})\navailable: {list}"));
        }
        self.settings.model = (reference != "default").then(|| reference.to_owned());
        self.save_settings().await?;
        Ok(format!("switched to {reference}; {}", self.takes_effect()))
    }

    async fn effort(&mut self, argument: Option<String>) -> Result<String> {
        let Some(level) = argument else {
            let effort = self.settings.effort.as_deref().unwrap_or("default");
            return Ok(format!("effort: {effort}"));
        };
        let answer = format!("effort set to {level}; {}", self.takes_effect());
        self.settings.effort = (level != "default").then_some(level);
        self.save_settings().await?;
        Ok(answer)
    }

    async fn proactive(&mut self, on: Option<bool>) -> Result<String> {
        let Some(on) = on else {
            let state = if self.settings.proactive { "on" } else { "off" };
            return Ok(format!("proactive: {state}"));
        };
        self.settings.proactive = on;
        self.intent.set_proactive(on);
        self.save_settings().await?;
        Ok(if on {
            "proactive on: Max may join in unasked"
        } else {
            "proactive off: Max replies only when @-ed or replied to"
        }
        .to_owned())
    }

    async fn persona(&mut self, persona: Persona) -> Result<String> {
        let answer = match persona {
            Persona::Show => {
                return Ok(match &self.settings.persona {
                    Some(persona) => format!("persona:\n{persona}"),
                    None => "persona: default".to_owned(),
                });
            }
            Persona::Reset => {
                self.settings.persona = None;
                "persona reset to the default"
            }
            Persona::Set(text) => {
                self.settings.persona = Some(text);
                "persona updated"
            }
        };
        self.save_settings().await?;
        Ok(format!("{answer}; {}", self.takes_effect()))
    }

    /// When a change of model, effort or persona shows: a running core
    /// keeps what it started with until it ends, which is mostly when it
    /// has been idle for its window.
    fn takes_effect(&self) -> String {
        let Some(a) = &self.core else {
            return "takes effect from the next reply".to_owned();
        };
        let idle = self.idle_window(a).as_secs();
        let idle = match (idle / 60, idle % 60) {
            (1, 0) => "a minute".to_owned(),
            (minutes, 0) => format!("{minutes} minutes"),
            _ => format!("{idle} seconds"),
        };
        format!("takes effect when the running turn ends, after {idle} idle")
    }

    /// The `/bind <码>` that bound this group, which the table hands over
    /// instead of running it.
    pub(super) async fn bound(&mut self, continued: bool) -> Result<()> {
        let text = if continued {
            "bound: the old group's history goes on here"
        } else {
            "bound: the history starts here"
        };
        self.answer(text).await
    }

    /// In a private chat, a code to bind a QQ group with; in a group, the
    /// group is bound already, or it wouldn't have an actor.
    async fn bind(&mut self, committed: &Committed, argument: Option<&str>) -> Result<String> {
        if self.place.kind != ConversationKind::Direct {
            return Ok("error: this group is bound already, and can't be bound again".to_owned());
        }
        let conversation = match argument {
            None => None,
            Some(group) => {
                let native_id = format!("group:{group}");
                let mut conn = self.shared.services.pool.acquire().await?;
                let found =
                    platform::conversation_of(&mut conn, Platform::QqLegacy, &native_id).await?;
                let Some(conversation) = found else {
                    return Ok(format!("error: no history of old group {group}"));
                };
                let bound = platform::endpoint_on(&mut conn, conversation, Platform::Qq).await?;
                if bound.is_some() {
                    return Ok(format!(
                        "error: old group {group}'s history goes on in another group already"
                    ));
                }
                Some(conversation)
            }
        };
        let pending = Pending {
            conversation,
            owner: committed.sender.principal,
        };
        let code = self.shared.binds.issue(pending, std::time::Instant::now());
        let target = match argument {
            Some(group) => format!("to go on with old group {group}'s history"),
            None => "to start a new history".to_owned(),
        };
        let how = command::how(ConversationKind::Group, &self.place.my_name, "/bind");
        Ok(format!(
            "code issued: send {how} {code} in the group to bind, {target}\nvalid for 10 minutes, once"
        ))
    }
}

/// A model as `/status` shows it: its reference, and the effort if set.
fn model(chosen: &Chosen) -> String {
    match &chosen.options.effort {
        Some(effort) => format!("{} · {effort}", chosen.reference()),
        None => chosen.reference(),
    }
}

/// The two largest units: 3d 4h, 2h 13m, 5m 12s, 12s.
fn span(duration: Duration) -> String {
    let s = duration.as_secs();
    let (d, h, m, s) = (s / 86400, s / 3600 % 24, s / 60 % 60, s % 60);
    if d > 0 {
        format!("{d}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m {s}s")
    } else {
        format!("{s}s")
    }
}

/// A unit as the guest's systemd has it: `web.service · running 3d 4h ·
/// 182M · 2 restarts`, with how long it has been so, the memory its
/// processes hold and how often systemd started it again;
/// `scrape.service · failed (exit-code) 5m 12s`; and `new.service · not
/// installed` for a file `maxx units apply` hasn't made a unit of.
fn unit(unit: &vm::Unit) -> String {
    let mut shown = unit.name.clone();
    match unit.load.as_str() {
        "loaded" => {}
        "not-found" => return shown + " · not installed",
        // A file systemd couldn't make a unit of: bad-setting, error.
        load => return format!("{shown} · {load}"),
    }
    let _ = write!(shown, " · {}", unit.state);
    if let Some(failure) = &unit.failure {
        let _ = write!(shown, " ({failure})");
    }
    if let Some(since) = unit.since {
        let _ = write!(shown, " {}", span(since));
    }
    if let Some(memory) = unit.memory {
        let _ = write!(shown, " · {}", size(memory));
    }
    match unit.restarts {
        0 => {}
        1 => shown.push_str(" · 1 restart"),
        restarts => {
            let _ = write!(shown, " · {restarts} restarts");
        }
    }
    shown
}

/// A size in bytes, to three figures in units of 1024: 812B, 264M, 1.21G.
fn size(bytes: u64) -> String {
    if bytes < 1000 {
        return format!("{bytes}B");
    }
    figures(bytes, 1024.0, &["K", "M", "G", "T"])
}

/// `count` to three figures, in the largest of `units` that leaves it
/// one or more, each `base` times the one before: 950, 1.23k, 12.3k,
/// 437M.
fn figures(count: u64, base: f64, units: &[&str]) -> String {
    let (mut value, mut unit) = (count as f64, "");
    for next in units {
        if value < 999.5 {
            break;
        }
        (value, unit) = (value / base, next);
    }
    if unit.is_empty() {
        return count.to_string();
    }
    let decimals = match value {
        _ if value < 9.995 => 2,
        _ if value < 99.95 => 1,
        _ => 0,
    };
    format!("{value:.decimals$}{unit}")
}

/// How long the host has been up, from /proc/uptime on Linux.
fn host_uptime() -> Option<Duration> {
    let uptime = std::fs::read_to_string("/proc/uptime").ok()?;
    let seconds: f64 = uptime.split_whitespace().next()?.parse().ok()?;
    Some(Duration::from_secs_f64(seconds))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_read_to_three_figures() {
        let read = [0, 812, 1000, 276 << 20, 1300 << 20, 16263 << 20, 3 << 40].map(size);
        assert_eq!(
            read,
            ["0B", "812B", "0.98K", "276M", "1.27G", "15.9G", "3.00T"]
        );
    }

    #[test]
    fn a_unit_shows_as_systemd_has_it() {
        let unit = |name: &str, state: &str, seconds| vm::Unit {
            name: name.to_owned(),
            load: "loaded".to_owned(),
            state: state.to_owned(),
            failure: None,
            since: Some(Duration::from_secs(seconds)),
            memory: None,
            restarts: 0,
        };
        let shown = [
            vm::Unit {
                memory: Some(182 << 20),
                restarts: 2,
                ..unit("web.service", "running", 273_600)
            },
            unit("poll.timer", "waiting", 41),
            vm::Unit {
                failure: Some("exit-code".to_owned()),
                memory: None,
                restarts: 1,
                ..unit("scrape.service", "failed", 312)
            },
            vm::Unit {
                since: None,
                ..unit("never.service", "dead", 0)
            },
            vm::Unit {
                load: "not-found".to_owned(),
                since: None,
                ..unit("new.service", "dead", 0)
            },
            vm::Unit {
                load: "bad-setting".to_owned(),
                ..unit("wrong.service", "dead", 5)
            },
        ]
        .map(|unit| super::unit(&unit));
        assert_eq!(
            shown,
            [
                "web.service · running 3d 4h · 182M · 2 restarts",
                "poll.timer · waiting 41s",
                "scrape.service · failed (exit-code) 5m 12s · 1 restart",
                "never.service · dead",
                "new.service · not installed",
                "wrong.service · bad-setting",
            ]
        );
    }
}
