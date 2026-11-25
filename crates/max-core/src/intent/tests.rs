use std::time::Duration;

use super::*;

struct Clock(Instant);

impl Clock {
    fn at(&self, secs: u64) -> Instant {
        self.0 + Duration::from_secs(secs)
    }
}

fn entry(id: i64, kind: EntryKind) -> Entry {
    Entry {
        id: MessageId::new(id),
        kind,
    }
}

fn chat(id: i64) -> Entry {
    entry(id, EntryKind::Chatter)
}

fn direct(ids: &[i64]) -> Decision {
    Decision::Wake {
        ids: ids.iter().copied().map(MessageId::new).collect(),
        reason: Reason::Direct,
    }
}

fn verdict(trigger: bool) -> Option<Verdict> {
    Some(Verdict {
        trigger,
        reason: "在问 Max".into(),
    })
}

#[test]
fn a_direct_trigger_wakes_at_once() {
    let mut intent = Intent::new();
    let e = entry(1, EntryKind::Direct);
    assert_eq!(intent.observe(&e), [direct(&[1])]);
    // A command wakes nobody: the actor runs it.
    assert!(intent.observe(&entry(2, EntryKind::Command)).is_empty());
}

#[test]
fn judged_wakes_are_capped() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    let mut woken = 0;
    // Two more than the cap, a minute apart: all within the hour.
    let tries = i64::try_from(JUDGED_WAKES_PER_HOUR).unwrap() + 2;
    for i in 0..tries {
        let at = clock.at(i.unsigned_abs() * 60);
        intent.observe(&chat(i));
        woken += intent.verdict(verdict(true), at).len();
    }
    assert_eq!(woken, JUDGED_WAKES_PER_HOUR);
    // An hour after the first, there is room again.
    intent.observe(&chat(tries));
    assert_eq!(intent.verdict(verdict(true), clock.at(3600)).len(), 1);
}

#[test]
fn proactive_off_leaves_only_direct_triggers() {
    let clock = Clock(Instant::now());
    let mut intent = Intent::new();
    intent.observe(&chat(1));
    intent.observe(&chat(2));
    intent.set_proactive(false);
    // Neither the verdict in flight nor what waited behind it wakes anyone.
    assert!(intent.verdict(verdict(true), clock.at(20)).is_empty());
    assert!(intent.observe(&chat(3)).is_empty());
    let e = entry(4, EntryKind::Direct);
    assert_eq!(intent.observe(&e), [direct(&[4])]);
}
