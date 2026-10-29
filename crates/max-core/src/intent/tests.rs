use super::*;

const XIAOMING: IdentityId = IdentityId(20);
const XIAOHONG: IdentityId = IdentityId(21);

struct Clock(Instant);

impl Clock {
    fn at(&self, secs: u64) -> Instant {
        self.0 + Duration::from_secs(secs)
    }
}

fn entry(id: i64, sender: IdentityId, kind: EntryKind, text: &str) -> Entry {
    Entry {
        id: MessageId(id),
        sender,
        kind,
        text: text.into(),
    }
}

fn chat(id: i64) -> Entry {
    entry(id, XIAOMING, EntryKind::Chatter, "今天吃什么")
}

fn direct(ids: &[i64]) -> Decision {
    Decision::Wake {
        ids: ids.iter().copied().map(MessageId).collect(),
        reason: Reason::Direct,
    }
}

fn classify(ids: &[i64]) -> Decision {
    Decision::Classify {
        batch: ids.iter().copied().map(MessageId).collect(),
    }
}

fn verdict(trigger: bool) -> Option<Verdict> {
    Some(Verdict {
        trigger,
        reason: "在问 Max".into(),
    })
}

fn judged(ids: &[i64]) -> Decision {
    Decision::Wake {
        ids: ids.iter().copied().map(MessageId).collect(),
        reason: Reason::Judged {
            note: "在问 Max".into(),
        },
    }
}

#[test]
fn a_direct_trigger_wakes_at_once() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    let e = entry(1, XIAOMING, EntryKind::Direct, "这个怎么修？");
    assert_eq!(intent.observe(&e, clock.at(0)), [direct(&[1])]);
    assert_eq!(intent.deadline(), None);
}

#[test]
fn a_trigger_mid_sentence_waits_for_the_rest() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    let e = entry(1, XIAOMING, EntryKind::Direct, "我跟你讲，");
    assert!(intent.observe(&e, clock.at(0)).is_empty());
    assert_eq!(intent.deadline(), Some(clock.at(10)));
    // Someone else's message neither merges nor delays it, nor does a
    // command.
    intent.observe(
        &entry(2, XIAOHONG, EntryKind::Command, "/status"),
        clock.at(2),
    );
    intent.observe(
        &entry(3, XIAOMING, EntryKind::Chatter, "昨天那个bug"),
        clock.at(3),
    );
    intent.observe(
        &entry(4, XIAOMING, EntryKind::Command, "/status"),
        clock.at(3),
    );
    assert!(intent.tick(clock.at(12)).is_empty());
    assert_eq!(intent.tick(clock.at(13)), [direct(&[1, 3])]);
    assert_eq!(intent.deadline(), None);
}

#[test]
fn a_hold_ends_after_twenty_seconds_however_much_follows() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    intent.observe(&entry(1, XIAOMING, EntryKind::Direct, ""), clock.at(0));
    for (i, secs) in [5, 10, 15].into_iter().enumerate() {
        let e = entry(2 + i as i64, XIAOMING, EntryKind::Chatter, "还有");
        intent.observe(&e, clock.at(secs));
    }
    assert_eq!(intent.deadline(), Some(clock.at(20)));
    assert_eq!(intent.tick(clock.at(20)), [direct(&[1, 2, 3, 4])]);
}

#[test]
fn a_burst_of_messages_holds_the_trigger() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    intent.observe(
        &entry(1, XIAOMING, EntryKind::Command, "/compact"),
        clock.at(0),
    );
    intent.observe(
        &entry(2, XIAOMING, EntryKind::Command, "/status"),
        clock.at(1),
    );
    let e = entry(3, XIAOMING, EntryKind::Direct, "帮我看看");
    assert!(intent.observe(&e, clock.at(2)).is_empty());
    assert_eq!(intent.tick(clock.at(12)), [direct(&[3])]);
}

#[test]
fn chatter_waits_for_the_classification_in_flight() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    assert_eq!(intent.observe(&chat(1), clock.at(0)), [classify(&[1])]);
    assert!(intent.observe(&chat(2), clock.at(10)).is_empty());
    assert!(intent.observe(&chat(3), clock.at(20)).is_empty());
    assert_eq!(
        intent.verdict(verdict(true), clock.at(30)),
        [judged(&[1]), classify(&[2, 3])]
    );
    assert!(intent.verdict(None, clock.at(40)).is_empty());
    assert_eq!(intent.observe(&chat(4), clock.at(50)), [classify(&[4])]);
}

#[test]
fn a_batch_keeps_the_newest() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    intent.observe(&chat(1), clock.at(0));
    for id in 2..=40 {
        intent.observe(
            &entry(id, XIAOHONG, EntryKind::Chatter, "刷屏"),
            clock.at(1),
        );
    }
    let next = intent.verdict(None, clock.at(3));
    assert_eq!(next, [classify(&(11..=40).collect::<Vec<_>>())]);
}

#[test]
fn judged_wakes_are_capped() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    let mut woken = 0;
    for i in 0..10 {
        let at = clock.at(i * 60);
        intent.observe(&chat(i as i64), at);
        woken += intent.verdict(verdict(true), at).len();
    }
    assert_eq!(woken, MAX_PER_HOUR);
    // An hour after the first, there is room again.
    intent.observe(&chat(20), clock.at(3600));
    assert_eq!(intent.verdict(verdict(true), clock.at(3600)).len(), 1);
}

#[test]
fn proactive_off_leaves_only_direct_triggers() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    intent.observe(&chat(1), clock.at(0));
    intent.observe(&chat(2), clock.at(10));
    intent.set_proactive(false);
    // Neither the verdict in flight nor what waited behind it wakes anyone.
    assert!(intent.verdict(verdict(true), clock.at(20)).is_empty());
    assert!(intent.observe(&chat(3), clock.at(30)).is_empty());
    let e = entry(4, XIAOMING, EntryKind::Direct, "在吗？");
    assert_eq!(intent.observe(&e, clock.at(40)), [direct(&[4])]);
}
