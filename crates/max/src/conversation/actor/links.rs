//! `/link` and `/unlink`: the edges along which Max in one conversation
//! asks Max in another, made by Max's owners alone. See "Asking another
//! conversation" in docs/rust-rewrite.md.

use max_core::message::Platform;
use max_db::links::{self, Peer};
use max_db::platform::ConversationKind;

use super::*;

impl Conversation {
    /// `/link` answers with a code, to be said where Max here is to ask;
    /// `/link <code>` lets Max where the code was issued ask Max here.
    pub(super) async fn link(&mut self, code: Option<&str>) -> Result<String> {
        self.learn_title();
        let here = self.place.conversation;
        let codes = &self.shared.links;
        let now = std::time::Instant::now();
        let Some(code) = code else {
            let code = codes.issue(here, now);
            let how = command::how(ConversationKind::Group, &self.place.my_name, "/link");
            return Ok(format!(
                "code issued: {code} lets Max here ask Max in another conversation, and not the other way\n\
                 send /link {code} there (in a group: {how} {code})\n\
                 valid for 10 minutes, once"
            ));
        };
        // Looked at before it is used: said here by mistake, it still
        // works where it was meant for.
        if codes.peek(code, now) == Some(here) {
            return Ok(
                "error: that code was issued here; send it in the conversation Max here is to ask"
                    .to_owned(),
            );
        }
        let Some(asker) = codes.redeem(code, now) else {
            return Ok("error: no such code, or it has run out".to_owned());
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let made = links::link(&mut conn, asker, here, Utc::now()).await?;
        let asker = peer(&mut conn, asker).await?;
        if !made {
            return Ok(format!("skipped: Max in {asker} may ask Max here already"));
        }
        let unlink = format!("/unlink c#{}", asker.conversation);
        let how = command::how(self.place.kind, &self.place.my_name, &unlink);
        Ok(format!(
            "linked: Max in {asker} may ask Max here now, and not the other way\n{how} removes it"
        ))
    }

    /// `/unlink c#N`: neither Max asks the other from now on.
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
            "unlinked: Max here and Max in {other} can't ask each other any more"
        ))
    }

    /// Whom Max here may ask, and who may ask it, as `/status` shows
    /// them: None for nobody.
    pub(super) async fn linked(&self) -> Result<[Option<String>; 2]> {
        let here = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        let asked = links::asked(&mut conn, here).await?;
        let askers = links::askers(&mut conn, here).await?;
        Ok([asked, askers].map(|peers| {
            let peers: Vec<String> = peers.iter().map(Peer::to_string).collect();
            (!peers.is_empty()).then(|| peers.join(" · "))
        }))
    }

    /// Asks QQ what this group is called, and keeps the answer as the
    /// conversation's title, for the conversations that name this one. In
    /// a task of its own: the actor waits only on the database, and no
    /// answer of its own shows the name.
    fn learn_title(&mut self) {
        let (Some(qq), Platform::Qq) = (&self.shared.services.admin, self.place.platform) else {
            return;
        };
        let Some(group) = self.place.native_id.strip_prefix("group:") else {
            return;
        };
        let (qq, group) = (Arc::clone(qq), group.to_owned());
        let pool = self.shared.services.pool.clone();
        let conversation = self.place.conversation;
        self.side.spawn(move |_| async move {
            let learned = async {
                let info = qq.info(&group).await?;
                let mut conn = pool.acquire().await?;
                platform::set_title(&mut conn, conversation, &info.group_name).await?;
                Ok::<_, Report>(())
            };
            if let Err(error) = learned.await {
                warn!(%conversation, %error, "couldn't learn what the group is called");
            }
        });
    }
}

/// `conversation` as another one names it.
async fn peer(conn: &mut max_db::PgConnection, conversation: ConversationId) -> Result<Peer> {
    let peer = links::peer(conn, conversation).await?;
    Ok(peer.unwrap_or(Peer {
        conversation,
        title: None,
    }))
}
