//! Wakes from the group's own VM: `max-wake` from a program Max keeps
//! there, and what the VM service says about the VM. See "常驻程序" in
//! docs/rust-rewrite.md.

use std::mem;

use chrono::TimeDelta;
use max_core::item::Item;
use tokio::sync::oneshot;

use super::jobs::fitted;
use super::*;

/// The group's programs wake Max at most this often in an hour; more are
/// held, and come together once the hour allows.
pub(super) const PER_HOUR: usize = 6;
/// The most texts held; past them, only a count.
const HELD: usize = 20;
const HOUR: Duration = Duration::from_secs(3600);

#[derive(Default)]
pub(super) struct Woken {
    /// When the group's programs woke Max, in the last hour.
    times: VecDeque<Instant>,
    held: Vec<String>,
    /// Held past `HELD`, counted.
    more: usize,
}

/// Texts to wake Max with, the held ones first, and how many more were
/// held than kept.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Batch {
    texts: Vec<String>,
    more: usize,
}

impl Woken {
    /// A program's text: the batch to wake Max with now, or when it is
    /// held until.
    fn arrive(&mut self, text: String, now: Instant) -> Result<Batch, Instant> {
        self.hold(text);
        self.release(now).ok_or_else(|| self.due().unwrap_or(now))
    }

    fn hold(&mut self, text: String) {
        if self.held.len() < HELD {
            self.held.push(text);
        } else {
            self.more += 1;
        }
    }

    /// The held texts, if the hour allows waking Max now.
    pub(super) fn release(&mut self, now: Instant) -> Option<Batch> {
        while self.times.front().is_some_and(|&at| at + HOUR <= now) {
            self.times.pop_front();
        }
        if self.held.is_empty() || self.times.len() >= PER_HOUR {
            return None;
        }
        self.times.push_back(now);
        Some(Batch {
            texts: mem::take(&mut self.held),
            more: mem::take(&mut self.more),
        })
    }

    /// When the held texts may wake Max.
    pub(super) fn due(&self) -> Option<Instant> {
        if self.held.is_empty() {
            return None;
        }
        Some(match self.times.front() {
            Some(&first) if self.times.len() >= PER_HOUR => first + HOUR,
            _ => Instant::now(),
        })
    }

    /// For `/status`: the wakes in the last hour, and the held ones.
    pub(super) fn summary(&self, now: Instant) -> Option<String> {
        let recent = self.times.iter().filter(|&&at| at + HOUR > now).count();
        let held = self.held.len() + self.more;
        match (recent, held) {
            (0, 0) => None,
            (_, 0) => Some(format!("{recent}/{PER_HOUR} this hour")),
            _ => Some(format!("{recent}/{PER_HOUR} this hour, {held} held")),
        }
    }
}

/// What the model is shown: one text as it is, more as a list.
fn shown(batch: &Batch, single: u32) -> Item {
    let text = match &batch.texts[..] {
        [text] if batch.more == 0 => format!("[max-wake] {}", text.trim()),
        texts => {
            let mut text = format!(
                "[max-wake] 这一小时叫醒满了，攒下了 {} 条：",
                texts.len() + batch.more
            );
            for each in texts {
                text.push_str("\n- ");
                text.push_str(each.trim());
            }
            if batch.more > 0 {
                text.push_str(&format!("\n（还有 {} 条没留）", batch.more));
            }
            text
        }
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
        let now = Instant::now();
        match self.woken.arrive(text, now) {
            Ok(batch) => {
                let _ = reply.send(Ok("叫醒了 Max".to_owned()));
                self.wake_programs(batch).await
            }
            Err(at) => {
                let wait = TimeDelta::from_std(at - now).unwrap_or_default();
                let when = (Utc::now() + wait).with_timezone(&self.shared.services.offset);
                let said = format!(
                    "这一小时已经叫醒过 {PER_HOUR} 次了，这条先攒着，{} 和攒下的一起叫醒",
                    when.format("%H:%M")
                );
                let _ = reply.send(Ok(said));
                Ok(())
            }
        }
    }

    /// The held wakes, once the hour allows.
    pub(super) async fn release_woken(&mut self) -> Result<()> {
        if self.stopping.is_some() {
            return Ok(());
        }
        match self.woken.release(Instant::now()) {
            Some(batch) => self.wake_programs(batch).await,
            None => Ok(()),
        }
    }

    async fn wake_programs(&mut self, batch: Batch) -> Result<()> {
        info!(conversation = %self.place.conversation, texts = batch.texts.len(), "a program wakes Max");
        let item = shown(&batch, self.single());
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

    fn batch(texts: &[&str], more: usize) -> Batch {
        Batch {
            texts: texts.iter().map(|&text| text.to_owned()).collect(),
            more,
        }
    }

    #[test]
    fn six_an_hour_then_the_rest_come_together() {
        let start = Instant::now();
        let at = |minutes: u64| start + Duration::from_secs(minutes * 60);
        let mut woken = Woken::default();
        for minute in 0..6 {
            let text = format!("第 {minute} 次");
            assert_eq!(
                woken.arrive(text.clone(), at(minute)),
                Ok(batch(&[&text], 0))
            );
        }
        // The hour after the first, the held ones may go.
        assert_eq!(woken.arrive("七".into(), at(10)), Err(at(60)));
        assert_eq!(woken.arrive("八".into(), at(20)), Err(at(60)));
        assert_eq!(woken.due(), Some(at(60)));
        assert_eq!(
            woken.summary(at(20)).as_deref(),
            Some("6/6 this hour, 2 held")
        );
        assert_eq!(woken.release(at(59)), None);
        assert_eq!(woken.release(at(60)), Some(batch(&["七", "八"], 0)));
        assert_eq!(woken.due(), None);
        // The first six went out of the hour since; the batch's is left.
        assert_eq!(woken.arrive("九".into(), at(65)), Ok(batch(&["九"], 0)));
        assert_eq!(woken.summary(at(65)).as_deref(), Some("2/6 this hour"));
    }

    #[test]
    fn past_twenty_held_only_a_count_is_kept() {
        let start = Instant::now();
        let mut woken = Woken::default();
        for n in 0..6 {
            woken.arrive(n.to_string(), start).unwrap();
        }
        for n in 0..25 {
            woken.arrive(format!("攒 {n}"), start).unwrap_err();
        }
        let released = woken.release(start + HOUR).unwrap();
        assert_eq!((released.texts.len(), released.more), (20, 5));
        let item = shown(&released, 25_000);
        let ItemKind::User { text, .. } = &item.kind else {
            panic!("{item:?}")
        };
        assert!(
            text.starts_with("[max-wake] 这一小时叫醒满了，攒下了 25 条：\n- 攒 0\n- 攒 1\n"),
            "{text}"
        );
        assert!(text.ends_with("- 攒 19\n（还有 5 条没留）"), "{text}");
    }

    #[test]
    fn one_text_is_shown_as_it_is() {
        let item = shown(&batch(&["CI 挂了 2 个\n"], 0), 25_000);
        let ItemKind::User { text, .. } = &item.kind else {
            panic!("{item:?}")
        };
        assert_eq!(text, "[max-wake] CI 挂了 2 个");
    }
}
