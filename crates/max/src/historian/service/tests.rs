use max_core::ids::{EndpointId, IdentityId, PrincipalId};
use max_core::message::Platform;
use max_db::platform::{Account, ConversationKind};

use super::*;

fn place(conversation: i64) -> Arc<Place> {
    Arc::new(Place {
        conversation: ConversationId(conversation),
        kind: ConversationKind::Group,
        endpoint: EndpointId(conversation),
        platform: Platform::Qq,
        native_id: format!("group:GROUP{conversation}"),
        me: Account {
            identity: IdentityId(1),
            principal: PrincipalId(1),
        },
        my_name: "maxx".into(),
    })
}

fn reasons(starts: &[Start]) -> Vec<(i64, Reason)> {
    let mut reasons: Vec<_> = starts
        .iter()
        .map(|start| (start.place.conversation.0, start.reason))
        .collect();
    reasons.sort_by_key(|(conversation, _)| *conversation);
    reasons
}

#[test]
fn a_busy_group_is_checked_once_a_minute_and_summarized_when_quiet() {
    let t0 = Instant::now();
    let mut watch = Watch::default();
    watch.said(place(1), t0);
    assert_eq!(reasons(&watch.due(t0)), [(1, Reason::Pressure)]);
    watch.done(ConversationId(1), false, t0);
    watch.said(place(1), t0 + Duration::from_secs(10));
    assert!(watch.due(t0 + Duration::from_secs(30)).is_empty());
    let minute = t0 + CHECK;
    assert_eq!(reasons(&watch.due(minute)), [(1, Reason::Pressure)]);
    watch.done(ConversationId(1), false, minute);
    // Quiet ten minutes after the last row, then not again until more is said.
    let quiet = t0 + Duration::from_secs(10) + QUIET;
    assert!(watch.due(quiet - Duration::from_secs(1)).is_empty());
    assert_eq!(reasons(&watch.due(quiet)), [(1, Reason::Quiet)]);
    watch.done(ConversationId(1), false, quiet);
    assert!(watch.due(quiet + QUIET).is_empty());
}

#[test]
fn captures_wait_their_turn_but_compact_doesnt() {
    let t0 = Instant::now();
    let mut watch = Watch::default();
    for conversation in 1..=3 {
        watch.said(place(conversation), t0);
    }
    assert_eq!(watch.due(t0).len(), CONCURRENT);
    let (reply, _answer) = oneshot::channel();
    let waiting = (1..=3)
        .find(|&c| !watch.conversations[&ConversationId(c)].running)
        .unwrap();
    watch.compact(place(waiting), reply, t0);
    let starts = watch.due(t0);
    assert_eq!(reasons(&starts), [(waiting, Reason::Compact)]);
    assert_eq!(starts[0].replies.len(), 1);
}

#[test]
fn a_failed_capture_rests_its_group() {
    let t0 = Instant::now();
    let mut watch = Watch::default();
    watch.said(place(1), t0);
    assert_eq!(watch.due(t0).len(), 1);
    watch.done(ConversationId(1), true, t0);
    watch.said(place(1), t0 + CHECK);
    assert!(watch.due(t0 + CHECK).is_empty());
    assert_eq!(reasons(&watch.due(t0 + REST)), [(1, Reason::Pressure)]);
}

#[test]
fn compact_waits_for_the_capture_running_in_its_group() {
    let t0 = Instant::now();
    let mut watch = Watch::default();
    watch.said(place(1), t0);
    assert_eq!(watch.due(t0).len(), 1);
    let (reply, _answer) = oneshot::channel();
    watch.compact(place(1), reply, t0);
    assert!(watch.due(t0).is_empty());
    watch.done(ConversationId(1), false, t0);
    assert_eq!(reasons(&watch.due(t0)), [(1, Reason::Compact)]);
}
