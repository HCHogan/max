//! Running commands. The answer is said in the same conversation, as a row
//! of Max's outside any turn: QQ gives no way from a group member's id to a
//! private chat with them. It doesn't quote the command, which is right
//! above it, and reads like a log: terse, `/name → result`, in a code
//! block (see `command::answer`). Like the command, it is in the next
//! core's context as Max's own words.

use std::fmt::Write;
use std::time::Duration;

use max_core::message::{Platform, Role};
use max_db::platform::ConversationKind;
use max_db::{ledger, summaries};
use tokio::sync::oneshot;

use super::*;
use crate::bind::Pending;
use crate::command::{self, Command, Persona};
use crate::conversation::ingest::Committed;
use crate::historian::{Captured, Compact, Compacted, Notice};

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
            // Who may link whom is its own business.
            Command::Kill
            | Command::Persona(_)
            | Command::Clear { .. }
            | Command::Unclear
            | Command::Compact => Rank::Admin,
            Command::Model(_) | Command::Effort(_) | Command::Proactive(_) | Command::Bind(_) => {
                Rank::Owner
            }
        };
        let name = command.name();
        if rank < needs {
            let who = if needs == Rank::Owner {
                "主人"
            } else {
                "群主、管理员"
            };
            return self.answer(name, &format!("拒绝：仅限{who}")).await;
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
            Command::Clear { all: false } => {
                let how = command::how(self.place.kind, &self.place.my_name, "/clear --all");
                format!("需要确认：发送 {how} 清空上下文")
            }
            Command::Clear { all: true } => {
                self.settings.cleared_upto = Some(committed.message.id);
                self.save_settings().await?;
                let how = command::how(self.place.kind, &self.place.my_name, "/unclear");
                format!("已清空：之前的消息不再进入上下文，{how} 恢复")
            }
            Command::Unclear => self.unclear().await?,
            Command::Compact => match self.compact() {
                Some(answer) => answer,
                None => return Ok(()),
            },
            Command::Bind(argument) => self.bind(committed, argument.as_deref()).await?,
        };
        self.answer(name, &answer).await
    }

    /// Takes `/clear --all` back: what came before its mark is in the
    /// context again. The historian summarizes up to the mark before it
    /// summarizes past it; if that failed, the rows it left between the
    /// summaries stay out, and `context_search` finds them.
    async fn unclear(&mut self) -> Result<String> {
        let Some(mark) = self.settings.cleared_upto.take() else {
            return Ok("跳过：没有清空过".to_owned());
        };
        self.save_settings().await?;
        let conversation = self.place.conversation;
        let mut conn = self.shared.pool.acquire().await?;
        let active = summaries::active(&mut conn, conversation, None).await?;
        let (before, after): (Vec<_>, Vec<_>) = active
            .into_iter()
            .map(|(_, summary)| summary.last)
            .partition(|last| *last <= mark);
        let left_out = !after.is_empty()
            && !ledger::rows(&mut conn, conversation, before.last().copied(), mark)
                .await?
                .is_empty();
        Ok(if left_out {
            "已恢复：清空前的摘要回到上下文；清空时还没写成摘要的那段不回来，context_search 搜得到"
                .to_owned()
        } else {
            "已恢复：清空前的消息回到上下文".to_owned()
        })
    }

    async fn answer(&mut self, name: &str, body: &str) -> Result<()> {
        let draft = Draft {
            reply_to: None,
            nodes: vec![DraftNode::Text {
                text: command::answer(name, body),
            }],
        };
        self.say(draft, None, None, None).await?;
        Ok(())
    }

    /// Hands `/compact` to the historian, which answers when it is done;
    /// or the answer now, when it can't.
    fn compact(&mut self) -> Option<String> {
        if self.place.kind == ConversationKind::Direct {
            return Some("跳过：私聊不写摘要".to_owned());
        }
        let Some(historian) = &self.shared.historian else {
            return Some("错误：没有配置摘要模型".to_owned());
        };
        let (reply, answer) = oneshot::channel();
        let notice = Notice::Compact(Compact {
            place: Arc::clone(&self.place),
            reply,
        });
        if historian.send(notice).is_err() {
            return Some("错误：摘要服务已停止".to_owned());
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
            Ok(Captured::Published(count)) => format!("已压缩：{count} 段摘要"),
            Ok(Captured::Nothing) => "跳过：没有要压缩的".to_owned(),
            Err(_) => "失败：稍后重试".to_owned(),
        };
        self.answer("compact", &text).await
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
            return Ok(format!("错误：没有这个模型（{error}）\n可选：{list}"));
        }
        self.settings.model = (reference != "default").then(|| reference.to_owned());
        self.save_settings().await?;
        Ok(format!("已切换：{reference}，下次回复生效"))
    }

    async fn effort(&mut self, argument: Option<String>) -> Result<String> {
        let Some(level) = argument else {
            let effort = match &self.settings.effort {
                Some(effort) => effort.clone(),
                None => "默认".to_owned(),
            };
            return Ok(format!("推理强度：{effort}"));
        };
        let answer = format!("已设置：{level}，下次回复生效");
        self.settings.effort = (level != "default").then_some(level);
        self.save_settings().await?;
        Ok(answer)
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
            "已开启主动接话"
        } else {
            "已关闭主动接话：只在被 @ 或回复时回答"
        }
        .to_owned())
    }

    async fn persona(&mut self, persona: Persona) -> Result<String> {
        let answer = match persona {
            Persona::Show => {
                return Ok(match &self.settings.persona {
                    Some(persona) => format!("当前人设：\n{persona}"),
                    None => "当前人设：默认".to_owned(),
                });
            }
            Persona::Reset => {
                self.settings.persona = None;
                "已恢复默认人设，下次回复生效"
            }
            Persona::Set(text) => {
                self.settings.persona = Some(text);
                "已更新人设，下次回复生效"
            }
        };
        self.save_settings().await?;
        Ok(answer.to_owned())
    }

    /// The `/bind <码>` that bound this group, which the table hands over
    /// instead of running it.
    pub(super) async fn bound(&mut self, continued: bool) -> Result<()> {
        let text = if continued {
            "已绑定：接续老群的记录"
        } else {
            "已绑定：从这里开始记录"
        };
        self.answer("bind", text).await
    }

    /// In a private chat, a code to bind a QQ group with; in a group, the
    /// group is bound already, or it wouldn't have an actor.
    async fn bind(&mut self, committed: &Committed, argument: Option<&str>) -> Result<String> {
        if self.place.kind != ConversationKind::Direct {
            return Ok("错误：本群已绑定，不支持改绑".to_owned());
        }
        let conversation = match argument {
            None => None,
            Some(group) => {
                let native_id = format!("group:{group}");
                let mut conn = self.shared.pool.acquire().await?;
                let found =
                    platform::conversation_of(&mut conn, Platform::QqLegacy, &native_id).await?;
                let Some(conversation) = found else {
                    return Ok(format!("错误：没有老群 {group} 的记录"));
                };
                let bound = platform::endpoint_on(&mut conn, conversation, Platform::Qq).await?;
                if bound.is_some() {
                    return Ok(format!("错误：老群 {group} 的记录已接到别的群"));
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
            Some(group) => format!("接续老群 {group} 的记录"),
            None => "开始新的记录".to_owned(),
        };
        let how = command::how(ConversationKind::Group, &self.place.my_name, "/bind");
        Ok(format!(
            "已生成绑定码：在要绑的群里发送 {how} {code}，{target}\n有效期 10 分钟，只能用一次"
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
