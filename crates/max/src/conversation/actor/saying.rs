//! What Max's account says in the chat: rows the actor commits and hands
//! to the sender, for a turn, a command's answer or a tool.

use std::sync::Arc;

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_core::ids::{MessageId, TurnId};
use max_core::message::{Draft, Message};
use tracing::warn;

use super::{Conversation, Does, Outgoing};
use crate::conversation::ingest::{self, By};
use crate::conversation::{Act, Post, Receipt, Refused};

impl Conversation {
    /// What a tool says or does, called from the VM: by a turn's program,
    /// whose result tells the core what it did, or by any other there.
    pub(super) async fn post(&mut self, post: Post) -> Result<()> {
        let Post { act, receipt } = post;
        if let Some(refused) = self.refuses(Does::ACTS) {
            if let Some(receipt) = receipt {
                let _ = receipt.send(Err(refused.into()));
            }
            return Ok(());
        }
        match act {
            Act::Say(draft) => {
                self.say(draft, None, None, By::Program, receipt).await?;
            }
            Act::Queue(draft) => {
                let said = self.say(draft, None, None, By::Program, None).await?;
                if let Some(receipt) = receipt {
                    let row = said.map(|(id, _)| id);
                    let _ = receipt.send(row.ok_or(Refused::NothingToSay));
                }
            }
            Act::Unsend(target) => {
                self.unsend(target, receipt).await?;
            }
        }
        Ok(())
    }

    /// Commits what Max's account says, `by` whom, and hands it to the
    /// sender; the row and when it was committed, if it was. The running core isn't fed it: its own words are in its
    /// transcript, and words from outside it, such as a command's answer,
    /// are in the next core's tail.
    pub(super) async fn say(
        &mut self,
        draft: Draft,
        turn: Option<TurnId>,
        segment: Option<i32>,
        by: By,
        receipt: Option<Receipt>,
    ) -> Result<Option<(MessageId, DateTime<Utc>)>> {
        let mut conn = self.shared.services.pool.acquire().await?;
        let said = ingest::said(
            &mut conn,
            &self.place,
            draft,
            turn,
            segment,
            by,
            Utc::now(),
            self.shared.services.offset,
        )
        .await?;
        drop(conn);
        Ok(self.hand_over(said, receipt, Refused::NothingToSay))
    }

    /// Takes back `target`, as `say` says something.
    pub(super) async fn unsend(
        &mut self,
        target: MessageId,
        receipt: Option<Receipt>,
    ) -> Result<Option<(MessageId, DateTime<Utc>)>> {
        let mut conn = self.shared.services.pool.acquire().await?;
        let unsend = ingest::unsend(
            &mut conn,
            &self.place,
            target,
            None,
            Utc::now(),
            self.shared.services.offset,
        )
        .await?;
        drop(conn);
        Ok(self.hand_over(unsend, receipt, Refused::NoSuchMessage))
    }

    /// A row of Max's that was committed, for the sender: the row and
    /// when it was committed; if none was, the receipt hears `why` at once.
    pub(super) fn hand_over(
        &mut self,
        committed: Option<Message>,
        receipt: Option<Receipt>,
        why: Refused,
    ) -> Option<(MessageId, DateTime<Utc>)> {
        let Some(message) = committed else {
            if let Some(receipt) = receipt {
                let _ = receipt.send(Err(why));
            }
            return None;
        };
        let (id, at) = (message.id, message.at);
        let message = Arc::new(message);
        self.committed(&message);
        let outgoing = Outgoing {
            place: Arc::clone(&self.place),
            message,
            receipt,
        };
        if self.shared.outbound.send(outgoing).is_err() {
            warn!(message = %id, "the sender is gone");
        }
        Some((id, at))
    }
}
