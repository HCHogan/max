//! Running commands. The answer is said in the same conversation, as a row
//! of Max's outside any turn: QQ gives no way from a group member's id to a
//! private chat with them. It doesn't quote the command, which is right
//! above it, and reads like a log: terse, in English, `/name → result`,
//! in a code block (see `command::answer`). Like the command, it is in the
//! next core's context, as the host's words.

use std::fmt::Write;
use std::time::Duration;

use max_core::message::{Platform, Role};
use max_db::platform::ConversationKind;

use super::*;
use crate::bind::Pending;
use crate::command::{self, Command, Persona};
use crate::conversation::ingest::Committed;

/// Who may run what. Commands that change one conversation are also its
/// group's owner's and admins'; those that cost money are also the other
/// person's in a private chat, which is theirs; binding a group is only
/// for Max's owners.
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
            Command::Kill
            | Command::Stop
            | Command::Start
            | Command::Persona(_)
            | Command::Clear { .. }
            | Command::Unclear => Rank::Admin,
            Command::Model(_) | Command::Effort(_) | Command::Proactive(_) => Rank::ChatOwner,
            Command::Bind(_) => Rank::Owner,
        };
        let name = command.name();
        if rank < needs {
            let who = if needs >= Rank::ChatOwner {
                "Max's owners"
            } else {
                "the group owner and admins"
            };
            return self.answer(name, &format!("refused: {who} only")).await;
        }
        let answer = match command {
            Command::Status => self.status(),
            Command::Kill => {
                let jobs = self.kill(committed, name).await?;
                if jobs.is_empty() {
                    return Ok(());
                }
                stopped_jobs(&jobs)
            }
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
            Command::Bind(argument) => self.bind(committed, argument.as_deref()).await?,
        };
        self.answer(name, &answer).await
    }

    /// Ends the running core quietly and stops the jobs, for `/kill` and
    /// `/stop`, the command `name`: the jobs stopped.
    async fn kill(&mut self, committed: &Committed, name: &str) -> Result<Vec<u32>> {
        // Nothing the model has seen wakes it again, held or not.
        self.seen = self.head;
        if self.core.is_some() {
            let reason = format!("{} ran /{name}", committed.message.sender.name);
            self.end(End::Kill(reason)).await?;
        }
        Ok(self.cancel_jobs())
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
        let jobs = self.kill(committed, "stop").await?;
        let how = command::how(self.place.kind, &self.place.my_name, "/start");
        let mut answer =
            format!("stopped: messages are still recorded, but Max won't reply until {how}");
        if !jobs.is_empty() {
            answer.push('\n');
            answer.push_str(&stopped_jobs(&jobs));
        }
        Ok(answer)
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

    async fn answer(&mut self, name: &str, body: &str) -> Result<()> {
        let draft = Draft {
            reply_to: None,
            nodes: vec![DraftNode::Text {
                text: command::answer(name, body),
            }],
        };
        self.say(draft, None, None, By::Host, None).await?;
        Ok(())
    }

    async fn save_settings(&mut self) -> Result<()> {
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
    /// its commit, then a key and its value a line. `/model` and
    /// `/persona` show those.
    fn status(&self) -> String {
        let settings = &self.settings;
        let mut lines = vec![format!("maxx {}", crate::COMMIT)];
        let mut line = |key: &str, value: String| lines.push(format!("{key:<10}{value}"));
        line("os", format!("{} · {}", os(), std::env::consts::ARCH));
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
        for job in self.job_lines() {
            line("job", job);
        }
        if let Some(dir) = &self.shared.vm_dir {
            let units = vm::units(&vm::work(dir, self.place.conversation));
            if !units.is_empty() {
                line("units", units.join(", "));
            }
        }
        if let Some(woken) = self.woken.summary(Instant::now()) {
            line("woken", woken);
        }
        if let Some(mark) = settings.cleared_upto {
            line("context", format!("after #{mark}"));
        }
        let mut up = span(self.shared.started.elapsed());
        if let Some(host) = host_uptime() {
            let _ = write!(up, " · host {}", span(host));
        }
        line("uptime", up);
        lines.join("\n")
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
        let idle = a.chosen.idle_window.as_secs();
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
        self.answer("bind", text).await
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

/// The jobs `/kill` or `/stop` stopped, as a line of its answer.
fn stopped_jobs(jobs: &[u32]) -> String {
    let jobs: Vec<String> = jobs.iter().map(|job| format!("job#{job}")).collect();
    format!("jobs stopped: {}", jobs.join(", "))
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

/// The distribution's name from /etc/os-release, else the OS's.
fn os() -> String {
    std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|release| {
            release.lines().find_map(|line| {
                let name = line.strip_prefix("PRETTY_NAME=")?;
                Some(name.trim_matches('"').to_owned())
            })
        })
        .unwrap_or_else(|| std::env::consts::OS.to_owned())
}

/// How long the host has been up, from /proc/uptime on Linux.
fn host_uptime() -> Option<Duration> {
    let uptime = std::fs::read_to_string("/proc/uptime").ok()?;
    let seconds: f64 = uptime.split_whitespace().next()?.parse().ok()?;
    Some(Duration::from_secs_f64(seconds))
}
