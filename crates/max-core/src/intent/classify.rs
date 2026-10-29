//! The classifier's prompt and its answer. The classify task reads the
//! ledger and renders the lines; everything here is text in, text out.

use std::collections::BTreeMap;

use serde::Deserialize;

use super::Verdict;
use crate::ids::PrincipalId;

/// How much of the persona the classifier sees.
pub const PERSONA_CHARS: usize = 500;

/// A longer reason is cut: it goes into the core's input as the
/// `[判定 …]` line.
pub const NOTE_CHARS: usize = 40;

pub fn system(persona: &str) -> String {
    let persona: String = persona.chars().take(PERSONA_CHARS).collect();
    format!(
        "你是多人群聊 agent「maxx」的触发判定器。它以前叫 Max，群里叫它 max 或 maxx 都是在叫它。maxx 的人设：
{persona}

给你一段群聊上下文和几条新消息。每行的格式是 [时间 名字 #编号 标记]: 内容，标记里的“你”指 maxx。判断 maxx 是否应该主动接话。

应该接话（trigger=true）：
1. 有人在叫 maxx 或找它帮忙，只是没打 @ —— 如“max帮我看看”“机器人查一下”“maxx你觉得呢”。
2. maxx 刚参与的对话有了后续：有人在回应、追问或反驳 maxx 刚说的话。
3. 正在讨论 maxx 感兴趣的话题，且它能给出具体有用的东西（答案、纠错、关键信息）。

不该接话（trigger=false）：
- 成员之间的日常闲聊，与 maxx 无关；
- 只是顺带提到/议论 maxx，不是在跟它说话；
- 有人叫 maxx 少说话、别插嘴，或者明显嫌它烦；
- 其他机器人发的机械消息（播报、复读、签到等）；
- 第 3 类要格外克制：只能附和、发感想、抖机灵的不算；上下文里 maxx 已经插过话的话题，别人没接它的茬就不要再插；
- 拿不准的一律 false —— 插错话比沉默尴尬得多，偶尔插话才有惊喜，频繁插话只会烦人。

只输出一行 JSON，不要其他内容：
{{\"trigger\": true/false, \"reason\": \"不超过20字\"}}"
    )
}

/// `[mention#N]` as `@名字`: a small model reads who is spoken to from the
/// name, where the core has a roster to look it up in. Max's name is in
/// `names` like anyone's; someone missing is `@某人`.
pub fn named(text: &str, names: &BTreeMap<PrincipalId, String>) -> String {
    const TOKEN: &str = "[mention#";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(TOKEN) {
        out += &rest[..at];
        let after = &rest[at + TOKEN.len()..];
        let digits = after
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(after.len());
        let principal = after[..digits].parse().ok().map(PrincipalId);
        match principal {
            Some(principal) if after[digits..].starts_with(']') => {
                let name = names.get(&principal).map_or("某人", String::as_str);
                out += "@";
                out += name;
                rest = &after[digits + 1..];
            }
            _ => {
                out += TOKEN;
                rest = after;
            }
        }
    }
    out + rest
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
    fn mentions_become_names() {
        let names = BTreeMap::from([
            (PrincipalId(1), "maxx".to_owned()),
            (PrincipalId(2), "小明".to_owned()),
        ]);
        let line =
            "[10:00 小红 #7]: [mention#2] 你让ai看 [mention#1] [mention#9] [mention#x] [mention#3";
        assert_eq!(
            named(line, &names),
            "[10:00 小红 #7]: @小明 你让ai看 @maxx @某人 [mention#x] [mention#3"
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
