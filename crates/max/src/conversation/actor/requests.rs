//! What tools and programs ask of the conversation: each is refused by
//! the one rule, or done here, and answered where the request says.

use color_eyre::eyre::Result;

use super::{Conversation, Does};
use crate::conversation::Request;

impl Conversation {
    pub(super) async fn request(&mut self, request: Request) -> Result<()> {
        if let Some(refused) = self.refuses(does(&request)) {
            request.refuse(refused.into());
            return Ok(());
        }
        match request {
            Request::Configure { changes, reply } => {
                self.configure(&changes, "Max").await?;
                let _ = reply.send(Ok(self.configured()));
            }
            Request::Ask {
                to,
                question,
                reply,
            } => {
                let asked = self.ask(to, &question).await?;
                let _ = reply.send(asked);
            }
            Request::Answer { to, text, reply } => {
                let answered = self.answer_question(to, &text).await?;
                let _ = reply.send(answered);
            }
            Request::Wake { text, reply } => {
                let woke = self.woken(&text).await?;
                let _ = reply.send(Ok(woke));
            }
            Request::Act { reply } => {
                let _ = reply.send(Ok(()));
            }
        }
        Ok(())
    }
}

/// What a request would have the conversation do.
fn does(request: &Request) -> Does {
    match request {
        Request::Ask { .. } | Request::Wake { .. } => Does::STARTS,
        Request::Answer { .. } | Request::Act { .. } => Does::ACTS,
        Request::Configure { .. } => Does::LOOKS,
    }
}
