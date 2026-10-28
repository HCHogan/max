//! The classifier's prompt and its answer. The classify task reads the
//! ledger and renders the lines; everything here is text in, text out.

use std::time::Duration;

use serde::Deserialize;

use super::{Kind, Status, Verdict};

/// How much of the persona the classifier sees.
pub const PERSONA_CHARS: usize = 500;

/// A longer reason is cut: it goes into the core's input as the
/// `[判定 …]` line.
pub const NOTE_CHARS: usize = 40;

pub fn system(persona: &str) -> String {
    let persona: String = persona.chars().take(PERSONA_CHARS).collect();
    format!(
        "你是多人群聊 agent「Max」的触发判定器。Max 的人设：
{persona}

给你一段群聊上下文、本群情况和几条新消息。每行的格式是 [时间 名字 #编号 标记]: 内容，标记里的“你”指 Max。判断 Max 是否应该主动接话。

应该接话（trigger=true）：
1. 有人在叫 Max 或找它帮忙，只是没打 @ —— 如“max帮我看看”“机器人查一下”“Max你觉得呢”。
2. Max 刚参与的对话有了后续：有人在回应、追问或反驳 Max 刚说的话。
3. 正在讨论 Max 感兴趣的话题，且它能给出具体有用的东西（答案、纠错、关键信息）。

不该接话（trigger=false）：
- 成员之间的日常闲聊，与 Max 无关；
- 只是顺带提到/议论 Max，不是在跟它说话；
- 其他机器人发的机械消息（播报、复读、签到等）；
- 标着“@你”“回复你”“戳你”的消息 Max 一定会回，不用为它们判 true；
- 第 3 类要格外克制：只能附和、发感想、抖机灵的不算；上下文里 Max 已经插过话的话题，别人没接它的茬就不要再插；
- Max 最近主动接的话没人理，就更克制；
- 拿不准的一律 false —— 插错话比沉默尴尬得多，偶尔插话才有惊喜，频繁插话只会烦人。

另外判断 dismiss：新消息里有人在叫 Max 少说话、别插嘴、闭嘴，或者明显嫌它烦，就是 true，否则 false。

只输出一行 JSON，不要其他内容：
{{\"trigger\": true/false, \"kind\": \"called\"|\"followup\"|\"topic\", \"reason\": \"不超过20字\", \"dismiss\": true/false}}
kind 对应上面三类：called=有人在叫它/找它帮忙；followup=它参与的对话的后续；topic=感兴趣的话题。"
    )
}

/// What the classify task counts from the ledger, plus intent's status.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Situation {
    /// Messages in the last hour, Max's and everyone else's.
    pub max_last_hour: usize,
    pub others_last_hour: usize,
    /// Messages in the last five minutes, and how many people sent them.
    pub recent: usize,
    pub recent_people: usize,
    pub status: Status,
}

impl Situation {
    pub fn line(&self) -> String {
        let mut line = format!(
            "近 1 小时 Max 说了 {} 条，群友 {} 条；近 5 分钟 {} 条，{} 个人在说。",
            self.max_last_hour, self.others_last_hour, self.recent, self.recent_people
        );
        let status = &self.status;
        if status.spoken_on > 0 {
            line += &format!(
                "Max 最近 {} 次主动接话，{} 次有人回应。",
                status.spoken_on, status.taken_up
            );
        }
        if let Some(left) = status.dismissed_for {
            line += &format!(
                "有人嫌 Max 话多，{}内只在被叫到或有人追问时接话。",
                hours(left)
            );
        }
        line
    }
}

fn hours(left: Duration) -> String {
    format!("{} 小时", left.as_secs().div_ceil(3600))
}

/// `context` and `new` are rendered lines, oldest first.
pub fn user(context: &str, situation: &Situation, new: &str) -> String {
    let or_none = |text: &str| {
        if text.trim().is_empty() {
            "（无）".to_string()
        } else {
            text.trim_end().to_string()
        }
    };
    format!(
        "[上下文]\n{}\n\n[本群情况]\n{}\n\n[新消息]\n{}",
        or_none(context),
        situation.line(),
        or_none(new)
    )
}

#[derive(Deserialize)]
struct Raw {
    trigger: bool,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    dismiss: bool,
}

/// The first `{` through the last `}`, so fences and prose around the
/// object don't matter. A kind the model mangled counts as a topic, the
/// most held back.
pub fn parse(text: &str) -> Option<Verdict> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    let raw: Raw = serde_json::from_str(text.get(start..=end)?).ok()?;
    let kind = match raw.kind.as_deref() {
        Some("called") => Kind::Called,
        Some("followup") => Kind::Followup,
        _ => Kind::Topic,
    };
    let reason = raw.reason.unwrap_or_default();
    Some(Verdict {
        trigger: raw.trigger,
        kind,
        reason: reason.trim().chars().take(NOTE_CHARS).collect(),
        dismiss: raw.dismiss,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quiet_group() -> Situation {
        Situation {
            max_last_hour: 0,
            others_last_hour: 3,
            recent: 2,
            recent_people: 1,
            status: Status {
                proactive: true,
                judged_last_hour: 0,
                cap: 8,
                dismissed_for: None,
                taken_up: 0,
                spoken_on: 0,
            },
        }
    }

    #[test]
    fn the_prompt() {
        let persona = "猫".repeat(600);
        let system = system(&persona);
        assert!(system.contains(&"猫".repeat(500)));
        assert!(!system.contains(&"猫".repeat(501)));
        assert!(system.contains(r#"{"trigger": true/false,"#));
        let user = user("", &quiet_group(), "[10:00 小明 #7]: max 在吗\n");
        assert_eq!(
            user,
            "[上下文]\n（无）\n\n[本群情况]\n近 1 小时 Max 说了 0 条，群友 3 条；近 5 分钟 2 条，1 个人在说。\n\n[新消息]\n[10:00 小明 #7]: max 在吗"
        );
    }

    #[test]
    fn the_situation_tells_how_max_has_been_received() {
        let mut situation = quiet_group();
        situation.status.spoken_on = 4;
        situation.status.taken_up = 1;
        situation.status.dismissed_for = Some(Duration::from_secs(20 * 3600 + 1));
        assert_eq!(
            situation.line(),
            "近 1 小时 Max 说了 0 条，群友 3 条；近 5 分钟 2 条，1 个人在说。\
             Max 最近 4 次主动接话，1 次有人回应。\
             有人嫌 Max 话多，21 小时内只在被叫到或有人追问时接话。"
        );
    }

    #[test]
    fn parsing_tolerates_fences_and_gaps() {
        let fenced =
            "```json\n{\"trigger\": true, \"kind\": \"followup\", \"reason\": \" 在追问 \"}\n```";
        assert_eq!(
            parse(fenced),
            Some(Verdict {
                trigger: true,
                kind: Kind::Followup,
                reason: "在追问".into(),
                dismiss: false,
            })
        );
        let mangled = r#"{"trigger": false, "kind": "闲聊", "dismiss": true}"#;
        let verdict = parse(mangled).unwrap();
        assert_eq!((verdict.kind, verdict.dismiss), (Kind::Topic, true));
        let long = format!(r#"{{"trigger": true, "reason": "{}"}}"#, "长".repeat(100));
        assert_eq!(parse(&long).unwrap().reason.chars().count(), NOTE_CHARS);
        assert_eq!(parse("不接"), None);
        assert_eq!(parse(r#"{"kind": "topic"}"#), None);
        assert_eq!(parse("} {"), None);
    }
}
