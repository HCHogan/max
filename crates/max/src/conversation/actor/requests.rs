//! What tools and programs ask of the conversation: each is refused by
//! the one rule, or done here, and answered where the request says.

use super::*;
use crate::conversation::Request;

impl Conversation {
    pub(super) async fn request(&mut self, request: Request, origin: Option<TurnId>) -> Result<()> {
        if let Some(refused) = self.refuses(origin, does(&request)) {
            request.refuse(refused.why());
            return Ok(());
        }
        match request {
            Request::Agent {
                task,
                title,
                workdir,
                reply,
            } => {
                let _ = reply.send(self.start_job(task, title, workdir));
            }
            Request::Steer {
                agent,
                message,
                reply,
            } => {
                let _ = reply.send(self.steer_job(agent, message));
            }
            Request::Cancel { handle, reply } => {
                let _ = reply.send(self.cancel_job(handle));
            }
            Request::Status { handle, reply } => {
                let _ = reply.send(self.jobs_running(handle));
            }
            Request::Configure { changes, reply } => {
                self.configure(&changes, "Max").await?;
                let _ = reply.send(Ok(self.configured()));
            }
            Request::Ask {
                to,
                question,
                by,
                reply,
            } => {
                let asked = self.ask(to, &question, by).await?;
                let _ = reply.send(asked);
            }
            Request::Answer {
                to,
                text,
                by,
                reply,
            } => {
                let _ = reply.send(self.answer_question(to, &text, by));
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
        Request::Agent { .. } | Request::Ask { .. } | Request::Wake { .. } => Does::STARTS,
        Request::Answer { .. } | Request::Act { .. } => Does::ACTS,
        Request::Steer { .. }
        | Request::Cancel { .. }
        | Request::Status { .. }
        | Request::Configure { .. } => Does::LOOKS,
    }
}
