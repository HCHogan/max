use sqlx::PgPool;

use super::*;

#[sqlx::test]
async fn an_account_is_created_once(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let first = account(&mut conn, Platform::Qq, "10001", "小明").await?;
    let again = account(&mut conn, Platform::Qq, "10001", "小明改了名").await?;
    assert_eq!(first, again);
    let elsewhere = account(&mut conn, Platform::QqLegacy, "10001", "小明").await?;
    assert_ne!(first.principal, elsewhere.principal);
    let name = sqlx::query_scalar!(
        "select display_name from principals where id = $1",
        first.principal.0
    )
    .fetch_one(&mut *conn)
    .await?;
    assert_eq!(name, "小明");
    Ok(())
}

#[sqlx::test]
async fn two_conversations_meeting_a_newcomer_make_one_person(pool: PgPool) -> sqlx::Result<()> {
    let mut a = pool.begin().await?;
    let mut b = pool.begin().await?;
    let first = account(&mut a, Platform::Qq, "10002", "小红").await?;
    // b waits on a's lock until a commits, then finds a's row.
    let (second, committed) =
        tokio::join!(account(&mut b, Platform::Qq, "10002", "小红"), a.commit());
    committed?;
    assert_eq!(second?, first);
    b.commit().await?;
    let people = sqlx::query_scalar!(r#"select count(*) as "n!" from principals"#)
        .fetch_one(&pool)
        .await?;
    assert_eq!(people, 1);
    Ok(())
}

#[sqlx::test]
async fn a_merged_person_reads_as_the_one_kept(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let kept = account(&mut conn, Platform::Qq, "10003", "小刚").await?;
    let merged = account(&mut conn, Platform::QqLegacy, "20003", "小刚").await?;
    sqlx::query!(
        "update principals set merged_into = $1 where id = $2",
        kept.principal.0,
        merged.principal.0
    )
    .execute(&mut *conn)
    .await?;
    let again = account(&mut conn, Platform::QqLegacy, "20003", "小刚").await?;
    assert_eq!(again.principal, kept.principal);
    let people = principals(&mut conn, &[kept.identity, merged.identity]).await?;
    assert_eq!(
        people,
        [
            (kept.identity, kept.principal),
            (merged.identity, kept.principal)
        ]
        .into()
    );
    Ok(())
}

#[sqlx::test]
async fn an_endpoint_brings_its_conversation(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let me = account(&mut conn, Platform::Qq, "20000", "Max")
        .await?
        .identity;
    let group = ConversationKind::Group;
    let first = endpoint(
        &mut conn,
        Platform::Qq,
        "group:30001",
        me,
        group,
        Some("测试群"),
    )
    .await?;
    let again = endpoint(&mut conn, Platform::Qq, "group:30001", me, group, None).await?;
    assert_eq!(first, again);
    let direct = ConversationKind::Direct;
    let other = endpoint(&mut conn, Platform::Qq, "private:10001", me, direct, None).await?;
    assert_ne!(first.conversation, other.conversation);
    Ok(())
}

#[sqlx::test]
async fn the_roster_falls_back_to_the_first_name_seen(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let me = account(&mut conn, Platform::Qq, "20000", "Max")
        .await?
        .identity;
    let group = ConversationKind::Group;
    let endpoint = endpoint(&mut conn, Platform::Qq, "group:30001", me, group, None).await?;
    let xiaoming = account(&mut conn, Platform::Qq, "10001", "小明").await?;
    let known = roster(
        &mut conn,
        endpoint.id,
        &[xiaoming.principal, PrincipalId(999)],
    )
    .await?;
    assert_eq!(
        known,
        [Known {
            principal: xiaoming.principal,
            name: "小明".into(),
            role: None,
        }]
    );
    Ok(())
}

#[sqlx::test]
async fn settings_default_until_saved(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let me = account(&mut conn, Platform::Qq, "20000", "Max")
        .await?
        .identity;
    let group = ConversationKind::Group;
    let conversation = endpoint(&mut conn, Platform::Qq, "group:30001", me, group, None)
        .await?
        .conversation;
    assert_eq!(
        settings(&mut conn, conversation).await?,
        Settings::default()
    );
    let changed = Settings {
        model: Some("fast".into()),
        proactive: false,
        ..Settings::default()
    };
    let at = DateTime::from_timestamp(1_800_000_000, 0).unwrap_or_default();
    save_settings(&mut conn, conversation, &changed, at).await?;
    assert_eq!(settings(&mut conn, conversation).await?, changed);
    Ok(())
}

#[sqlx::test]
async fn a_gateway_session_is_kept_per_platform(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    assert_eq!(gateway_session(&mut conn, Platform::Qq).await?, None);
    let at = chrono::DateTime::from_timestamp(1_800_000_000, 0).unwrap_or_default();
    save_gateway_session(&mut conn, Platform::Qq, "S1", 41, at).await?;
    save_gateway_session(&mut conn, Platform::Qq, "S2", 7, at).await?;
    assert_eq!(
        gateway_session(&mut conn, Platform::Qq).await?,
        Some(("S2".to_owned(), 7))
    );
    Ok(())
}

#[sqlx::test]
async fn binding_a_group_to_an_old_conversation(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let old_max = account(&mut conn, Platform::QqLegacy, "20000", "Max").await?;
    let group = ConversationKind::Group;
    let old = endpoint(
        &mut conn,
        Platform::QqLegacy,
        "group:30001",
        old_max.identity,
        group,
        None,
    )
    .await?;
    let found = conversation_of(&mut conn, Platform::QqLegacy, "group:30001").await?;
    assert_eq!(found, Some(old.conversation));
    assert_eq!(
        conversation_of(&mut conn, Platform::QqLegacy, "group:1").await?,
        None
    );

    let max = account(&mut conn, Platform::Qq, "BOT", "maxx").await?;
    let native = "group:GROUPOPENID";
    assert_eq!(
        find_endpoint(&mut conn, Platform::Qq, native, max.identity).await?,
        None
    );
    let bound = endpoint_on(&mut conn, old.conversation, Platform::Qq).await?;
    assert_eq!(bound, None);
    let new = attach(&mut conn, found, Platform::Qq, native, max.identity, group).await?;
    assert_eq!(new.conversation, old.conversation);
    let bound = endpoint_on(&mut conn, old.conversation, Platform::Qq).await?;
    assert_eq!(bound.as_deref(), Some(native));
    assert_eq!(
        find_endpoint(&mut conn, Platform::Qq, native, max.identity).await?,
        Some(new)
    );
    let direct = ConversationKind::Direct;
    let fresh = attach(
        &mut conn,
        None,
        Platform::Qq,
        "c2c:USER",
        max.identity,
        direct,
    )
    .await?;
    assert_ne!(fresh.conversation, old.conversation);
    assert_eq!(
        conversation_kind(&mut conn, fresh.conversation).await?,
        direct
    );
    assert_eq!(conversation_kind(&mut conn, new.conversation).await?, group);
    Ok(())
}

#[sqlx::test]
async fn a_merged_account_speaks_for_its_owner(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let owner = account(&mut conn, Platform::Qq, "USER_OPENID", "hank").await?;
    let member = account(&mut conn, Platform::Qq, "MEMBER_OPENID", "hank").await?;
    merge(&mut conn, member.principal, owner.principal).await?;
    merge(&mut conn, owner.principal, owner.principal).await?;
    let again = account(&mut conn, Platform::Qq, "MEMBER_OPENID", "hank").await?;
    assert_eq!(again.principal, owner.principal);
    assert_eq!(again.identity, member.identity);
    let native = native_user_id(&mut conn, member.identity).await?;
    assert_eq!(native.as_deref(), Some("MEMBER_OPENID"));
    Ok(())
}
