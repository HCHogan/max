//! What tools and programs ask of the conversation: each is done here,
//! or refused, and answered where the request says.

use super::*;
use crate::conversation::Request;

impl Conversation {
    pub(super) async fn request(&mut self, request: Request, origin: Option<TurnId>) -> Result<()> {
        let ended = self.ended(origin);
        match request {
            Request::Agent {
                task,
                title,
                workdir,
                reply,
            } => {
                let refused = ended.or_else(|| self.stopped());
                let started = match refused {
                    Some(refused) => Err(refused),
                    None => self.start_job(task, title, workdir),
                };
                let _ = reply.send(started);
            }
            Request::Shell { shell, reply } => {
                let refused = ended.or_else(|| self.stopped());
                let started = match refused {
                    Some(refused) => Err(refused),
                    None => self.start_command(shell),
                };
                let _ = reply.send(started);
            }
            Request::Adopt { moved, reply } => {
                let adopted = match ended {
                    Some(refused) => Err((refused, moved)),
                    None => self.adopt(moved),
                };
                let _ = reply.send(adopted);
            }
            Request::Steer {
                job,
                message,
                reply,
            } => {
                let steered = ended.map_or_else(|| self.steer_job(job, message), Err);
                let _ = reply.send(steered);
            }
            Request::Cancel { job, reply } => {
                let cancelled = ended.map_or_else(|| self.cancel_job(job), Err);
                let _ = reply.send(cancelled);
            }
            Request::Status { job, reply } => {
                let running = ended.map_or_else(|| self.jobs_running(job), Err);
                let _ = reply.send(running);
            }
            Request::Configure { changes, reply } => {
                let configured = match ended {
                    Some(refused) => Err(refused),
                    None => {
                        self.configure(&changes, "Max").await?;
                        Ok(self.configured())
                    }
                };
                let _ = reply.send(configured);
            }
            Request::Ask {
                to,
                question,
                reply,
            } => {
                let asked = self.ask(to, &question, origin).await?;
                let _ = reply.send(asked);
            }
            Request::Answer { to, text, reply } => {
                let _ = reply.send(self.answer_question(to, &text, origin));
            }
            Request::Wake { text, reply } => self.woken(text, reply).await?,
        }
        Ok(())
    }
}
