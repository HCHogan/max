use color_eyre::eyre::eyre;
use max_core::ids::{EndpointId, IdentityId, MessageId, PrincipalId};
use max_core::message::{Content, Message, Platform, Sender};
use max_db::platform::Account;

use super::*;

fn place(conversation: i64, kind: ConversationKind) -> Arc<Place> {
    Arc::new(Place {
        conversation: ConversationId(conversation),
        kind,
        endpoint: EndpointId(1),
        platform: Platform::Qq,
        native_id: format!("group:GROUP{conversation}"),
        me: Account {
            identity: IdentityId(1),
            principal: PrincipalId(1),
        },
        my_name: "maxx".into(),
    })
}

fn row(conversation: i64, kind: ConversationKind) -> Notice {
    Notice::Row(Row {
        place: place(conversation, kind),
        message: Arc::new(Message {
            id: MessageId(1),
            conversation: ConversationId(conversation),
            sender: Sender {
                identity: IdentityId(1),
                name: "小明".into(),
                role: None,
            },
            at: chrono::Utc::now(),
            content: Content::Unsend {
                target: MessageId(0),
            },
            turn: None,
            raw: serde_json::Value::Null,
        }),
    })
}

fn group(conversation: i64) -> Notice {
    row(conversation, ConversationKind::Group)
}

/// What starts at `at`: each group, and why.
fn starting(schedule: &mut Schedule, at: Instant) -> (Vec<(i64, Reason)>, Vec<Start>) {
    let starts = schedule.start(at);
    let shown = starts
        .iter()
        .map(|start| (start.place.conversation.0, start.reason))
        .collect();
    (shown, starts)
}

fn ok() -> Result<Captured> {
    Ok(Captured::Nothing)
}

fn failed() -> Result<Captured> {
    Err(eyre!("the model said nothing"))
}

#[test]
fn a_check_waits_a_minute_from_the_first_row_and_a_summary_ten_from_the_last() {
    let t = Instant::now();
    let mut schedule = Schedule::default();
    schedule.hear(row(2, ConversationKind::Direct), t);
    assert_eq!(schedule.next(), None, "a private chat isn't summarized");

    schedule.hear(group(1), t);
    schedule.hear(group(1), t + Duration::from_secs(50));
    assert_eq!(schedule.next(), Some(t + CHECK));
    assert!(
        starting(&mut schedule, t + Duration::from_secs(59))
            .0
            .is_empty()
    );
    let (shown, mut starts) = starting(&mut schedule, t + CHECK);
    assert_eq!(shown, [(1, Reason::Pressure)]);
    // The quiet one is from the last row, and waits for the check.
    let quiet = t + Duration::from_secs(50) + QUIET;
    assert_eq!(schedule.next(), None);
    schedule.finished(starts.remove(0), ok(), t + CHECK);
    assert_eq!(schedule.next(), Some(quiet));
    let (shown, mut starts) = starting(&mut schedule, quiet);
    assert_eq!(shown, [(1, Reason::Quiet)]);
    schedule.finished(starts.remove(0), ok(), quiet);
    // Nothing is left of the group.
    assert!(schedule.groups.is_empty());
}

#[test]
fn compact_goes_first_and_waits_only_for_its_group() {
    let t = Instant::now();
    let mut schedule = Schedule::default();
    for conversation in 1..=3 {
        schedule.hear(group(conversation), t);
    }
    let (shown, mut starts) = starting(&mut schedule, t + CHECK);
    assert_eq!(shown.len(), AT_ONCE, "{shown:?}");
    let (busy, _) = shown[0];
    let (_, idle) = (1..=3)
        .map(|conversation| (shown.iter().any(|(c, _)| *c == conversation), conversation))
        .find(|(running, _)| !running)
        .unwrap();

    let (reply, mut answer) = oneshot::channel();
    let (other, mut other_answer) = oneshot::channel();
    for (conversation, reply) in [(busy, reply), (idle, other)] {
        let place = place(conversation, ConversationKind::Group);
        schedule.hear(Notice::Compact(Compact { place, reply }), t + CHECK);
    }
    // The idle group's starts though both places are taken.
    let (shown, mut compacts) = starting(&mut schedule, t + CHECK);
    assert_eq!(shown, [(idle, Reason::Compact)]);
    schedule.finished(compacts.remove(0), failed(), t + CHECK);
    let said = other_answer.try_recv().unwrap().unwrap_err();
    assert!(said.contains("said nothing"), "{said}");

    // The busy one's waits for its check; the place that frees goes to
    // the group still due.
    let first = starts
        .iter()
        .position(|start| start.place.conversation.0 == busy);
    schedule.finished(starts.remove(first.unwrap()), ok(), t + CHECK);
    let (shown, mut compacts) = starting(&mut schedule, t + CHECK);
    assert_eq!(shown, [(busy, Reason::Compact), (idle, Reason::Pressure)]);
    assert!(answer.try_recv().is_err());
    schedule.finished(compacts.remove(0), ok(), t + CHECK);
    assert!(matches!(answer.try_recv(), Ok(Ok(Captured::Nothing))));
}

#[test]
fn a_failed_check_rests_tries_once_more_and_then_waits_for_a_row() {
    let t = Instant::now();
    let mut schedule = Schedule::default();
    schedule.hear(group(1), t);
    let (_, mut starts) = starting(&mut schedule, t + CHECK);
    schedule.finished(starts.remove(0), failed(), t + CHECK);
    let rest = Due {
        at: t + CHECK + REST,
        retry: true,
    };
    assert_eq!(schedule.groups[&ConversationId(1)].pressure, Some(rest));
    // A row meanwhile doesn't bring it sooner.
    schedule.hear(group(1), t + CHECK);
    let again = &schedule.groups[&ConversationId(1)];
    assert_eq!(again.pressure, Some(rest));
    assert_eq!(again.quiet.map(|due| due.at), Some(t + CHECK + QUIET));
    let (shown, mut starts) = starting(&mut schedule, t + CHECK + REST);
    assert_eq!(shown, [(1, Reason::Pressure)]);
    assert!(starts[0].retry);
    schedule.finished(starts.remove(0), failed(), t + CHECK + REST);
    // Given up; the quiet summary from that row is still due.
    assert_eq!(schedule.groups[&ConversationId(1)].pressure, None);
    let (shown, mut starts) = starting(&mut schedule, t + CHECK + REST);
    assert_eq!(shown, [(1, Reason::Quiet)]);
    assert!(!starts[0].retry);
    schedule.finished(starts.remove(0), ok(), t + CHECK + REST);
    assert!(schedule.groups.is_empty());
}
