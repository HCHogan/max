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
    let people = principals(&mut conn, &[owner.identity, member.identity]).await?;
    let both = [
        (owner.identity, owner.principal),
        (member.identity, owner.principal),
    ];
    assert_eq!(people, both.into());
    Ok(())
}
