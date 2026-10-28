//! The classifier's prompt and its answer. The classify task reads the
//! ledger and renders the lines; everything here is text in, text out.

use serde::Deserialize;

use super::Verdict;

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

给你一段群聊上下文和几条新消息。每行的格式是 [时间 名字 #编号 标记]: 内容，标记里的“你”指 Max。判断 Max 是否应该主动接话。

应该接话（trigger=true）：
1. 有人在叫 Max 或找它帮忙，只是没打 @ —— 如“max帮我看看”“机器人查一下”“Max你觉得呢”。
2. Max 刚参与的对话有了后续：有人在回应、追问或反驳 Max 刚说的话。
3. 正在讨论 Max 感兴趣的话题，且它能给出具体有用的东西（答案、纠错、关键信息）。

不该接话（trigger=false）：
- 成员之间的日常闲聊，与 Max 无关；
- 只是顺带提到/议论 Max，不是在跟它说话；
- 有人叫 Max 少说话、别插嘴，或者明显嫌它烦；
- 其他机器人发的机械消息（播报、复读、签到等）；
- 第 3 类要格外克制：只能附和、发感想、抖机灵的不算；上下文里 Max 已经插过话的话题，别人没接它的茬就不要再插；
- 拿不准的一律 false —— 插错话比沉默尴尬得多，偶尔插话才有惊喜，频繁插话只会烦人。

只输出一行 JSON，不要其他内容：
{{\"trigger\": true/false, \"reason\": \"不超过20字\"}}"
    )
}

/// `context` and `new` are rendered lines, oldest first.
pub fn user(context: &str, new: &str) -> String {
    let or_none = |text: &str| {
        if text.trim().is_empty() {
            "（无）".to_string()
        } else {
            text.trim_end().to_string()
        }
    };
    format!(
        "[上下文]\n{}\n\n[新消息]\n{}",
        or_none(context),
        or_none(new)
    )
}

#[derive(Deserialize)]
struct Raw {
    trigger: bool,
    #[serde(default)]
    reason: Option<String>,
}

/// The first `{` through the last `}`, so fences and prose around the
/// object don't matter.
pub fn parse(text: &str) -> Option<Verdict> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    let raw: Raw = serde_json::from_str(text.get(start..=end)?).ok()?;
    let reason = raw.reason.unwrap_or_default();
    Some(Verdict {
        trigger: raw.trigger,
        reason: reason.trim().chars().take(NOTE_CHARS).collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prompt() {
        let persona = "猫".repeat(600);
        let system = system(&persona);
        assert!(system.contains(&"猫".repeat(500)));
        assert!(!system.contains(&"猫".repeat(501)));
        assert!(system.contains(r#"{"trigger": true/false,"#));
        let user = user("", "[10:00 小明 #7]: max 在吗\n");
        assert_eq!(
            user,
            "[上下文]\n（无）\n\n[新消息]\n[10:00 小明 #7]: max 在吗"
        );
    }

    #[test]
    fn parsing_tolerates_fences_and_gaps() {
        let fenced = "```json\n{\"trigger\": true, \"reason\": \" 在追问 \"}\n```";
        assert_eq!(
            parse(fenced),
            Some(Verdict {
                trigger: true,
                reason: "在追问".into(),
            })
        );
        // What the old prompt asked for still parses.
        let old = r#"{"trigger": false, "kind": "topic", "dismiss": true}"#;
        assert_eq!(parse(old).map(|verdict| verdict.trigger), Some(false));
        let long = format!(r#"{{"trigger": true, "reason": "{}"}}"#, "长".repeat(100));
        assert_eq!(parse(&long).unwrap().reason.chars().count(), NOTE_CHARS);
        assert_eq!(parse("不接"), None);
        assert_eq!(parse(r#"{"reason": "在问"}"#), None);
        assert_eq!(parse("} {"), None);
    }
}
