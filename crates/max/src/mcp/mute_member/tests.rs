use std::sync::{Arc, Mutex};

use max_db::platform::ConversationKind;
use qqbot::api::Muted;
use sqlx::PgPool;

use super::*;
use crate::conversation::Place;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaohong, from_xiaoming, group, offset, text};
use crate::mcp::{Caller, Services};
use crate::qq::admin::Admin;
use crate::qq::send::Answer;

/// QQ as a group admin sees it: who is muted, each change asked for, and
/// a refusal to give once.
#[derive(Default)]
struct Group {
    muted: Mutex<Vec<Muted>>,
    asked: Mutex<Vec<(String, MuteOp, String, String)>>,
    refusal: Mutex<Option<api::Error>>,
}

impl Admin for Group {
    fn muted<'a>(&'a self, _: &'a str) -> Answer<'a, Vec<Muted>> {
        Box::pin(async move { Ok(self.muted.lock().unwrap().clone()) })
    }

    fn mute<'a>(&'a self, group: &'a str, mute: &'a Mute<'a>) -> Answer<'a, ()> {
        Box::pin(async move {
            if let Some(refusal) = self.refusal.lock().unwrap().take() {
                return Err(refusal);
            }
            let openid = mute.member_openid.to_owned();
            let until = mute.mute_expire_at.clone();
            self.asked
                .lock()
                .unwrap()
                .push((group.into(), mute.op, openid.clone(), until.clone()));
            let mut muted = self.muted.lock().unwrap();
            muted.retain(|muted| muted.member_openid != openid);
            if mute.op != MuteOp::Del {
                muted.push(Muted {
                    member_openid: openid,
                    mute_expire_at: until,
                });
            }
            Ok(())
        })
    }
}

fn refused(code: i64) -> api::Error {
    api::Error::Api {
        path: "/v2/groups/GROUP1/restrict_chat_setting".into(),
        status: 400,
        code,
        message: "机器人不是群管理员".into(),
        trace: String::new(),
    }
}

/// What a call is told when it is refused.
async fn code(context: &Context, member: PrincipalId, seconds: i64) -> &'static str {
    let args = json!({ "member": member.0, "seconds": seconds });
    run(context, args).await.unwrap_err().code
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_normal_member_is_muted_and_let_speak(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    for inbound in [
        from_xiaoming(0, vec![text("加群领红包")]),
        from_xiaohong(1, vec![text("别发了")]),
    ] {
        let committed = ingest::inbound(&mut conn, &place, &inbound, Utc::now(), offset());
        committed.await.unwrap();
    }
    let person = |native: &'static str, name: &'static str| {
        let pool = pool.clone();
        async move {
            let mut conn = pool.acquire().await.unwrap();
            let account = platform::account(&mut conn, Platform::Qq, native, name).await;
            account.unwrap().principal
        }
    };
    let xiaoming = person("XIAOMING", "小明").await;
    let xiaohong = person("XIAOHONG", "小红").await;
    let stranger = person("STRANGER", "路人").await;
    drop(conn);
    let qq = Arc::new(Group::default());
    let context = Context {
        services: Arc::new(Services {
            admin: Some(Arc::clone(&qq) as Arc<dyn Admin>),
            ..Services::bare(pool.clone())
        }),
        place: Arc::clone(&place),
        page_tokens: 2000,
        work: None,
        caller: Caller::Check,
    };
    let asked = || qq.asked.lock().unwrap().clone();

    // Muted for ten minutes, until a time in QQ's zone; then once more,
    // which moves the end.
    let args = json!({ "member": xiaoming.0, "seconds": 600 });
    let muted = run(&context, args).await.unwrap();
    assert_eq!(muted["member"], xiaoming.0);
    assert!(muted["until"].is_string(), "{muted}");
    let args = json!({ "member": xiaoming.0, "seconds": 60 });
    run(&context, args).await.unwrap();
    let ops: Vec<MuteOp> = asked().iter().map(|(_, op, _, _)| *op).collect();
    assert_eq!(ops, [MuteOp::Add, MuteOp::Update]);
    let (group, _, openid, until) = &asked()[0];
    assert_eq!((group.as_str(), openid.as_str()), ("GROUP1", "XIAOMING"));
    assert!(until.ends_with("+08:00"), "{until}");
    // Lifted.
    let args = json!({ "member": xiaoming.0, "seconds": 0 });
    let lifted = run(&context, args).await.unwrap();
    assert_eq!(lifted, json!({ "member": xiaoming.0, "until": null }));
    let (_, op, _, until) = asked().pop().unwrap();
    assert_eq!((op, until.as_str()), (MuteOp::Del, ""));
    assert!(qq.muted.lock().unwrap().is_empty());

    // QQ's refusal comes back in words.
    *qq.refusal.lock().unwrap() = Some(refused(40011030));
    let args = json!({ "member": xiaoming.0, "seconds": 60 });
    let failure = run(&context, args).await.unwrap_err();
    assert_eq!(failure.code, "not_muted");
    assert!(failure.message.contains("不是群管理员"), "{failure:?}");

    // What QQ would refuse isn't asked.
    let before = asked().len();
    assert_eq!(code(&context, xiaohong, 60).await, "refused");
    assert_eq!(code(&context, place.me.principal, 60).await, "refused");
    assert_eq!(code(&context, stranger, 60).await, "not_found");
    assert_eq!(code(&context, xiaoming, -1).await, "bad_arguments");
    assert_eq!(code(&context, xiaoming, LONGEST + 1).await, "bad_arguments");
    let direct = Context {
        services: Arc::new(Services {
            admin: context.services.admin.clone(),
            ..Services::bare(pool.clone())
        }),
        place: Arc::new(Place {
            conversation: place.conversation,
            kind: ConversationKind::Direct,
            endpoint: place.endpoint,
            platform: Platform::Qq,
            native_id: "c2c:XIAOMING".into(),
            me: place.me,
            my_name: "maxx".into(),
        }),
        page_tokens: 2000,
        work: None,
        caller: Caller::Check,
    };
    assert_eq!(code(&direct, xiaoming, 60).await, "refused");
    let elsewhere = Context {
        services: Arc::new(Services {
            admin: None,
            ..(*context.services).clone()
        }),
        ..context
    };
    assert_eq!(code(&elsewhere, xiaoming, 60).await, "unavailable");
    assert_eq!(asked().len(), before);
}
