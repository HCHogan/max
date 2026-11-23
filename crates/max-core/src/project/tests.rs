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
    let huge = Budgets::for_window(1_048_576);
    assert_eq!(
        (huge.tail_high, huge.tail_low, huge.single),
        (64_000, 32_000, 25_000)
    );
    let big = Budgets::for_window(256_000);
    assert_eq!(
        (big.tail_high, big.tail_low, big.single),
        (32_000, 16_000, 25_000)
    );
    let small = Budgets::for_window(32_000);
    assert_eq!(
        (small.tail_high, small.tail_low, small.single),
        (4_000, 2_000, 4_800)
    );
    assert_eq!(Budgets::for_window(8_000).single, 2_000);
}

#[test]
fn the_tail_is_cut_in_whole_stretches() {
    let budgets = Budgets {
        tail_high: 100,
        tail_low: 50,
        single: 0,
    };
    let rows = |n| vec![10; n];
    assert_eq!(tail_start(&rows(10), &budgets), 0);
    // Over 100: drop 50, leaving the low watermark and a bit.
    assert_eq!(tail_start(&rows(11), &budgets), 5);
    // The start stays put as rows arrive...
    assert_eq!(tail_start(&rows(15), &budgets), 5);
    // ...until the tail is over 100 again.
    assert_eq!(tail_start(&rows(16), &budgets), 10);
    // Far over, as before the first cut: the low watermark or more.
    assert_eq!(tail_start(&rows(1_000), &budgets), 990);
    assert_eq!(tail_start(&[1_000], &budgets), 1);
}

#[test]
fn the_base_context() {
    let volatile = Volatile {
        now: utc(10, 28, 6, 5),
        roster: vec!["[mention#12] 小明".into()],
        askable: Vec::new(),
        askers: Vec::new(),
        memory: "# 记忆\n- 群友叫你小鲨鲨（2026-08-28 #3）".into(),
        quoted: String::new(),
        first: "[14:04 小明 #9 @你]: 在吗\n".into(),
    };
    let linked = Volatile {
        askable: vec!["c#9 示波器同好会".into(), "c#12".into()],
        askers: vec!["c#3 小明".into()],
        ..volatile.clone()
    };
    let volatile = volatile.render(china());
    assert_eq!(
        volatile,
        "[现在] 2026-10-28 周三 14:05\n\n[上下文里的人]\n[mention#12] 小明\n\n[记忆]\n# 记忆\n- 群友叫你小鲨鲨（2026-08-28 #3）\n\n[新消息]\n[14:04 小明 #9 @你]: 在吗\n"
    );
    // Whom Max here may ask, and who may ask it, after the people.
    assert_eq!(
        linked.render(china()),
        volatile.replace(
            "小明\n\n[记忆]",
            "小明\n\n[能问的会话]\nc#9 示波器同好会\nc#12\n\n[能进来的会话]\nc#3 小明\n\n[记忆]"
        )
    );
    let context = context(
        "你是 Max".into(),
        [
            String::new(),
            "--- 2026-10-28 周三 ---\n".into(),
            "[09:00 小明 #8]: 早\n".into(),
            volatile,
        ],
        [PrincipalId::new(12)].into(),
        |text| u32::try_from(text.chars().count()).unwrap(),
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
    assert_eq!(
        kinds,
        [("system", 6), ("user", 22), ("user", 17), ("user", 115)]
    );
    assert_eq!(context.roster, [PrincipalId::new(12)].into());
}
