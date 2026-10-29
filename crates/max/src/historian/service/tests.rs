use max_core::ids::{EndpointId, IdentityId, MessageId, PrincipalId};
use max_core::message::{Content, Message, Platform, Sender};
use max_db::PgPool;
use max_db::platform::Account;

use super::*;
use crate::conversation::testing::offset;
use crate::llm::testing::{Script, models};

fn place(kind: ConversationKind) -> Arc<Place> {
    Arc::new(Place {
        conversation: ConversationId(1),
        kind,
        endpoint: EndpointId(1),
        platform: Platform::Qq,
        native_id: "group:GROUP1".into(),
        me: Account {
            identity: IdentityId(1),
            principal: PrincipalId(1),
        },
        my_name: "maxx".into(),
    })
}

fn row(kind: ConversationKind) -> Notice {
    Notice::Row(Row {
        place: place(kind),
        message: Arc::new(Message {
            id: MessageId(1),
            conversation: ConversationId(1),
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

fn units(notice: Notice, service: &Service) -> Vec<(Reason, Wait)> {
    let units = service.on_input(notice);
    units
        .into_iter()
        .map(|(c, wait)| (c.reason, wait))
        .collect()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_group_row_calls_for_a_check_and_a_quiet_summary_and_compact_goes_first(pool: PgPool) {
    let models = Arc::new(models(&Arc::new(Script::default())));
    let historian = Historian {
        pool,
        chosen: models.historian().unwrap().unwrap(),
        models,
        offset: offset(),
    };
    let service = Service {
        historian,
        waiting: Mutex::default(),
    };
    assert_eq!(
        units(row(ConversationKind::Group), &service),
        [
            (Reason::Pressure, Wait::Throttle(CHECK)),
            (Reason::Quiet, Wait::Debounce(QUIET))
        ]
    );
    assert_eq!(units(row(ConversationKind::Direct), &service), []);
    let (reply, _answer) = oneshot::channel();
    let compact = Notice::Compact(Compact {
        place: place(ConversationKind::Group),
        reply,
    });
    assert_eq!(units(compact, &service), [(Reason::Compact, Wait::Urgent)]);
    assert_eq!(service.waiting.lock().unwrap()[&ConversationId(1)].len(), 1);
}
