//! The linker: links each QQ account that speaks in a group going on from
//! an old one to the old QQ number whose avatar it shows, when that is
//! clear. What isn't is logged and recorded, and the owner fixes it in the
//! database: nobody asks for a link, so nobody can ask for one to someone
//! else. See "按头像接上" in docs/rust-rewrite.md.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use color_eyre::eyre::Result;
use max_core::ids::{ConversationId, IdentityId, PrincipalId};
use max_core::message::Platform;
use max_db::PgPool;
use max_db::links::{self, Account, Number, Outcome};
use max_db::platform::ConversationKind;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use super::avatar::{self, Avatars};
use crate::worker::Row;

/// How old an old number's stored avatar may get before it is fetched
/// again.
const STALE: TimeDelta = TimeDelta::days(7);
/// How long an account whose avatar couldn't be fetched waits before it
/// is tried again, when it speaks.
const RETRY: Duration = Duration::from_secs(600);

pub struct Linker {
    pub pool: PgPool,
    pub avatars: Arc<Avatars>,
    /// The owners and Max: no account is linked to them, and theirs aren't
    /// checked.
    pub barred: BTreeSet<PrincipalId>,
}

impl Linker {
    /// Until `stop`: first the accounts each such group has left to check,
    /// then each account when it first speaks.
    pub async fn run(self, mut rows: UnboundedReceiver<Row>, stop: CancellationToken) {
        tokio::select! {
            () = stop.cancelled() => return,
            () = self.sweep_all() => {}
        }
        let mut done: HashSet<IdentityId> = match self.checked().await {
            Ok(checked) => checked,
            Err(error) => {
                warn!("the linker couldn't read what it checked: {error:#}");
                return;
            }
        };
        let mut tried: HashMap<IdentityId, Instant> = HashMap::new();
        loop {
            let row = tokio::select! {
                () = stop.cancelled() => break,
                row = rows.recv() => match row {
                    Some(row) => row,
                    None => break,
                },
            };
            let place = &row.place;
            let sender = row.message.sender.identity;
            if place.platform != Platform::Qq
                || place.kind != ConversationKind::Group
                || done.contains(&sender)
                || tried.get(&sender).is_some_and(|at| at.elapsed() < RETRY)
            {
                continue;
            }
            tried.insert(sender, Instant::now());
            match self.sweep(place.conversation).await {
                Ok(failed) if !failed.contains(&sender) => {
                    done.insert(sender);
                }
                Ok(_) => {}
                Err(error) => {
                    warn!(conversation = %place.conversation, "linking failed: {error:#}")
                }
            }
        }
    }

    async fn sweep_all(&self) {
        let conversations = async {
            let mut conn = self.pool.acquire().await?;
            Ok::<_, color_eyre::Report>(links::conversations(&mut conn).await?)
        };
        let conversations = match conversations.await {
            Ok(conversations) => conversations,
            Err(error) => {
                warn!("the linker couldn't find the groups: {error:#}");
                return;
            }
        };
        for conversation in conversations {
            if let Err(error) = self.sweep(conversation).await {
                warn!(%conversation, "linking failed: {error:#}");
            }
        }
    }

    async fn checked(&self) -> Result<HashSet<IdentityId>> {
        let mut conn = self.pool.acquire().await?;
        Ok(links::checked(&mut conn).await?.into_iter().collect())
    }

    /// Checks the accounts `conversation` has left to check, if it goes on
    /// from an old group: each is linked or recorded as not. Returns those
    /// whose avatar couldn't be fetched, which are left to another try.
    async fn sweep(&self, conversation: ConversationId) -> Result<HashSet<IdentityId>> {
        let mut conn = self.pool.acquire().await?;
        if !links::goes_on(&mut conn, conversation).await? {
            return Ok(HashSet::new());
        }
        let accounts = links::unchecked(&mut conn, conversation).await?;
        let accounts: Vec<Account> = accounts
            .into_iter()
            .filter(|account| !self.barred.contains(&account.principal))
            .collect();
        if accounts.is_empty() {
            return Ok(HashSet::new());
        }
        let numbers = links::numbers(&mut conn, conversation).await?;
        drop(conn);
        let default = self.avatars.default().await?;
        let numbers = self.refresh(numbers).await?;
        let mut failed = HashSet::new();
        let mut seen = Vec::new();
        for account in accounts {
            match self.avatars.of_account(&account.openid).await {
                Ok(print) => seen.push((account, print)),
                Err(error) => {
                    let account = account.identity;
                    warn!(%conversation, %account, "couldn't fetch an account's avatar: {error:#}");
                    failed.insert(account);
                }
            }
        }
        let decided = decide(&seen, &numbers, &default, &self.barred);
        let mut conn = self.pool.acquire().await?;
        for ((account, _), (mut outcome, number)) in seen.iter().zip(decided) {
            if let Some(number) = number
                && outcome == Outcome::Linked
                && links::linked_here(&mut conn, conversation, number.principal, account.identity)
                    .await?
            {
                outcome = Outcome::Taken;
            }
            report(conversation, account, outcome, number);
            let number = number.map(|number| (number.identity, number.principal));
            links::record(&mut conn, account, outcome, number, Utc::now()).await?;
        }
        Ok(failed)
    }

    /// The numbers with prints to compare: stale ones are fetched again,
    /// and one that can't be keeps the print it had, or is left out.
    async fn refresh(&self, numbers: Vec<Number>) -> Result<Vec<Number>> {
        let stale = Utc::now() - STALE;
        let mut fresh = Vec::new();
        for mut number in numbers {
            if number.fetched_at.is_none_or(|at| at < stale) {
                match self.avatars.of_number(&number.number).await {
                    Ok(print) => {
                        let mut conn = self.pool.acquire().await?;
                        links::save_print(&mut conn, number.identity, &print, Utc::now()).await?;
                        number.print = Some(print);
                    }
                    Err(error) => {
                        let number = number.identity;
                        debug!(%number, "couldn't fetch an old number's avatar: {error:#}");
                    }
                }
            }
            if number.print.is_some() {
                fresh.push(number);
            }
        }
        Ok(fresh)
    }
}

/// What comes of each account seen, by its avatar's print: linked to the
/// number it shows, if that one alone does and no other account seen
/// shows it too.
fn decide<'a>(
    seen: &[(Account, Vec<u8>)],
    numbers: &'a [Number],
    default: &[u8],
    barred: &BTreeSet<PrincipalId>,
) -> Vec<(Outcome, Option<&'a Number>)> {
    let shown: Vec<Result<&Number, Outcome>> = seen
        .iter()
        .map(|(_, print)| {
            if avatar::alike(print, default) {
                return Err(Outcome::Default);
            }
            let mut shows = numbers.iter().filter(|number| {
                number
                    .print
                    .as_deref()
                    .is_some_and(|theirs| avatar::alike(print, theirs))
            });
            match (shows.next(), shows.next()) {
                (None, _) => Err(Outcome::None),
                (Some(number), None) => Ok(number),
                (Some(_), Some(_)) => Err(Outcome::Ambiguous),
            }
        })
        .collect();
    let showing = |number: &Number| {
        shown
            .iter()
            .filter(|other| matches!(other, Ok(theirs) if theirs.identity == number.identity))
            .count()
    };
    shown
        .iter()
        .map(|shows| match *shows {
            Err(outcome) => (outcome, None),
            Ok(number) if barred.contains(&number.principal) => (Outcome::Barred, Some(number)),
            Ok(number) if showing(number) > 1 => (Outcome::Taken, Some(number)),
            Ok(number) => (Outcome::Linked, Some(number)),
        })
        .collect()
}

fn report(
    conversation: ConversationId,
    account: &Account,
    outcome: Outcome,
    number: Option<&Number>,
) {
    let (who, name) = (account.identity, &account.name);
    match (outcome, number) {
        (Outcome::Linked, Some(number)) => {
            let (old, old_name) = (number.identity, &number.name);
            info!(%conversation, account = %who, name, number = %old, old_name, "linked by avatar");
        }
        (Outcome::Default | Outcome::None, _) => {
            info!(%conversation, account = %who, name, ?outcome, "not linked");
        }
        (_, number) => {
            let old = number.map(|number| number.identity.to_string());
            warn!(%conversation, account = %who, name, ?outcome, number = ?old, "not linked");
        }
    }
}

#[cfg(test)]
mod tests;
