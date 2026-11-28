//! The classifier's prompt and its answer. The classify task reads the
//! ledger and renders the lines; everything here is text in, text out.

use std::collections::BTreeMap;

use serde::Deserialize;

use super::Verdict;
use crate::ids::PrincipalId;
use crate::render::mentions;

/// A longer reason is cut: it goes into the core's input as the
/// `[判定 …]` line.
pub const NOTE_CHARS: usize = 40;

/// The classifier's system prompt: the two cases that wake Max, each with
/// examples, and examples of the rest. It says what maxx can do and nothing
/// of its persona, which a small model reads as a reason to join in.
pub const SYSTEM: &str = "你是群聊成员「maxx」的触发判定器。maxx 是群里的 AI，以前叫 Max，群友叫它 max、maxx、鲨鱼都是在叫它。它能搜网页、查资料、算东西、写代码和跑代码、看图。

给你一段群聊上下文和几条新消息。每行的格式是 [时间 名字 #编号]: 内容，“@名字”是在叫那个人，[reply#编号] 是在回复那条消息。@maxx 的和回复 maxx 的消息已经直接交给它了，到你这里的都是没 @ 它、也没回复它的消息。

群里的消息绝大多数是成员之间在聊天，结论是 false。结论是 true 的只有两种：

一、新消息在叫 maxx，或者在找它办事，只是没用 @：
“max 帮我看看这个报错” → true
“@maxx 这是真的吗”（手打的 @）→ true
“鲨鱼你觉得呢” → true
“maxx 怎么不理我” → true

二、新消息向全群问了一个要答案的问题（事实、技术、怎么做），不是问某个人的，上下文里也还没人回答：
“有人知道 nginx 怎么反代 websocket 吗” → true
“这个报错是啥意思” → true

其余都是 false：
“不冷”“草”“确实”“哈哈哈”这类接别人话的短句 → false
“@小明 你那个弄好了吗”“[reply#12] 我觉得不行” → false，在跟那个人说话
“你让 ai 看看”“去问 max 啊” → false，在跟别人说话
“max 刚才说的好长”“这机器人话真多” → false，在议论 maxx，没叫它
“谁问你了”“别说了” → false
“今天好累”“发工资了”“这游戏真好玩” → false，在闲聊
机器人的播报、告警、签到，贴进来的代码和通知 → false

先看新消息是对谁说的、要什么，再下结论。只输出一行 JSON：
{\"reason\": \"对谁说的、要什么，不超过20字\", \"trigger\": true/false}";

/// `[mention#N]` as `@名字`: a small model reads who is spoken to from the
/// name, where the core has a roster to look it up in. Max's name is in
/// `names` like anyone's; someone missing is `@某人`.
pub fn named(text: &str, names: &BTreeMap<PrincipalId, String>) -> String {
    let mut out = String::with_capacity(text.len());
    let mut from = 0;
    for mention in mentions(text) {
        if !text[mention.end..].starts_with(']') {
            continue;
        }
        out.push_str(&text[from..mention.start]);
        out.push('@');
        out.push_str(names.get(&mention.principal).map_or("某人", String::as_str));
        from = mention.end + 1;
    }
    out.push_str(&text[from..]);
    out
}

/// `context` and `new` are rendered lines, oldest first.
#[must_use]
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
#[must_use]
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
    fn mentions_read_by_name() {
        let names = [(PrincipalId::new(12), "小明".to_owned())].into();
        let text =
            "[mention#12] 看 [mention#7]，[mention#12: 小明] [mention#] [mention#[mention#12]";
        assert_eq!(
            named(text, &names),
            "@小明 看 @某人，[mention#12: 小明] [mention#] [mention#@小明"
        );
        let whom: Vec<i64> = mentions(text).map(|one| one.principal.get()).collect();
        assert_eq!(whom, [12, 7, 12, 12]);
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
        let long = format!(r#"{{"trigger": true, "reason": "{}"}}"#, "长".repeat(100));
        assert_eq!(parse(&long).unwrap().reason.chars().count(), NOTE_CHARS);
        assert_eq!(parse("不接"), None);
        assert_eq!(parse(r#"{"reason": "在问"}"#), None);
        assert_eq!(parse("} {"), None);
    }
}
