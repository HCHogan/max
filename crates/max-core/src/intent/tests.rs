use super::*;

const MAX: IdentityId = IdentityId(1);
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

fn verdict(trigger: bool, kind: Kind, dismiss: bool) -> Option<Verdict> {
    Some(Verdict {
        trigger,
        kind,
        reason: "在追问".into(),
        dismiss,
    })
}

fn judged(ids: &[i64], kind: Kind) -> Decision {
    Decision::Wake {
        ids: ids.iter().copied().map(MessageId).collect(),
        reason: Reason::Judged {
            kind,
            note: "在追问".into(),
        },
    }
}

#[test]
fn a_direct_trigger_wakes_at_once() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    let e = entry(1, XIAOMING, EntryKind::Direct, "这个怎么修？");
    assert_eq!(intent.observe(&e, clock.at(0)), [direct(&[1])]);
    assert_eq!(intent.deadline(), None);
}

#[test]
fn a_trigger_mid_sentence_waits_for_the_rest() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    let e = entry(1, XIAOMING, EntryKind::Direct, "我跟你讲，");
    assert!(intent.observe(&e, clock.at(0)).is_empty());
    assert_eq!(intent.deadline(), Some(clock.at(10)));
    // Someone else's message neither merges nor delays it.
    intent.observe(
        &entry(2, XIAOHONG, EntryKind::Command, "!status"),
        clock.at(2),
    );
    intent.observe(
        &entry(3, XIAOMING, EntryKind::Chatter, "昨天那个bug"),
        clock.at(3),
    );
    assert_eq!(
        intent.held().collect::<Vec<_>>(),
        [MessageId(1), MessageId(3)]
    );
    assert!(intent.tick(clock.at(12)).is_empty());
    assert_eq!(intent.tick(clock.at(13)), [direct(&[1, 3])]);
    assert_eq!(intent.held().count(), 0);
}

#[test]
fn a_hold_ends_after_twenty_seconds_however_much_follows() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
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
    let mut intent = Intent::new(Config::default());
    intent.observe(
        &entry(1, XIAOMING, EntryKind::Command, "!help"),
        clock.at(0),
    );
    intent.observe(&entry(2, XIAOMING, EntryKind::Quiet, "看"), clock.at(1));
    let e = entry(3, XIAOMING, EntryKind::Direct, "帮我看看");
    assert!(intent.observe(&e, clock.at(2)).is_empty());
    assert_eq!(intent.tick(clock.at(12)), [direct(&[3])]);
}

#[test]
fn chatter_is_classified_through_the_gate() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    let chat = |id, text: &str| entry(id, XIAOMING, EntryKind::Chatter, text);
    // The first plain chatter in fifteen minutes goes through; the next doesn't.
    assert_eq!(
        intent.observe(&chat(1, "今天吃什么"), clock.at(0)),
        [classify(&[1])]
    );
    assert!(intent.observe(&chat(2, "火锅吧"), clock.at(60)).is_empty());
    // Naming Max always goes through, but waits for the one in flight.
    assert!(intent.observe(&chat(3, "问问MAX"), clock.at(70)).is_empty());
    assert_eq!(
        intent.verdict(verdict(false, Kind::Topic, false), clock.at(75)),
        [classify(&[3])]
    );
    assert!(intent.verdict(None, clock.at(80)).is_empty());
    assert_eq!(
        intent.observe(&chat(4, "那个呢"), clock.at(15 * 60)),
        [classify(&[4])]
    );
}

#[test]
fn after_max_speaks_chatter_is_classified_as_it_comes() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    intent.observe(&entry(1, MAX, EntryKind::Max, "好的"), clock.at(0));
    let chat = |id| entry(id, XIAOMING, EntryKind::Chatter, "嗯");
    assert_eq!(intent.observe(&chat(2), clock.at(10)), [classify(&[2])]);
    assert!(intent.observe(&chat(3), clock.at(20)).is_empty());
    assert!(intent.observe(&chat(4), clock.at(30)).is_empty());
    assert_eq!(
        intent.verdict(verdict(true, Kind::Followup, false), clock.at(40)),
        [judged(&[2], Kind::Followup), classify(&[3, 4])]
    );
    assert!(intent.observe(&chat(5), clock.at(181)).is_empty());
}

#[test]
fn a_batch_keeps_the_newest() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    intent.observe(&entry(1, MAX, EntryKind::Max, "好的"), clock.at(0));
    intent.observe(&entry(2, XIAOMING, EntryKind::Chatter, "嗯"), clock.at(1));
    for id in 3..=40 {
        intent.observe(
            &entry(id, XIAOHONG, EntryKind::Chatter, "刷屏"),
            clock.at(2),
        );
    }
    let next = intent.verdict(None, clock.at(3));
    assert_eq!(next, [classify(&(11..=40).collect::<Vec<_>>())]);
}

#[test]
fn direct_triggers_in_a_batch_only_count_for_dismiss() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    intent.observe(&entry(1, MAX, EntryKind::Max, "好的"), clock.at(0));
    let e = entry(2, XIAOMING, EntryKind::Direct, "别说了");
    assert_eq!(
        intent.observe(&e, clock.at(10)),
        [classify(&[2]), direct(&[2])]
    );
    assert!(
        intent
            .verdict(verdict(true, Kind::Followup, true), clock.at(11))
            .is_empty()
    );
    assert_eq!(intent.status(clock.at(11)).cap, 4);
}

#[test]
fn judged_wakes_are_capped() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    let mut woken = 0;
    for i in 0..10 {
        let at = clock.at(i * 60);
        intent.observe(
            &entry(i as i64, XIAOMING, EntryKind::Chatter, "max在吗"),
            at,
        );
        let decisions = intent.verdict(verdict(true, Kind::Called, false), at);
        woken += decisions.len();
    }
    assert_eq!(woken, 8);
    // An hour after the first, there is room again.
    intent.observe(
        &entry(20, XIAOMING, EntryKind::Chatter, "max在吗"),
        clock.at(3600),
    );
    assert_eq!(
        intent
            .verdict(verdict(true, Kind::Called, false), clock.at(3600))
            .len(),
        1
    );
}

#[test]
fn topics_cool_down_and_stop_when_dismissed() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    let topic = |intent: &mut Intent, id: i64, secs: u64, dismiss: bool| {
        intent.observe(
            &entry(id, XIAOMING, EntryKind::Chatter, "max 看看"),
            clock.at(secs),
        );
        intent
            .verdict(verdict(!dismiss, Kind::Topic, dismiss), clock.at(secs))
            .len()
    };
    assert_eq!(topic(&mut intent, 1, 0, false), 1);
    assert_eq!(topic(&mut intent, 2, 100, false), 0);
    assert_eq!(topic(&mut intent, 3, 300, false), 1);
    topic(&mut intent, 4, 400, true);
    assert_eq!(topic(&mut intent, 5, 1000, false), 0);
    let status = intent.status(clock.at(1000));
    assert_eq!((status.cap, status.dismissed_for.is_some()), (4, true));
    intent.set_proactive(true);
    assert_eq!(intent.status(clock.at(1000)).dismissed_for, None);
}

#[test]
fn proactive_off_leaves_only_direct_triggers() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    intent.set_proactive(false);
    intent.observe(&entry(1, MAX, EntryKind::Max, "好的"), clock.at(0));
    assert!(
        intent
            .observe(&entry(2, XIAOMING, EntryKind::Chatter, "max"), clock.at(1))
            .is_empty()
    );
    let e = entry(3, XIAOMING, EntryKind::Direct, "在吗？");
    assert_eq!(intent.observe(&e, clock.at(2)), [direct(&[3])]);
}

#[test]
fn whether_judged_wakes_are_taken_up() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new(Config::default());
    let judge = |intent: &mut Intent, id: i64, secs: u64| {
        intent.observe(
            &entry(id, XIAOMING, EntryKind::Chatter, "max"),
            clock.at(secs),
        );
        intent.verdict(verdict(true, Kind::Called, false), clock.at(secs));
        intent.observe(
            &entry(id + 100, MAX, EntryKind::Max, "我在"),
            clock.at(secs + 5),
        );
    };
    judge(&mut intent, 1, 0);
    intent.observe(&entry(2, XIAOMING, EntryKind::Direct, "好耶"), clock.at(60));
    intent.verdict(None, clock.at(61)); // the classification it set off in the hot window
    judge(&mut intent, 3, 600);
    intent.tick(clock.at(1000));
    let status = intent.status(clock.at(1000));
    assert_eq!((status.taken_up, status.spoken_on), (1, 2));
}
