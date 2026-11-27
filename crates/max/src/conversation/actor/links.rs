//! `/link` and `/unlink`: the edges along which Max in one conversation
//! enters another's VM, made by the people the two belong to: a group's
//! owner, the other person in a private chat, and Max's owners. See
//! "Entering another conversation's VM" in docs/design/vm.md.

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_db::links::{self, Peer};
use max_db::platform::ConversationKind;

use super::Conversation;
use crate::command;

impl Conversation {
    /// `/link` answers with a code, to be said in the conversation whose
    /// VM Max here is to enter; `/link <code>` lets Max where the code
    /// was issued enter the VM here.
    pub(super) async fn link(&mut self, code: Option<&str>) -> Result<String> {
        let here = self.place.conversation;
        let codes = &self.shared.links;
        let now = std::time::Instant::now();
        let Some(code) = code else {
            let code = codes.issue(here, now);
            let how = command::how(ConversationKind::Group, &self.place.my_name, "/link");
            return Ok(format!(
                "code issued: {code} lets Max here enter another conversation's VM, and not the other way\n\
                 send /link {code} there (in a group: {how} {code})\n\
                 valid for 10 minutes, once"
            ));
        };
        // Looked at before it is used: said here by mistake, it still
        // works where it was meant for.
        if codes.peek(code, now) == Some(here) {
            return Ok(
                "error: that code was issued here; send it in the conversation whose VM Max here is to enter"
                    .to_owned(),
            );
        }
        let Some(from) = codes.redeem(code, now) else {
            return Ok("error: no such code, or it has run out".to_owned());
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let made = links::link(&mut conn, from, here, Utc::now()).await?;
        let from = peer(&mut conn, from).await?;
        if !made {
            return Ok(format!("skipped: Max in {from} may enter this VM already"));
        }
        let unlink = format!("/unlink c#{}", from.conversation);
        let how = command::how(self.place.kind, &self.place.my_name, &unlink);
        Ok(format!(
            "linked: Max in {from} may enter this VM now, with all that Max here has, and not the other way\n{how} removes it"
        ))
    }

    /// `/unlink c#N`: neither Max enters the other's VM from now on.
    pub(super) async fn unlink(&mut self, handle: Option<&str>) -> Result<String> {
        let Some(other) = handle.and_then(links::named) else {
            let (kind, me) = (self.place.kind, &self.place.my_name);
            let how = command::how(kind, me, "/unlink c#N");
            let status = command::how(kind, me, "/status");
            return Ok(format!(
                "error: say which conversation, as {how}; {status} lists them"
            ));
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        if links::unlink(&mut conn, self.place.conversation, other).await? == 0 {
            return Ok(format!("skipped: no link with c#{other}"));
        }
        let other = peer(&mut conn, other).await?;
        Ok(format!(
            "unlinked: Max here and Max in {other} can't enter each other's VM any more"
        ))
    }

    /// Whose VMs Max here may enter, and who may enter its own, as
    /// `/status` shows them, which is by number alone: None for nobody.
    pub(super) async fn linked(&self) -> Result<[Option<String>; 2]> {
        let here = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        let enterable = links::enterable(&mut conn, here).await?;
        let enterers = links::enterers(&mut conn, here).await?;
        Ok([enterable, enterers].map(|peers| {
            let number = |peer: &Peer| format!("c#{}", peer.conversation);
            let peers: Vec<String> = peers.iter().map(number).collect();
            (!peers.is_empty()).then(|| peers.join(" · "))
        }))
    }
}

/// `conversation` as another one names it.
pub(super) async fn peer(
    conn: &mut max_db::PgConnection,
    conversation: ConversationId,
) -> Result<Peer> {
    let peer = links::peer(conn, conversation).await?;
    Ok(peer.unwrap_or(Peer {
        conversation,
        title: None,
    }))
}
