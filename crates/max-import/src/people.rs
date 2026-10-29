//! People: every old principal with a QQ account, under its old id, with
//! that account as a `qq_legacy` identity under its old id. Max is one of
//! them. At the end the bot's account joins Max, and the owner's new
//! account joins their old one.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Utc};
use color_eyre::eyre::{Result, bail, eyre};
use max_core::ids::{IdentityId, PrincipalId};
use max_db::PgConnection;
use tracing::{info, warn};

use crate::Accounts;

pub struct People {
    /// Max's old principal and its QQ identity.
    pub max: (i64, i64),
    /// Each person's one QQ identity, by principal.
    pub identity: HashMap<i64, i64>,
    /// The other way round, as rendering wants it.
    pub principal: BTreeMap<IdentityId, PrincipalId>,
    /// A name from the old tables, where they have one.
    pub name: HashMap<i64, String>,
}

type Row = (
    i64,
    i64,
    String,
    Option<String>,
    DateTime<Utc>,
    DateTime<Utc>,
);

pub async fn import(old: &mut PgConnection, new: &mut PgConnection) -> Result<People> {
    let max: Vec<(i64, i64)> = sqlx::query_as(
        "select pi.principal_id, pi.principal_identity_id
         from principal_identities pi join platform_accounts pa using (platform_account_id)
         where pa.platform = 'qq' and pi.native_user_id = pa.native_account_id",
    )
    .fetch_all(&mut *old)
    .await?;
    let [max] = max[..] else {
        bail!("{} QQ identities of Max's own", max.len());
    };
    let rows: Vec<Row> = sqlx::query_as(
        "select p.principal_id, pi.principal_identity_id, pi.native_user_id,
                coalesce(nullif(btrim(p.display_name), ''), nullif(btrim(pi.display_name), '')),
                p.created_at, pi.created_at
         from principals p
         join principal_identities pi using (principal_id)
         join platform_accounts pa using (platform_account_id)
         where pa.platform = 'qq'
         order by p.principal_id",
    )
    .fetch_all(&mut *old)
    .await?;

    let mut people = People {
        max,
        identity: HashMap::new(),
        principal: BTreeMap::new(),
        name: HashMap::new(),
    };
    for (principal, identity, _, name, _, _) in &rows {
        if people.identity.insert(*principal, *identity).is_some() {
            bail!("principal {principal} has two QQ identities");
        }
        people
            .principal
            .insert(IdentityId(*identity), PrincipalId(*principal));
        if let Some(name) = name {
            people.name.insert(*principal, name.clone());
        }
    }
    people.name.insert(max.0, "maxx".to_owned());

    // The nameless get one once their messages are in; see `name`.
    let names: Vec<String> = rows
        .iter()
        .map(|row| people.name.get(&row.0).cloned().unwrap_or_default())
        .collect();
    sqlx::query(
        "insert into principals (id, display_name, created_at)
         select * from unnest($1::bigint[], $2::text[], $3::timestamptz[])",
    )
    .bind(rows.iter().map(|row| row.0).collect::<Vec<_>>())
    .bind(names)
    .bind(rows.iter().map(|row| row.4).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    sqlx::query(
        "insert into identities (id, principal_id, platform, native_user_id, created_at)
         select id, principal_id, 'qq_legacy', native_user_id, created_at
         from unnest($1::bigint[], $2::bigint[], $3::text[], $4::timestamptz[])
             as t (id, principal_id, native_user_id, created_at)",
    )
    .bind(rows.iter().map(|row| row.1).collect::<Vec<_>>())
    .bind(rows.iter().map(|row| row.0).collect::<Vec<_>>())
    .bind(rows.iter().map(|row| row.2.clone()).collect::<Vec<_>>())
    .bind(rows.iter().map(|row| row.5).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    info!(people = rows.len(), "people");
    Ok(people)
}

/// Those with no name in the old tables are called what they last said
/// something as, or 某人.
pub async fn name(new: &mut PgConnection) -> Result<()> {
    sqlx::query(
        "update principals p set display_name = coalesce(
             (select m.sender_name from messages m join identities i on i.id = m.sender_identity_id
              where i.principal_id = p.id order by m.id desc limit 1),
             '某人')
         where p.display_name = ''",
    )
    .execute(new)
    .await?;
    Ok(())
}

/// The bot's account is Max's; the owner's openid joins their old QQ
/// number, and their old private chat goes on in the new one.
pub async fn accounts(new: &mut PgConnection, people: &People, accounts: &Accounts) -> Result<()> {
    let bot: i64 = sqlx::query_scalar(
        "insert into identities (principal_id, platform, native_user_id)
         values ($1, 'qq', $2) returning id",
    )
    .bind(people.max.0)
    .bind(&accounts.bot_openid)
    .fetch_one(&mut *new)
    .await?;
    let owner: i64 = sqlx::query_scalar(
        "select principal_id from identities where platform = 'qq_legacy' and native_user_id = $1",
    )
    .bind(&accounts.owner_qq)
    .fetch_optional(&mut *new)
    .await?
    .ok_or_else(|| eyre!("the owner's QQ number isn't in the old records"))?;
    sqlx::query(
        "insert into identities (principal_id, platform, native_user_id) values ($1, 'qq', $2)",
    )
    .bind(owner)
    .bind(&accounts.owner_openid)
    .execute(&mut *new)
    .await?;
    let chat: Option<i64> = sqlx::query_scalar(
        "select conversation_id from endpoints where platform = 'qq_legacy' and native_id = $1",
    )
    .bind(format!("private:{}", accounts.owner_qq))
    .fetch_optional(&mut *new)
    .await?;
    match chat {
        Some(chat) => {
            sqlx::query(
                "insert into endpoints (conversation_id, platform, native_id, self_identity_id)
                 values ($1, 'qq', $2, $3)",
            )
            .bind(chat)
            .bind(format!("c2c:{}", accounts.owner_openid))
            .bind(bot)
            .execute(&mut *new)
            .await?;
        }
        None => warn!("the owner had no private chat with Max"),
    }
    Ok(())
}
