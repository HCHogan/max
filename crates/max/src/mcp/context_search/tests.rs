use chrono::TimeDelta;

use super::*;
use crate::conversation::testing::{at, offset};

fn hit(kind: Kind, n: i64, score: f32, key: &str) -> Hit {
    Hit {
        kind,
        handle: format!("{n}"),
        time: String::new(),
        text: String::new(),
        read: Value::Null,
        score,
        at: at(0) + TimeDelta::minutes(n),
        key: key.into(),
    }
}

fn handles(hits: &[Hit]) -> Vec<&str> {
    hits.iter().map(|hit| hit.handle.as_str()).collect()
}

#[test]
fn terms_are_words_between_spaces_lowercased_once() {
    assert_eq!(
        terms(" GitHub  部署\u{3000}github 方案 ").unwrap(),
        ["github", "部署", "方案"]
    );
    assert_eq!(terms("  ").unwrap_err().code, "bad_arguments");
    assert!(terms("一 二 三 四 五 六 七 八").is_ok());
    assert_eq!(
        terms("一 二 三 四 五 六 七 八 九").unwrap_err().code,
        "bad_arguments"
    );
    assert_eq!(terms(&"长".repeat(51)).unwrap_err().code, "bad_arguments");
    assert_eq!(pattern(r"100%_a\b"), r"%100\%\_a\\b%");
}

#[test]
fn snippets_center_on_the_first_hit() {
    assert_eq!(snippet("短的一句", &["一"]), "短的一句");
    let long = format!("{}Deploy 了{}", "前".repeat(100), "后".repeat(300));
    let cut = snippet(&long, &["后后", "deploy"]);
    assert!(
        cut.starts_with(&format!("…{}Deploy 了", "前".repeat(40))),
        "{cut}"
    );
    assert!(cut.ends_with('…'));
    assert_eq!(cut.chars().count(), SNIPPET + 2);
    // A hit at the start, or none, shows the start; one at the end, the end.
    let start = snippet(&long, &["前前"]);
    assert!(start.starts_with("前前") && start.ends_with('…'));
    assert_eq!(snippet(&long, &["没有"]), start);
    let last = format!("{}末尾", "前".repeat(300));
    let end = snippet(&last, &["末尾"]);
    assert!(end.starts_with('…') && end.ends_with("末尾"), "{end}");
}

#[test]
fn dates_are_whole_local_days() {
    let (from, until) = window(Some("2026-10-03"), Some("2026-10-04"), offset()).unwrap();
    assert_eq!(from.unwrap().to_rfc3339(), "2026-10-02T16:00:00+00:00");
    assert_eq!(until.unwrap().to_rfc3339(), "2026-10-04T16:00:00+00:00");
    assert_eq!(window(None, None, offset()).unwrap(), (None, None));
    for (from, to) in [
        (Some("10-03"), None),
        (Some("2026-10-05"), Some("2026-10-04")),
    ] {
        assert_eq!(
            window(from, to, offset()).unwrap_err().code,
            "bad_arguments"
        );
    }
}

#[test]
fn no_kind_takes_more_than_two_thirds_while_another_has_hits() {
    let messages = (0..5).map(|n| hit(Kind::Message, n, 1.0, &n.to_string()));
    let mut hits: Vec<Hit> = messages.collect();
    hits.push(hit(Kind::Summary, 10, 0.5, "s10"));
    hits.push(hit(Kind::Summary, 11, 0.5, "s11"));
    assert_eq!(handles(&choose(hits, 3)), ["4", "3", "11"]);

    // With nothing else, one kind fills them all.
    let hits = (0..5).map(|n| hit(Kind::Message, n, 1.0, &n.to_string()));
    assert_eq!(handles(&choose(hits.collect(), 3)), ["4", "3", "2"]);

    // A message said again is one result: the best of them.
    let hits = vec![
        hit(Kind::Message, 1, 0.5, "哈哈"),
        hit(Kind::Message, 2, 1.0, "部署"),
        hit(Kind::Message, 3, 0.5, "哈哈"),
    ];
    assert_eq!(handles(&choose(hits, 10)), ["2", "3"]);
}
