use chrono::{DateTime, Utc};

use super::*;
use crate::ids::SummaryId;
use crate::project::decay::Costs;

fn ids(ids: &[i64]) -> Vec<MessageId> {
    ids.iter().copied().map(MessageId).collect()
}

fn compartment(first: i64, last: i64) -> String {
    format!(
        r#"{{"first": {first}, "last": {last}, "title": "周末去哪", "kind": "decision", "importance": 70, "p1": "[mention#12] 提议周六去爬山，大家同意。", "p2": "周六爬山。", "p3": "10 月 25 日定了周六爬山"}}"#
    )
}

fn answer(compartments: &[(i64, i64)]) -> String {
    let parts: Vec<String> = compartments
        .iter()
        .map(|&(first, last)| compartment(first, last))
        .collect();
    format!(r#"{{"compartments": [{}]}}"#, parts.join(", "))
}

#[test]
fn compartments_cover_the_stretch_in_order() {
    // Ids skip: other conversations' rows fall in between.
    let stretch = ids(&[10, 12, 17, 18, 30]);
    let text = format!("```json\n{}\n```", answer(&[(10, 17), (18, 30)]));
    let parsed = parse(&text, &stretch).unwrap();
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].first, MessageId(10));
    assert_eq!(parsed[0].last, MessageId(17));
    assert_eq!(parsed[1].first, MessageId(18));
    assert_eq!(parsed[0].importance, 70);
    assert_eq!(parsed[0].line, "10 月 25 日定了周六爬山");
}

#[test]
fn gaps_overlaps_and_short_answers_are_refused() {
    let stretch = ids(&[10, 12, 17, 18, 30]);
    let gap = parse(&answer(&[(10, 12), (18, 30)]), &stretch);
    assert!(
        matches!(gap, Err(Invalid::Start { index: 1, .. })),
        "{gap:?}"
    );
    let overlap = parse(&answer(&[(10, 17), (17, 30)]), &stretch);
    assert!(matches!(overlap, Err(Invalid::Start { .. })), "{overlap:?}");
    let short = parse(&answer(&[(10, 17)]), &stretch);
    assert!(matches!(short, Err(Invalid::Short { .. })), "{short:?}");
    let backwards = parse(&answer(&[(12, 10)]), &ids(&[12, 10]));
    assert!(
        backwards.is_ok(),
        "the stretch's order counts, not the numbers"
    );
    let past = parse(&answer(&[(10, 31)]), &stretch);
    assert!(matches!(past, Err(Invalid::End { .. })), "{past:?}");
    let extra = parse(&answer(&[(10, 30), (31, 32)]), &stretch);
    assert!(
        matches!(extra, Err(Invalid::End { index: 1, .. })),
        "{extra:?}"
    );
    assert_eq!(
        parse(r#"{"compartments": []}"#, &stretch),
        Err(Invalid::Empty)
    );
    assert!(matches!(parse("算了", &stretch), Err(Invalid::Shape(_))));
}

#[test]
fn fields_are_checked() {
    let stretch = ids(&[1]);
    let with = |from: &str, to: &str| answer(&[(1, 1)]).replacen(from, to, 1);
    let kind = parse(&with("decision", "news"), &stretch);
    assert!(matches!(kind, Err(Invalid::Kind { .. })), "{kind:?}");
    let importance = parse(&with("70", "0"), &stretch);
    assert!(
        matches!(importance, Err(Invalid::Importance { .. })),
        "{importance:?}"
    );
    let empty = parse(&with("周末去哪", " "), &stretch);
    assert!(
        matches!(empty, Err(Invalid::Length { field: "title", .. })),
        "{empty:?}"
    );
    let long = "长".repeat(LINE_CHARS + 1);
    let line = parse(&with("10 月 25 日定了周六爬山", &long), &stretch);
    assert!(
        matches!(line, Err(Invalid::Length { field: "p3", .. })),
        "{line:?}"
    );
    let broken = with("10 月 25 日定了周六爬山", "10 月 25 日\\n定了爬山");
    assert_eq!(
        parse(&broken, &stretch).unwrap()[0].line,
        "10 月 25 日 定了爬山"
    );
}

#[test]
fn the_unsettled_last_compartment_waits() {
    let stretch = ids(&[1, 2, 3]);
    let two = parse(&answer(&[(1, 2), (3, 3)]), &stretch).unwrap();
    assert_eq!(settled(two.clone(), false).len(), 1);
    assert_eq!(settled(two, true).len(), 2);
    let one = parse(&answer(&[(1, 3)]), &stretch).unwrap();
    assert_eq!(
        settled(one, false).len(),
        1,
        "one is kept, or nothing moves"
    );
}

#[test]
fn earlier_summaries_are_shown_brief() {
    let at = |text: &str| text.parse::<DateTime<Utc>>().unwrap();
    let summary = |id, brief: Option<&str>| Summary {
        id: SummaryId(id),
        started_at: at("2026-10-25T06:02:00Z"),
        ended_at: at("2026-10-25T08:30:00Z"),
        title: "周末去哪".into(),
        full: "全文".into(),
        brief: brief.map(Into::into),
        line: None,
        costs: Costs {
            importance: 50,
            full: 1,
            brief: None,
            line: None,
        },
    };
    let offset = FixedOffset::east_opt(8 * 3600).unwrap();
    assert_eq!(
        earlier(&[summary(44, Some("简述")), summary(45, None)], offset),
        "[summary#44 2026-10-25 周日 14:02–16:30] 周末去哪\n简述\n\n[summary#45 2026-10-25 周日 14:02–16:30] 周末去哪\n全文"
    );
}

#[test]
fn max_is_listed_as_max() {
    let max = person(PrincipalId(3), "maxx", None, true);
    assert_eq!(max, "[mention#3] maxx（就是 maxx）");
    let owner = person(PrincipalId(12), "小明", Some(Role::Owner), false);
    assert_eq!(owner, "[mention#12] 小明（群主）");
}

#[test]
fn the_input_marks_what_is_missing() {
    let text = user(
        "[现在] 2026-10-29 周四 03:10\n",
        "",
        "[mention#12] 小明",
        "",
    );
    assert_eq!(
        text,
        "[现在] 2026-10-29 周四 03:10\n\n[之前的摘要]\n（无）\n\n[这段里的人]\n[mention#12] 小明\n\n[聊天记录]\n（无）"
    );
}
