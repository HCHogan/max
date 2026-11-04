//! Calls from the programs Max keeps in the group's VM, outside any turn:
//! the tools marked `program`, run beside the core, and what they say
//! capped by the hour. See "常驻程序" in docs/rust-rewrite.md.

use serde_json::Value;
use tokio::sync::oneshot;

use super::*;

/// The group's programs say at most this many messages in an hour.
pub(super) const SAID_PER_HOUR: usize = 200;
const HOUR: Duration = Duration::from_secs(3600);

/// When the group's programs said something, in the last hour.
#[derive(Default)]
pub(super) struct Said(VecDeque<Instant>);

impl Said {
    /// Counts one more message at `now`, if the hour has room for it.
    pub(super) fn take(&mut self, now: Instant) -> bool {
        while self
            .0
            .front()
            .is_some_and(|&at| now.duration_since(at) >= HOUR)
        {
            self.0.pop_front();
        }
        if self.0.len() >= SAID_PER_HOUR {
            return false;
        }
        self.0.push_back(now);
        true
    }
}

impl Conversation {
    /// A program's call of `tool`; the result goes to `reply`.
    pub(super) fn program_call(
        &mut self,
        tool: String,
        args: Value,
        reply: oneshot::Sender<Result<Value, mcp::Failure>>,
    ) {
        if self.stopping.is_some() {
            let _ = reply.send(Err(mcp::Failure::new("closed", "Max 正在重启，没做")));
            return;
        }
        let work = self
            .shared
            .vm_dir
            .as_deref()
            .map(|dir| vm::work(dir, self.place.conversation));
        let context = mcp::Context {
            services: Arc::clone(&self.shared.services),
            place: Arc::clone(&self.place),
            page_tokens: self.single(),
            video: false,
            work,
            caller: mcp::Caller::Program(Poster::program(self.mailbox.clone())),
        };
        self.side.spawn(move |_| async move {
            let _ = reply.send(mcp::program_call(&tool, &context, args).await);
        });
    }

    /// Whether a program may say one more message now; why not, if not.
    pub(super) fn program_says(&mut self) -> Option<String> {
        if self.program_said.take(Instant::now()) {
            return None;
        }
        Some(format!("这一小时程序已经发了 {SAID_PER_HOUR} 条，没发"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn so_many_an_hour() {
        let start = Instant::now();
        let mut said = Said::default();
        for second in 0..SAID_PER_HOUR as u64 {
            assert!(said.take(start + Duration::from_secs(second)));
        }
        assert!(!said.take(start + Duration::from_secs(60)));
        assert!(said.take(start + HOUR));
        assert!(!said.take(start + HOUR));
        assert!(said.take(start + HOUR + Duration::from_secs(1)));
    }
}
