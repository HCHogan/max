//! Running commands. The answer is said in the same conversation, quoting
//! the command, as a row of Max's outside any turn: QQ gives no way from a
//! group member's id to a private chat with them.

use std::fmt::Write;

use max_core::message::{Platform, Role};
use max_db::platform::ConversationKind;
use tokio::sync::oneshot;

use super::*;
use crate::bind::Pending;
use crate::command::{self, Command, HELP, Persona};
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
            Command::Help | Command::Status => Rank::Anyone,
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
            return self
                .answer(committed.message.id, format!("这个命令只有{who}能用。"))
                .await;
        }
        let answer = match command {
            Command::Help => HELP.to_owned(),
            Command::Status => self.status(),
            Command::Kill => {
                // Nothing the model has seen wakes it again, held or not.
                self.seen = self.head;
                if self.core.is_some() {
                    let reason = format!("{} 用 !kill 停下了", committed.message.sender.name);
                    self.end(End::Kill(reason)).await?;
                }
                return Ok(());
            }
            Command::Model(argument) => self.model(argument.as_deref()).await?,
            Command::Effort(argument) => self.effort(argument).await?,
            Command::Proactive(on) => self.proactive(on).await?,
            Command::Persona(persona) => self.persona(persona).await?,
            Command::Clear { all: false } => "要清空上下文，发 !clear --all。".to_owned(),
            Command::Clear { all: true } => {
                self.settings.cleared_upto = Some(committed.message.id);
                self.save_settings().await?;
                "好，之前的聊天不再进上下文。".to_owned()
            }
            Command::Compact => match self.compact(committed.message.id) {
                Some(answer) => answer,
                None => return Ok(()),
            },
            Command::Bind(argument) => self.bind(committed, argument.as_deref()).await?,
        };
        self.answer(committed.message.id, answer).await
    }

    /// Answers the command `to`, quoting it.
    async fn answer(&mut self, to: MessageId, text: String) -> Result<()> {
        let draft = Draft {
            reply_to: Some(to),
            nodes: vec![DraftNode::Text { text }],
        };
        self.say(draft, None, None).await?;
        Ok(())
    }

    /// Hands `!compact` to the historian, which answers when it is done;
    /// or the answer now, when it can't.
    fn compact(&mut self, command: MessageId) -> Option<String> {
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
            let _ = mailbox.send(Event::Compacted { command, result });
        });
        None
    }

    pub(super) async fn compacted(&mut self, command: MessageId, result: Compacted) -> Result<()> {
        let text = match result {
            Ok(Captured::Published(count)) => format!("好，整理成了 {count} 段摘要。"),
            Ok(Captured::Nothing) => "没有要整理的。".to_owned(),
            Err(_) => "这次没整理成，等会儿再试试。".to_owned(),
        };
        self.answer(command, text).await
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

    fn status(&self) -> String {
        let settings = &self.settings;
        let mut out = String::new();
        match self
            .shared
            .models
            .turn(settings.model.as_deref(), settings.effort.as_deref())
        {
            Ok(chosen) => {
                let effort = chosen.options.effort.as_deref().unwrap_or("默认");
                let _ = writeln!(out, "模型：{}，推理强度 {effort}", chosen.reference());
            }
            Err(error) => {
                let _ = writeln!(out, "模型：选不出来（{error}）");
            }
        }
        let persona = match &settings.persona {
            Some(persona) => format!("自定义，{}…", persona.chars().take(20).collect::<String>()),
            None => "默认".to_owned(),
        };
        let _ = writeln!(out, "人设：{persona}");
        let proactive = if settings.proactive { "开" } else { "关" };
        let _ = writeln!(out, "主动接话：{proactive}");
        match &self.core {
            Some(a) => {
                let minutes = a.started.elapsed().as_secs() / 60;
                let _ = writeln!(
                    out,
                    "在跑：t#{}，{minutes} 分钟，{} 轮",
                    a.ordinal,
                    a.run.round()
                );
            }
            None => out.push_str("在跑：没有\n"),
        }
        if let Some(mark) = settings.cleared_upto {
            let _ = writeln!(out, "上下文从 #{mark} 之后算起");
        }
        out.trim_end().to_owned()
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

    /// The `!bind <码>` that bound this group, which the table hands over
    /// instead of running it.
    pub(super) async fn bound(&mut self, committed: &Committed, continued: bool) -> Result<()> {
        let text = if continued {
            "绑好了，这个群接着老群的记录往下聊。"
        } else {
            "绑好了，这个群从这里开始记。"
        };
        self.answer(committed.message.id, text.to_owned()).await
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
            "在要绑的群里发 !bind {code}，{target}。10 分钟内有效，只能用一次。"
        ))
    }
}
