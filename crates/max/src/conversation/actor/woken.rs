//! Wakes from the group's own VM: `max-wake` from a program Max keeps
//! there, and what the VM service says about the VM. See "常驻程序" in
//! docs/rust-rewrite.md.

use max_core::item::Item;
use tokio::sync::oneshot;

use super::jobs::fitted;
use super::*;
use max_core::limits::HOUR;

/// When the group's programs woke Max, in the last hour. Not a cap: Max
/// is shown the count with each wake, so a program that wakes it too
/// often shows even in a turn that didn't see the other wakes, which
/// aren't rows of the timeline.
#[derive(Default)]
pub(super) struct Woken(VecDeque<Instant>);

impl Woken {
    /// Counts a wake at `now`: the hour's, this one too.
    fn count(&mut self, now: Instant) -> usize {
        while self.0.front().is_some_and(|&at| at + HOUR <= now) {
            self.0.pop_front();
        }
        self.0.push_back(now);
        self.0.len()
    }

    /// For `/status`: the wakes in the last hour.
    pub(super) fn summary(&self, now: Instant) -> Option<String> {
        let recent = self.0.iter().filter(|&&at| at + HOUR > now).count();
        (recent > 0).then(|| format!("{recent} this hour"))
    }
}

/// What the model is shown: the text, after the hour's count once there
/// has been more than one.
fn shown(text: &str, count: usize, single: u32) -> Item {
    let text = match count {
        0 | 1 => format!("[max-wake] {}", text.trim()),
        _ => format!("[max-wake] （这一小时第 {count} 次）{}", text.trim()),
    };
    let text = fitted(&text, single);
    let tokens = tokens::count(&text);
    Item::new(ItemKind::user(text), tokens)
}

impl Conversation {
    /// `max-wake` from a program in the group's VM.
    pub(super) async fn woken(
        &mut self,
        text: String,
        reply: oneshot::Sender<Result<String, String>>,
    ) -> Result<()> {
        if self.stopping.is_some() {
            let _ = reply.send(Err("Max 正在重启，没叫醒".to_owned()));
            return Ok(());
        }
        let count = self.woken.count(Instant::now());
        let _ = reply.send(Ok("叫醒了 Max".to_owned()));
        info!(conversation = %self.place.conversation, count, "a program wakes Max");
        let item = shown(&text, count, self.single());
        self.wake_with(Reason::Program, item).await
    }

    /// The VM service on the group's VM.
    pub(super) async fn vm_notice(&mut self, text: String) -> Result<()> {
        if self.stopping.is_some() {
            return Ok(());
        }
        let text = format!("[VM] {text}");
        let tokens = tokens::count(&text);
        let item = Item::new(ItemKind::user(text), tokens);
        self.wake_with(Reason::Program, item).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(item: &Item) -> &str {
        let ItemKind::User { text, .. } = &item.kind else {
            panic!("{item:?}")
        };
        text
    }

    #[test]
    fn a_wake_says_how_many_the_hour_has_had() {
        let start = Instant::now();
        let at = |minutes: u64| start + Duration::from_secs(minutes * 60);
        let mut woken = Woken::default();
        for (minute, count) in (0..10).zip(1..) {
            assert_eq!(woken.count(at(minute)), count);
        }
        assert_eq!(woken.summary(at(30)).as_deref(), Some("10 this hour"));
        // The first went out of the hour.
        assert_eq!(woken.count(at(60)), 10);
        assert_eq!(woken.summary(at(200)), None);
    }

    #[test]
    fn the_first_is_shown_as_it_is_and_the_rest_counted() {
        assert_eq!(
            text(&shown("CI 挂了 2 个\n", 1, 25_000)),
            "[max-wake] CI 挂了 2 个"
        );
        assert_eq!(
            text(&shown("又挂了", 37, 25_000)),
            "[max-wake] （这一小时第 37 次）又挂了"
        );
    }
}
