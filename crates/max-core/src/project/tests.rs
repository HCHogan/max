use chrono::TimeZone;

use super::*;

fn china() -> FixedOffset {
    FixedOffset::east_opt(8 * 3600).unwrap()
}

fn utc(month: u32, day: u32, hour: u32, minute: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, month, day, hour, minute, 0)
        .unwrap()
}

#[test]
fn budgets_follow_the_window() {
    let big = Budgets::for_window(256_000);
    assert_eq!(
        (big.tail_high, big.tail_low, big.summaries, big.single),
        (32_000, 16_000, 8_000, 25_000)
    );
    let small = Budgets::for_window(32_000);
    assert_eq!(
        (
            small.tail_high,
            small.tail_low,
            small.summaries,
            small.single
        ),
        (4_000, 2_000, 1_000, 4_800)
    );
    assert_eq!(Budgets::for_window(8_000).single, 2_000);
}

#[test]
fn the_tail_is_cut_in_whole_stretches() {
    let budgets = Budgets {
        tail_high: 100,
        tail_low: 50,
        summaries: 0,
        single: 0,
    };
    let rows = |n| vec![10; n];
    assert_eq!(tail_start(&rows(20), &budgets), 0);
    // Over 200: drop 150, leaving the low watermark and a bit.
    assert_eq!(tail_start(&rows(21), &budgets), 15);
    // The start stays put as rows arrive...
    assert_eq!(tail_start(&rows(35), &budgets), 15);
    // ...until the tail is over 200 again.
    assert_eq!(tail_start(&rows(36), &budgets), 30);
    assert_eq!(tail_start(&[1_000], &budgets), 1);
}

#[test]
fn summaries_render_at_their_level() {
    let old = Summary {
        id: SummaryId(1),
        started_at: utc(10, 3, 6, 2),
        ended_at: utc(10, 3, 8, 30),
        title: "去重庆玩的计划".into(),
        full: "小明和小红商量了……".into(),
        brief: Some("定了国庆去重庆。".into()),
        line: Some("10 月 3 日商量国庆去重庆".into()),
        costs: Costs {
            importance: 1,
            full: 300,
            brief: Some(100),
            line: Some(20),
        },
    };
    let imported = Summary {
        id: SummaryId(2),
        started_at: utc(10, 3, 15, 10),
        ended_at: utc(10, 3, 17, 20),
        title: "深夜修 bug".into(),
        full: "  [mention#12] 修好了登录。\n".into(),
        brief: None,
        line: None,
        costs: Costs {
            importance: 50,
            full: 40,
            brief: None,
            line: None,
        },
    };
    let summaries = [old, imported];
    // Tight: the old one is down to a line.
    assert_eq!(
        summary_block(&summaries, 34, china()),
        "[早先的聊天，摘要]\n\
         [summary#1 2026-10-03 周六 14:02–16:30] 10 月 3 日商量国庆去重庆\n\
         \n\
         [summary#2 2026-10-03 周六 23:10 – 10-04 01:20] 深夜修 bug\n\
         [mention#12] 修好了登录。\n"
    );
    // Roomy: in full.
    assert!(
        summary_block(&summaries, 10_000, china()).contains("去重庆玩的计划\n小明和小红商量了……")
    );
    assert_eq!(summary_block(&[], 100, china()), "");
}

#[test]
fn roster_lines_and_mentions() {
    let line = roster_line(PrincipalId(12), "小\n明", Some(Role::Admin), false);
    assert_eq!(line, "[mention#12] 小 明（管理员）");
    assert_eq!(
        roster_line(PrincipalId(1), "Max", None, true),
        "[mention#1] Max（你）"
    );
    assert_eq!(
        roster_line(PrincipalId(3), "小红", Some(Role::Member), false),
        "[mention#3] 小红"
    );
    let text = "[mention#12] 和 [mention#7: 小红] 聊了 [mention#x] [mention#12]";
    assert_eq!(mentioned(text), [PrincipalId(7), PrincipalId(12)].into());
}

#[test]
fn the_base_context() {
    let volatile = Volatile {
        now: utc(10, 28, 6, 5),
        roster: vec!["[mention#12] 小明".into()],
        quoted: String::new(),
        first: "[14:04 小明 #9 @你]: 在吗\n".into(),
    };
    let volatile = volatile.render(china());
    assert_eq!(
        volatile,
        "[现在] 2026-10-28 周三 14:05\n\n[上下文里的人]\n[mention#12] 小明\n\n[新消息]\n[14:04 小明 #9 @你]: 在吗\n"
    );
    let context = context(
        "你是 Max".into(),
        [String::new(), "--- 2026-10-28 周三 ---\n".into(), volatile],
        [PrincipalId(12)].into(),
        |text| text.chars().count() as u32,
    );
    let kinds: Vec<(&str, u32)> = context
        .items
        .iter()
        .map(|item| match &item.kind {
            ItemKind::System { .. } => ("system", item.tokens),
            ItemKind::User { .. } => ("user", item.tokens),
            _ => ("other", item.tokens),
        })
        .collect();
    assert_eq!(kinds, [("system", 6), ("user", 22), ("user", 79)]);
    assert_eq!(context.roster, [PrincipalId(12)].into());
}
