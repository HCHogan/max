//! Running commands. The answer is said in the same conversation, as a row
//! of Max's outside any turn: QQ gives no way from a group member's id to a
//! private chat with them. It doesn't quote the command, which is right
//! above it.

use std::fmt::Write;
use std::time::Duration;

use max_core::message::{Content, MentionTarget, Node, Platform, Role};
use max_db::platform::ConversationKind;
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
            Command::Link(_) => Rank::Anyone,
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
            Command::Link(argument) => {
                let owner = rank == Rank::Owner;
                self.link(committed, argument.as_deref(), owner).await?
            }
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
        let notice = Notice::Compact(Compact {
            place: Arc::clone(&self.place),
            reply,
        });
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

    /// A card like the Haskell version's `!version`, in English: a line
    /// each, an emoji in front. QQ breaks lines at a bare newline; two
    /// spaces before it, Markdown's break, made it two. `/model` and
    /// `/persona` show those.
    fn status(&self) -> String {
        let settings = &self.settings;
        let mut lines = vec![
            format!("🦈 maxx {}", crate::COMMIT),
            format!("🌊 {} · {}", os(), std::env::consts::ARCH),
        ];
        let proactive = if settings.proactive { "on" } else { "off" };
        lines.push(format!("💬 proactive: {proactive}"));
        lines.push(match &self.core {
            Some(a) => format!(
                "⚙️ replying: t#{} · {} · round {}",
                a.ordinal,
                span(a.started.elapsed()),
                a.run.round()
            ),
            None => "💤 idle".to_owned(),
        });
        if let Some(mark) = settings.cleared_upto {
            lines.push(format!("🧹 context after #{mark}"));
        }
        let mut up = format!("⏱️ up {}", span(self.shared.started.elapsed()));
        if let Some(host) = host_uptime() {
            let _ = write!(up, " · host {}", span(host));
        }
        lines.push(up);
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

impl Conversation {
    /// `/link <QQ号>`: this account is the person with that QQ number in
    /// the old group's records. Nothing proves the number is the sender's,
    /// so a person is linked once per group, the answer says to whom in
    /// front of everyone, and only an owner changes a link: someone else's,
    /// with an @ of them, or undone with `-`. See "权限".
    async fn link(
        &mut self,
        committed: &Committed,
        argument: Option<&str>,
        owner: bool,
    ) -> Result<String> {
        const USAGE: &str = "在群里发 /link 你的QQ号，把这个账号接到老群记录里的你。";
        if self.place.kind == ConversationKind::Direct {
            return Ok("/link 要在群里发：每个群里的账号各接各的。".to_owned());
        }
        let Some(last) = argument.and_then(|argument| argument.split_whitespace().last()) else {
            return Ok(USAGE.to_owned());
        };
        let me = self.place.me.identity;
        let mentioned = match &committed.message.content {
            Content::Message { nodes, .. } => nodes.iter().find_map(|node| match node {
                Node::Mention {
                    target: MentionTarget::Identity(id),
                    ..
                } if *id != me => Some(*id),
                _ => None,
            }),
            _ => None,
        };
        if (mentioned.is_some() || last == "-") && !owner {
            return Ok("替别人接、撤销，只有主人能用。".to_owned());
        }
        let target = mentioned.unwrap_or(committed.sender.identity);
        let mut conn = self.shared.pool.acquire().await?;
        let Some((own, merged)) = platform::own_principal(&mut conn, target).await? else {
            return Ok(USAGE.to_owned());
        };
        let current = merged.unwrap_or(own);
        if current == self.place.me.principal || self.shared.owners.contains(&current) {
            return Ok("主人和 Max 自己的账号不用 /link。".to_owned());
        }
        if last == "-" {
            platform::relink(&mut conn, own, None).await?;
            return Ok("好，撤销了这个账号的关联。".to_owned());
        }
        let qq = (5..=12).contains(&last.len()) && last.bytes().all(|b| b.is_ascii_digit());
        if !qq {
            return Ok(USAGE.to_owned());
        }
        let found = platform::legacy_speaker(&mut conn, self.place.conversation, last).await?;
        let Some(old) = found else {
            return Ok("老群的记录里没有这个 QQ 号说过的话。".to_owned());
        };
        if current == old.principal {
            return Ok("已经接上了。".to_owned());
        }
        if merged.is_some() && !owner {
            return Ok("你已经接到老群记录里的另一个人了，要改找主人。".to_owned());
        }
        let endpoint = self.place.endpoint;
        if let Some(other) = platform::linked_in(&mut conn, endpoint, old.principal, target).await?
        {
            if !owner {
                return Ok("这个 QQ 号在这个群里已经有人接上了，有问题找主人。".to_owned());
            }
            platform::relink(&mut conn, other.principal, None).await?;
        }
        platform::relink(&mut conn, own, Some(old.principal)).await?;
        Ok(format!("好，接到了老群记录里的「{}」。", old.name))
    }

    /// Each time an account that isn't linked talks to Max, with an @ or a
    /// reply, in a group that goes on from an old one, tells it about
    /// `/link` before Max answers. Chatter among others isn't interrupted.
    pub(super) async fn remind_to_link(&mut self, committed: &Committed) -> Result<()> {
        let person = committed.sender.principal;
        if self.place.kind == ConversationKind::Direct
            || committed.direct.is_none()
            || person == self.place.me.principal
            || self.shared.owners.contains(&person)
        {
            return Ok(());
        }
        let identity = committed.sender.identity;
        let mut conn = self.shared.pool.acquire().await?;
        let linked = platform::own_principal(&mut conn, identity).await?;
        if linked.is_none_or(|(_, merged)| merged.is_some()) {
            return Ok(());
        }
        let conversation = self.place.conversation;
        if platform::endpoint_on(&mut conn, conversation, Platform::QqLegacy)
            .await?
            .is_none()
        {
            return Ok(());
        }
        drop(conn);
        let text = " 如果你在老群里说过话，发 /link 你的QQ号，把这个账号接到老群记录里的你；没说过就不用管。";
        let draft = Draft {
            reply_to: None,
            nodes: vec![
                DraftNode::Mention { principal: person },
                DraftNode::Text { text: text.into() },
            ],
        };
        self.say(draft, None, None).await?;
        Ok(())
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
