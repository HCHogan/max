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

fn direct(ids: &[i64]) -> Decision {
    Decision::Wake {
        ids: ids.iter().copied().map(MessageId).collect(),
        reason: Reason::Direct,
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
