//! The running core: how the actor starts one, has it take its next step,
//! feeds it the model's output, and ends it.

use std::collections::HashSet;
use std::path::Path;

use chrono::Utc;
use color_eyre::eyre::{Result, eyre};
use max_core::intent::Reason;
use max_core::item::{Item, ModelOutput, Timing};
use max_core::limits::MEMORY_FILE_BYTES;
use max_core::message::{Draft, DraftNode};
use max_core::project::MEMORY_FILE;
use max_core::prompt;
use max_core::run::{FailReason, Fill, Input, Run, RunSpec, Step, Wake};
use max_db::{turns, usage};
use tokio::time::Instant;
use tracing::{info, warn};

use super::follow_up::Voice;
use super::{Active, Conversation, Does, End, failure};
use crate::conversation::ingest::By;
use crate::conversation::project::Projection;
use crate::conversation::{TaskId, model, tool};
use crate::scope::Scope;
use crate::vm::{self, Vms};
use crate::{llm, service, tokens};

impl Conversation {
    /// Max's memory file, read from the host's side of /work as the guest
    /// left it, and shown as `project::memory` says; empty without one.
    pub(super) async fn memory(&self) -> String {
        let Some(dir) = &self.shared.vm_dir else {
            return String::new();
        };
        let work = vm::work(dir, self.place.conversation);
        let file = Path::new(MEMORY_FILE)
            .strip_prefix("/work")
            .unwrap_or(Path::new(MEMORY_FILE))
            .to_path_buf();
        let read = tokio::task::spawn_blocking(move || {
            service::work::read(&work, &file, MEMORY_FILE_BYTES)
        });
        match read.await {
            Ok(Ok(bytes)) => {
                max_core::project::memory(&String::from_utf8_lossy(&bytes), tokens::count)
            }
            Ok(Err(failure)) if failure.code == "not_found" => String::new(),
            Ok(Err(failure)) if failure.code == "too_big" => format!(
                "（{MEMORY_FILE} 超过 {} KiB，整个没加载：整理一下。）",
                MEMORY_FILE_BYTES >> 10
            ),
            Ok(Err(failure)) => {
                warn!(conversation = %self.place.conversation, error = failure.message, "couldn't read the memory file");
                String::new()
            }
            Err(error) => {
                warn!(conversation = %self.place.conversation, %error, "couldn't read the memory file");
                String::new()
            }
        }
    }

    pub(super) async fn start_core(&mut self, wake: Wake) -> Result<()> {
        if self.refuses(Does::STARTS).is_some() {
            return Ok(());
        }
        let settings = &self.settings;
        let chosen = self
            .shared
            .models
            .turn(settings.model.as_deref(), settings.effort.as_deref())?
            .in_conversation(self.place.conversation);
        let now = Utc::now();
        let persona = settings.persona.as_deref().unwrap_or(prompt::PERSONA);
        let vms = self.shared.vms.as_ref();
        let apis = vms.map_or("", |vms| vms.apis());
        let platforms = &self.shared.services.platforms;
        let platform = platforms.get(&self.place.platform);
        let projection = Projection {
            place: &self.place,
            system: prompt::system(
                persona,
                &service::tool::DECLARATIONS,
                platform.map_or("", |adapter| adapter.notes()),
                apis,
                vms.map(Vms::idle),
            ),
            window: chosen.window,
            cleared_upto: settings.cleared_upto,
            memory: self.memory().await,
            now,
            offset: self.shared.services.offset,
        };
        // What wakes Max is a row, or comes to a conversation that has
        // rows: a core's base is projected from them.
        let from = self
            .head
            .ok_or_else(|| eyre!("a core can't start in a conversation without a row"))?;
        let mut conn = self.shared.services.pool.acquire().await?;
        let (context, inputs) = projection.base(&mut conn, from, vec![wake]).await?;
        let started = turns::start(&mut conn, self.place.conversation, &inputs, from, now).await?;
        drop(conn);
        let spec = RunSpec {
            model: chosen.tag.clone(),
            window: chosen.window,
            max_output: chosen.max_output,
        };
        let base: u32 = context.items.iter().map(|item| item.tokens).sum();
        info!(conversation = %self.place.conversation, turn = %started.turn, ordinal = started.ordinal, model = %chosen.reference(), base, "a core starts");
        self.core = Some(Active {
            turn: started.turn,
            ordinal: started.ordinal,
            run: Run::new(spec, context, inputs),
            chosen,
            io: Scope::new(),
            live: HashSet::new(),
            voice: Voice::default(),
            from,
            last_at: Some(now),
            idle_since: Instant::now(),
            started: Instant::now(),
        });
        Ok(())
    }

    /// After every event: what the core does next, if nothing is in flight.
    pub(super) async fn advance(&mut self) -> Result<()> {
        loop {
            let Some(active) = self.core.as_mut() else {
                return Ok(());
            };
            if active.run.is_busy() {
                return Ok(());
            }
            // Stopping, a core may finish what it is doing within the grace;
            // one with nothing to do ends now.
            if self.stopping.is_some() && active.run.is_idle() {
                self.end(End::Idle).await?;
                continue;
            }
            // Over its limits, the core gives up, and near them with
            // nothing to do, it ends; the next trigger starts a new one from
            // the ledger.
            if active.run.at_limit() || (active.run.is_idle() && active.run.near_limit()) {
                let how = if active.run.is_idle() {
                    End::Idle
                } else {
                    End::Failed(FailReason::ContextExhausted)
                };
                self.end(how).await?;
                continue;
            }
            match active.run.next_step() {
                Step::CallModel(request) => {
                    self.seen = self.head;
                    self.next_task += 1;
                    let task = TaskId::new(self.next_task);
                    active.live.insert(task);
                    let chosen = active.chosen.clone();
                    let mailbox = self.mailbox.clone();
                    let pictures = self.shared.pictures.clone();
                    let abort = active
                        .io
                        .spawn(move |_| model::call(chosen, pictures, request, task, mailbox));
                    active.voice.calls(task, abort);
                    return Ok(());
                }
                Step::RunTools(calls) => {
                    for call in calls {
                        self.next_task += 1;
                        let task = TaskId::new(self.next_task);
                        active.live.insert(task);
                        let vms = self.shared.vms.clone();
                        let context = crate::tools::Context {
                            conversation: self.place.conversation,
                            store: self.shared.services.store.clone(),
                            video: active.chosen.video,
                        };
                        let mailbox = self.mailbox.clone();
                        active
                            .io
                            .spawn(move |_| tool::call(vms, context, call, task, mailbox));
                    }
                    return Ok(());
                }
                Step::Idle => return Ok(()),
            }
        }
    }

    pub(super) async fn model_output(&mut self, out: ModelOutput, timing: Timing) -> Result<()> {
        let Some(active) = self.core.as_mut() else {
            return Ok(());
        };
        active.voice.taken();
        active.idle_since = Instant::now();
        let used = out.usage;
        if let Err(rejected) = active.run.model_output(out) {
            warn!(turn = %active.turn, %rejected, "a model output didn't fit");
        }
        let call = active.chosen.usage(
            usage::Purpose::Turn,
            Some(self.place.conversation),
            Some(active.turn),
            used,
            Some(timing),
        );
        llm::record(&self.shared.services.pool, &call).await;
        Ok(())
    }

    /// Wakes Max with `item`: in the running core, or a new one.
    pub(super) async fn wake_with(&mut self, reason: Reason, item: Item) -> Result<()> {
        let wake = Wake {
            ids: Vec::new(),
            reason,
            item: Some(item),
        };
        match self.core.as_mut() {
            Some(active) => {
                if let Err(rejected) = active.run.input(Input::Wake(wake)) {
                    warn!(turn = %active.turn, %rejected, "a wake didn't fit the core");
                }
            }
            None => self.start_core(wake).await?,
        }
        Ok(())
    }

    pub(super) async fn end(&mut self, how: End) -> Result<()> {
        let Some(mut active) = self.core.take() else {
            return Ok(());
        };
        // Aborts the model call in flight: started now, not waited for.
        drop(active.io);
        if let Some(text) = active.voice.cut_off() {
            let tokens = tokens::count(&text);
            if let Err(rejected) = active.run.partial_output(text, tokens) {
                warn!(turn = %active.turn, %rejected, "the partial output didn't fit");
            }
        }
        let applied = match &how {
            End::Kill(reason) => {
                info!(turn = %active.turn, reason, "killed");
                active.run.interrupt()
            }
            End::Stopped => active.run.interrupt(),
            End::Failed(reason) => active.run.fail(reason.clone()),
            End::Idle => Ok(()),
        };
        if let Err(rejected) = applied {
            warn!(turn = %active.turn, %rejected, "the ending didn't fit");
        }
        let outcome = active.run.outcome();
        let mut conn = self.shared.services.pool.acquire().await?;
        turns::finish(
            &mut conn,
            active.turn,
            &active.run.record(),
            &outcome,
            Utc::now(),
        )
        .await?;
        info!(turn = %active.turn, ?outcome, rounds = active.run.round(), warned = active.run.is_warned(), "the core ends");
        drop(conn);
        let why = match how {
            End::Failed(FailReason::Model { error }) => failure("the model call failed", &error),
            End::Failed(FailReason::ContextExhausted) => {
                let Fill { tokens, limit } = active.run.fill();
                let reason = format!("{tokens} tokens, limit {limit}");
                failure("the context is full", &reason)
            }
            End::Stopped => {
                let grace = self.shared.stop_grace;
                let reason =
                    format!("Max is shutting down, and the turn outlasted the {grace:?} grace");
                failure("interrupted", &reason)
            }
            End::Kill(_) | End::Idle => return Ok(()),
        };
        self.report_unanswered(&active.run, &why).await
    }

    /// A short line under the latest direct trigger the run didn't get to;
    /// a judged wake goes unanswered, as Max may stay quiet anyway.
    pub(super) async fn report_unanswered(&mut self, run: &Run, why: &str) -> Result<()> {
        let trigger = run
            .unhandled()
            .iter()
            .filter(|wake| wake.reason == Reason::Direct)
            .filter_map(|wake| wake.ids.last().copied())
            .max();
        let Some(trigger) = trigger else {
            return Ok(());
        };
        let draft = Draft {
            reply_to: Some(trigger),
            nodes: vec![DraftNode::Text { text: why.into() }],
        };
        self.say(draft, None, None, By::Host, None).await?;
        Ok(())
    }
}
