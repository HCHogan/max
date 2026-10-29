//! Running commands. The answer is said in the same conversation, as a row
//! of Max's outside any turn: QQ gives no way from a group member's id to a
//! private chat with them. It doesn't quote the command, which is right
//! above it.

use std::fmt::Write;
use std::time::Duration;

use max_core::message::{Platform, Role};
use max_db::platform::ConversationKind;
use tokio::sync::oneshot;

use super::*;
use crate::bind::Pending;
use crate::command::{self, Command, Persona};
use crate::conversation::ingest::Committed;
use crate::historian::{Captured, Compacted};

/// Who may run what. Commands that cost money or change how Max behaves
/// everywhere are the owners'; those that change one conversation are
/// also its group's owner's and admins'.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Rank {
    Anyone,
    Admin,
    Owner,
}

impl Conversation {
    pub(super) async fn command(&mut self, committed: &Committed) -> Result<()> {
        let Some(command) = command::parse(&committed.text) else {
            return Ok(());
        };
        let rank = if self.shared.owners.contains(&committed.sender.principal) {
            Rank::Owner
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
            Command::Kill | Command::Persona(_) | Command::Clear { .. } | Command::Compact => {
                Rank::Admin
            }
            Command::Model(_) | Command::Effort(_) | Command::Proactive(_) | Command::Bind(_) => {
                Rank::Owner
            }
        };
        if rank < needs {
            let who = if needs == Rank::Owner {
                "主人"
            } else {
                "群主、管理员"
            };
            return self.answer(format!("这个命令只有{who}能用。")).await;
        }
        let answer = match command {
            Command::Status => self.status(),
            Command::Kill => {
                // Nothing the model has seen wakes it again, held or not.
                self.seen = self.head;
                if self.core.is_some() {
                    let reason = format!("{} 用 /kill 停下了", committed.message.sender.name);
                    self.end(End::Kill(reason)).await?;
                }
                return Ok(());
            }
            Command::Model(argument) => self.model(argument.as_deref()).await?,
            Command::Effort(argument) => self.effort(argument).await?,
            Command::Proactive(on) => self.proactive(on).await?,
            Command::Persona(persona) => self.persona(persona).await?,
            Command::Clear { all: false } => "要清空上下文，发 /clear --all。".to_owned(),
            Command::Clear { all: true } => {
                self.settings.cleared_upto = Some(committed.message.id);
                self.save_settings().await?;
                "好，之前的聊天不再进上下文。".to_owned()
            }
            Command::Compact => match self.compact() {
                Some(answer) => answer,
                None => return Ok(()),
            },
            Command::Bind(argument) => self.bind(committed, argument.as_deref()).await?,
        };
        self.answer(answer).await
    }

    async fn answer(&mut self, text: String) -> Result<()> {
        let draft = Draft {
            reply_to: None,
            nodes: vec![DraftNode::Text { text }],
        };
        self.say(draft, None, None).await?;
        Ok(())
    }

    /// Hands `/compact` to the historian, which answers when it is done;
    /// or the answer now, when it can't.
    fn compact(&mut self) -> Option<String> {
        if self.place.kind == ConversationKind::Direct {
            return Some("私聊不写摘要。".to_owned());
        }
        let Some(historian) = &self.shared.historian else {
            return Some("没有配写摘要的模型。".to_owned());
        };
        let (reply, answer) = oneshot::channel();
        let notice = Notice::Compact(Arc::clone(&self.place), reply);
        if historian.send(notice).is_err() {
            return Some("写摘要的服务停了。".to_owned());
        }
        let mailbox = self.mailbox.clone();
        self.side.spawn(move |_| async move {
            let result = answer
                .await
                .unwrap_or_else(|_| Err("the historian stopped".to_owned()));
            let _ = mailbox.send(Event::Compacted(result));
        });
        None
    }

    pub(super) async fn compacted(&mut self, result: Compacted) -> Result<()> {
        let text = match result {
            Ok(Captured::Published(count)) => format!("好，整理成了 {count} 段摘要。"),
            Ok(Captured::Nothing) => "没有要整理的。".to_owned(),
            Err(_) => "这次没整理成，等会儿再试试。".to_owned(),
        };
        self.answer(text).await
    }

    async fn save_settings(&mut self) -> Result<()> {
        let mut conn = self.shared.pool.acquire().await?;
        platform::save_settings(
            &mut conn,
            self.place.conversation,
            &self.settings,
            Utc::now(),
        )
        .await?;
        Ok(())
    }

    /// A card like the Haskell version's `!version`: a line each, an emoji
    /// in front. A line ends in two spaces, Markdown's line break.
    fn status(&self) -> String {
        let settings = &self.settings;
        let mut lines = vec![
            format!("🦈 maxx {}", crate::COMMIT),
            format!("🌊 {} · {}", os(), std::env::consts::ARCH),
        ];
        lines.push(
            match self
                .shared
                .models
                .turn(settings.model.as_deref(), settings.effort.as_deref())
            {
                Ok(chosen) => {
                    let effort = chosen.options.effort.as_deref().unwrap_or("默认");
                    format!("🧠 {} · 推理 {effort}", chosen.reference())
                }
                Err(error) => format!("🧠 模型选不出来（{error}）"),
            },
        );
        let persona = match &settings.persona {
            Some(persona) => {
                let start: String = persona
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .chars()
                    .take(20)
                    .collect();
                format!("自定义：{start}…")
            }
            None => "默认".to_owned(),
        };
        lines.push(format!("🎭 人设：{persona}"));
        let proactive = if settings.proactive { "开" } else { "关" };
        lines.push(format!("💬 主动接话：{proactive}"));
        lines.push(match &self.core {
            Some(a) => format!(
                "⚙️ 在回复：t#{} · {} · 第 {} 轮",
                a.ordinal,
                span(a.started.elapsed()),
                a.run.round()
            ),
            None => "💤 没有在跑的回复".to_owned(),
        });
        if let Some(mark) = settings.cleared_upto {
            lines.push(format!("🧹 上下文从 #{mark} 之后算起"));
        }
        let mut up = format!("⏱️ up {}", span(self.shared.started.elapsed()));
        if let Some(host) = host_uptime() {
            let _ = write!(up, " · host {}", span(host));
        }
        lines.push(up);
        lines.join("  \n")
    }

    async fn model(&mut self, argument: Option<&str>) -> Result<String> {
        let models = &self.shared.models;
        let list = models.references().join("、");
        let current = self.settings.model.clone();
        let Some(reference) = argument.filter(|argument| *argument != "list") else {
            let current = match models.turn(current.as_deref(), None) {
                Ok(chosen) => chosen.reference(),
                Err(_) => current.unwrap_or_default(),
            };
            return Ok(format!("当前：{current}\n可选：{list}"));
        };
        if let Err(error) = models.choose(reference, None) {
            return Ok(format!("没有这个模型（{error}）。可选：{list}"));
        }
        self.settings.model = (reference != "default").then(|| reference.to_owned());
        self.save_settings().await?;
        Ok(format!("下一次回复起用 {reference}。"))
    }

    async fn effort(&mut self, argument: Option<String>) -> Result<String> {
        let Some(level) = argument else {
            let effort = match &self.settings.effort {
                Some(effort) => effort.clone(),
                None => "默认".to_owned(),
            };
            return Ok(format!("推理强度：{effort}"));
        };
        self.settings.effort = (level != "default").then_some(level);
        self.save_settings().await?;
        Ok("下一次回复起生效。".to_owned())
    }

    async fn proactive(&mut self, on: Option<bool>) -> Result<String> {
        let Some(on) = on else {
            let state = if self.settings.proactive {
                "开"
            } else {
                "关"
            };
            return Ok(format!("主动接话：{state}"));
        };
        self.settings.proactive = on;
        self.intent.set_proactive(on);
        self.save_settings().await?;
        Ok(if on {
            "主动接话开了。"
        } else {
            "主动接话关了，只在被叫到时回。"
        }
        .to_owned())
    }

    async fn persona(&mut self, persona: Persona) -> Result<String> {
        let answer = match persona {
            Persona::Show => {
                return Ok(match &self.settings.persona {
                    Some(persona) => format!("当前人设：\n{persona}"),
                    None => "用的是默认人设。".to_owned(),
                });
            }
            Persona::Reset => {
                self.settings.persona = None;
                "回到默认人设，下一次回复起生效。"
            }
            Persona::Set(text) => {
                self.settings.persona = Some(text);
                "人设换了，下一次回复起生效。"
            }
        };
        self.save_settings().await?;
        Ok(answer.to_owned())
    }

    /// The `/bind <码>` that bound this group, which the table hands over
    /// instead of running it.
    pub(super) async fn bound(&mut self, continued: bool) -> Result<()> {
        let text = if continued {
            "绑好了，这个群接着老群的记录往下聊。"
        } else {
            "绑好了，这个群从这里开始记。"
        };
        self.answer(text.to_owned()).await
    }

    /// In a private chat, a code to bind a QQ group with; in a group, the
    /// group is bound already, or it wouldn't have an actor.
    async fn bind(&mut self, committed: &Committed, argument: Option<&str>) -> Result<String> {
        if self.place.kind != ConversationKind::Direct {
            return Ok("这个群已经绑定过了，不支持改绑。".to_owned());
        }
        let conversation = match argument {
            None => None,
            Some(group) => {
                let native_id = format!("group:{group}");
                let mut conn = self.shared.pool.acquire().await?;
                let found =
                    platform::conversation_of(&mut conn, Platform::QqLegacy, &native_id).await?;
                let Some(conversation) = found else {
                    return Ok(format!("没找到老群 {group} 的记录。"));
                };
                let bound = platform::endpoint_on(&mut conn, conversation, Platform::Qq).await?;
                if bound.is_some() {
                    return Ok(format!("老群 {group} 的记录已经接到一个群上了。"));
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
            Some(group) => format!("接上老群 {group} 的记录"),
            None => "开一段新的记录".to_owned(),
        };
        Ok(format!(
            "在要绑的群里发 /bind {code}，{target}。10 分钟内有效，只能用一次。"
        ))
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
