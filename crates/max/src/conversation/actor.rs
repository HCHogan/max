//! The actor's loop: commit, route, and drive the core. It awaits only the
//! database; model calls run as tasks in the core's `io` scope and come
//! back as events.

use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use color_eyre::eyre::{Report, Result};
use max_core::ids::{ConversationId, IdentityId, MessageId, PrincipalId, TurnId};
use max_core::intent::{Decision, Entry, EntryKind, Intent, Reason};
use max_core::message::{Message, Platform};
use max_core::prompt;
use max_core::render::Mark;
use max_core::run::{FailReason, Input, Outcome, Run, Wake};
use max_db::platform::{self, Settings};
use max_db::{ledger, turns};
use tokio::sync::broadcast;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::time::{Instant, sleep_until};
use tracing::{debug, warn};

use self::follow_up::Voice;
use super::ingest::{self, By};
use super::notice::Notice;
use super::project;
use super::{Event, Place, Receipt, Refusal, Signal, Subscription, TaskId, Unanswered, classify};
use crate::bind::Binds;
use crate::causes;
use crate::code::Codes;
use crate::command;
use crate::config::Limits;
use crate::inbound::Inbound;
use crate::llm::{Chosen, Models};
use crate::media::pictures::Pictures;
use crate::scope::Scope;
use crate::service;
use crate::vm::Vms;
use crate::worker::Rows;

/// How many rows a program following the timeline may fall behind by;
/// further behind, it starts again from the database.
const SUBSCRIBED_ROWS: usize = 256;
/// The most of a reason a failure line shows: a provider's error page
/// runs to kilobytes.
const REASON_CHARS: usize = 300;

/// What an event would have the conversation do, as far as stopping
/// goes: whether it has Max say or do something, which `/stop` forbids,
/// and whether it starts work, which Max shutting down forbids.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Does {
    acts: bool,
    starts: bool,
}

impl Does {
    /// Reads something, or changes a setting.
    pub(super) const LOOKS: Self = Self::new(false, false);
    /// Has Max say or do something as part of what already runs.
    pub(super) const ACTS: Self = Self::new(true, false);
    /// Starts work that says and does nothing by itself: a program's call
    /// of a tool, which is refused in its turn if it would act.
    pub(super) const RUNS: Self = Self::new(false, true);
    /// Starts something Max is to act on: a question, an answer, a wake.
    pub(super) const STARTS: Self = Self::new(true, true);

    const fn new(acts: bool, starts: bool) -> Self {
        Self { acts, starts }
    }
}

/// What every conversation's actor shares.
#[derive(Debug)]
pub struct Shared {
    /// The database, and what the tools reach.
    pub services: Arc<service::Services>,
    /// The configured models.
    pub models: Arc<Models>,
    /// To each platform's sender: what the conversations say.
    pub outbound: HashMap<Platform, UnboundedSender<Outgoing>>,
    /// How long a core may go on when Max stops, before it is interrupted.
    pub stop_grace: Duration,
    /// Max's owners, who may run every command.
    pub owners: BTreeSet<PrincipalId>,
    /// The codes of `/bind`.
    pub binds: Arc<Binds>,
    /// The codes of `/link`: each is for the conversation whose Max is to
    /// ask.
    pub links: Arc<Codes<ConversationId>>,
    /// To the conversation table, for another conversation's actor: a
    /// question for its Max.
    pub signals: UnboundedSender<Signal>,
    /// The derived-data workers, which hear of every committed row.
    pub rows: Rows,
    /// None when no VMs are configured: the tools say so.
    pub vms: Option<Vms>,
    /// The VMs' directory, which holds each conversation's /work and so
    /// its memory file; None when no VMs are configured.
    pub vm_dir: Option<PathBuf>,
    /// Where model calls find their pictures; None when no media
    /// directory is configured, and none are sent.
    pub pictures: Option<Arc<Pictures>>,
    /// When Max started, for `/status`.
    pub started: Instant,
    /// The configuration file's defaults of the limits a conversation
    /// may set for itself.
    pub limits: Limits,
}

/// Something Max said, committed, for the platform's sender.
#[derive(Debug)]
pub struct Outgoing {
    /// Where it goes.
    pub place: Arc<Place>,
    /// The row.
    pub message: Arc<Message>,
    /// Told once it is sent or failed, for a `Post` that waits.
    pub receipt: Option<Receipt>,
}

/// A conversation's actor: its state, and the loop that is its one
/// writer. See the module.
pub struct Conversation {
    shared: Arc<Shared>,
    place: Arc<Place>,
    settings: Settings,
    /// The last row of the timeline, once there is one.
    head: Option<MessageId>,
    /// Everything up to here has been in a model request.
    seen: Option<MessageId>,
    core: Option<Active>,
    intent: Intent,
    /// The classifier, and the calls of the programs in the group's VM.
    side: Scope,
    stopping: Option<Instant>,
    next_task: u64,
    mailbox: UnboundedSender<Event>,
    /// Who addressed Max in the last [`FOLLOW_UP`], and when they last did.
    addressed: HashMap<IdentityId, Instant>,
    /// What Max in other conversations asked Max here, kept for its
    /// answers.
    asked: asking::Asked,
    /// The wakes from the group's programs lately, and the held ones.
    woken: woken::Woken,
    /// What the group's programs said lately.
    /// Every row committed, for the programs following the timeline.
    subscribers: broadcast::Sender<Arc<Message>>,
}

/// By its conversation and where its timeline has come to.
impl fmt::Debug for Conversation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Conversation")
            .field("conversation", &self.place.conversation)
            .field("head", &self.head)
            .field("running", &self.core.is_some())
            .finish_non_exhaustive()
    }
}

struct Active {
    turn: TurnId,
    ordinal: i32,
    run: Run,
    chosen: Chosen,
    io: Scope,
    live: HashSet<TaskId>,
    /// What its model calls have said, and the one in flight.
    voice: Voice,
    /// The snapshot position: the base context is projected from the
    /// rows up to here; later ones are fed, with their pictures.
    from: MessageId,
    /// When the last row the core saw was sent, for date lines; at first,
    /// when the core started.
    last_at: Option<DateTime<Utc>>,
    idle_since: Instant,
    started: Instant,
}

/// How a core ends.
enum End {
    Kill(String),
    Failed(FailReason),
    /// Idle: its window ran out, or Max is stopping.
    Idle,
    /// Max is stopping and the core wasn't done within the grace.
    Stopped,
}

impl Conversation {
    /// The actor of the conversation at `place`, as the ledger and its
    /// settings have it; `mailbox` is its own, for the tasks it starts.
    ///
    /// # Errors
    ///
    /// If the database can't be read.
    pub async fn new(
        shared: Arc<Shared>,
        place: Arc<Place>,
        mailbox: UnboundedSender<Event>,
    ) -> Result<Self> {
        let mut conn = shared.services.pool.acquire().await?;
        let head = ledger::head(&mut conn, place.conversation).await?;
        let settings = platform::settings(&mut conn, place.conversation).await?;
        let mut intent = Intent::new();
        intent.set_proactive(settings.proactive);
        Ok(Self {
            shared,
            place,
            settings,
            head,
            seen: head,
            core: None,
            intent,
            side: Scope::new(),
            stopping: None,
            next_task: 0,
            mailbox,
            addressed: HashMap::new(),
            asked: asking::Asked::default(),
            woken: woken::Woken::default(),
            subscribers: broadcast::Sender::new(SUBSCRIBED_ROWS),
        })
    }

    /// Until `Event::Stop` and the core is done with; or until an error,
    /// when it gives up.
    ///
    /// # Errors
    ///
    /// What the actor gave up on, a failed query for the most part: its
    /// turns are closed as lost before it returns.
    pub async fn run(mut self, mut mailbox: UnboundedReceiver<Event>) -> Result<()> {
        self.learn_title();
        let served = self.serve(&mut mailbox).await;
        if let Err(error) = &served {
            self.give_up(error).await;
        }
        served
    }

    /// Asks the platform what this chat is called, and keeps the answer
    /// as the conversation's title, by which other conversations name this
    /// one. Once as the actor starts, so a group renamed is known by its
    /// new name after Max restarts. In a task of its own: the actor waits
    /// only on the database. Without an answer the title stays as it was.
    fn learn_title(&mut self) {
        let Some(adapter) = self.shared.services.platforms.get(&self.place.platform) else {
            return;
        };
        let (adapter, place) = (Arc::clone(adapter), Arc::clone(&self.place));
        let pool = self.shared.services.pool.clone();
        let conversation = self.place.conversation;
        self.side.spawn(move |_| async move {
            let learned = async {
                let Some(title) = adapter.title(&place).await? else {
                    return Ok(());
                };
                let mut conn = pool.acquire().await?;
                platform::set_title(&mut conn, conversation, &title).await?;
                Ok::<_, Report>(())
            };
            if let Err(error) = learned.await {
                warn!(%conversation, %error, "couldn't learn what the chat is called");
            }
        });
    }

    async fn serve(&mut self, mailbox: &mut UnboundedReceiver<Event>) -> Result<()> {
        loop {
            let deadline = self.deadline();
            tokio::select! {
                event = mailbox.recv() => match event {
                    Some(event) => self.handle(event).await?,
                    None => self.stop(),
                },
                () = sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => {
                    self.timer().await?;
                }
            }
            self.advance().await?;
            if self.stopping.is_some() && self.core.is_none() {
                return Ok(());
            }
        }
    }

    /// After an error: the core is stopped, and the conversation's
    /// unfinished turns end lost, as in a crash, so they don't look
    /// running. A line says so, with the error, if the database lets it.
    /// The next message starts the conversation again. What runs in the
    /// group's VM runs on: it isn't the actor's.
    async fn give_up(&mut self, error: &Report) {
        let core = self.core.take();
        self.refuse_questions(Unanswered::TurnOver);
        let why = causes::chain(&**error);
        if let Err(error) = self.wind_up(core, &why).await {
            let conversation = self.place.conversation;
            warn!(%conversation, %error, "couldn't wind up after the error");
        }
    }

    async fn wind_up(&mut self, core: Option<Active>, why: &str) -> Result<()> {
        let mut conn = self.shared.services.pool.acquire().await?;
        for turn in turns::unfinished(&mut conn, Some(self.place.conversation)).await? {
            turns::close(&mut conn, turn, &Outcome::Lost, Utc::now()).await?;
        }
        drop(conn);
        if let Some(active) = core {
            drop(active.io);
            let text = failure("the conversation failed", why);
            self.report_unanswered(&active.run, &text).await?;
        }
        Ok(())
    }

    fn deadline(&self) -> Option<Instant> {
        let core = self.core.as_ref().and_then(|active| {
            if self.stopping.is_some() {
                self.stopping
            } else if active.run.is_idle() {
                Some(active.idle_since + self.idle_window(active))
            } else {
                None
            }
        });
        [core, self.intent.deadline().map(Instant::from_std)]
            .into_iter()
            .flatten()
            .min()
    }

    async fn handle(&mut self, event: Event) -> Result<()> {
        match event {
            Event::Inbound(inbound) => self.inbound(inbound, false).await,
            Event::Bound(inbound) => self.inbound(inbound, true).await,
            Event::Post(post) => self.post(post).await,
            Event::Said { task, segment } => {
                let Some(active) = self
                    .core
                    .as_mut()
                    .filter(|active| active.live.contains(&task))
                else {
                    debug!(%task, "dropped a stale Said");
                    return Ok(());
                };
                let (turn, index) = (active.turn, active.voice.says(segment.source));
                let said = self
                    .say(segment.draft, Some(turn), Some(index), By::Max, None)
                    .await?;
                if let Some((_, at)) = said
                    && let Some(active) = self.core.as_mut()
                {
                    active.last_at = Some(at);
                }
                Ok(())
            }
            Event::ModelDone { task, out } => {
                if !self.finished(task) {
                    debug!(%task, "dropped a stale ModelDone");
                    return Ok(());
                }
                if let Some(active) = self.core.as_mut() {
                    active.voice.called();
                }
                match out {
                    Ok((out, timing)) => self.model_output(out, timing).await,
                    Err(error) => {
                        let error = causes::chain(&error);
                        warn!(conversation = %self.place.conversation, error, "the model call failed");
                        self.end(End::Failed(FailReason::Model { error })).await
                    }
                }
            }
            Event::ToolDone { task, call, out } => {
                if self.finished(task)
                    && let Some(active) = self.core.as_mut()
                    && let Err(rejected) = active.run.tool_result(call, out)
                {
                    warn!(turn = %active.turn, %rejected, "a tool result didn't fit");
                }
                Ok(())
            }
            Event::Verdict(verdict) => {
                let decisions = self.intent.verdict(verdict, std::time::Instant::now());
                self.decide(decisions).await
            }
            Event::Request(request) => self.request(request).await,
            Event::Heard(heard) => self.heard(heard).await,
            Event::Call { tool, args, reply } => {
                self.program_call(tool, args, reply);
                Ok(())
            }
            Event::Subscribe(reply) => {
                let subscription = Subscription {
                    place: Arc::clone(&self.place),
                    head: self.head,
                    rows: self.subscribers.subscribe(),
                    services: Arc::clone(&self.shared.services),
                };
                let _ = reply.send(subscription);
                Ok(())
            }
            Event::Stop => {
                self.stop();
                Ok(())
            }
        }
    }

    /// A row is committed: it is the head, and the workers and the
    /// programs following the timeline hear of it.
    fn committed(&mut self, message: &Arc<Message>) {
        self.head = Some(message.id);
        self.shared.rows.send(&self.place, message);
        if self.subscribers.receiver_count() > 0 {
            let _ = self.subscribers.send(Arc::clone(message));
        }
    }

    /// Whether `task` was the current core's, which no longer waits for it.
    fn finished(&mut self, task: TaskId) -> bool {
        self.core
            .as_mut()
            .is_some_and(|active| active.live.remove(&task))
    }

    fn stop(&mut self) {
        if self.stopping.is_none() {
            self.stopping = Some(Instant::now() + self.shared.stop_grace);
        }
    }

    async fn inbound(&mut self, inbound: Inbound, bound: bool) -> Result<()> {
        // A group bound to an old conversation goes on from its history.
        let continued = self.head.is_some();
        let mut conn = self.shared.services.pool.acquire().await?;
        // A platform may say a message twice, as QQ does when it replays
        // a resumed session.
        let known = ledger::by_native_id(&mut conn, self.place.endpoint, &inbound.native_id);
        if let Some(id) = known.await? {
            debug!(%id, native_id = inbound.native_id, "dropped a message already committed");
            return Ok(());
        }
        let mut committed = ingest::inbound(
            &mut conn,
            &self.place,
            inbound,
            Utc::now(),
            self.shared.services.offset,
        )
        .await?;
        drop(conn);
        self.committed(&committed.message);
        let command = committed.command.take();
        let kind = if command.is_some() {
            EntryKind::Command
        } else if committed.direct.is_some() {
            EntryKind::Direct
        } else {
            EntryKind::Chatter
        };
        if bound {
            self.bound(continued).await?;
        } else if let Some(command) = command {
            self.command(&committed, command).await?;
        } else {
            let mark = committed
                .direct
                .map_or(Mark::None, super::ingest::Direct::mark);
            self.feed(&[(&committed.message, mark)]).await?;
            self.follow_up(&committed).await?;
        }
        // Stopped, intent doesn't see it: no classifier call, and no wake.
        // It is in the next core's tail all the same.
        if self.settings.stopped {
            return Ok(());
        }
        let entry = Entry {
            id: committed.message.id,
            sender: committed.sender.identity,
            kind,
            text: committed.text,
        };
        let decisions = self.intent.observe(&entry, std::time::Instant::now());
        self.decide(decisions).await
    }

    /// Rows from the timeline for a running core.
    async fn feed(&mut self, rows: &[(&Message, Mark)]) -> Result<()> {
        let Some(active) = self.core.as_mut() else {
            return Ok(());
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let mut input = project::follow_up(
            &mut conn,
            &self.place,
            rows,
            active.run.roster(),
            active.last_at,
            active.chosen.window,
            self.shared.services.offset,
        )
        .await?;
        // A picture they quote from before the core started was likely
        // shown only by its caption: it comes after them.
        let mut quoted = Vec::new();
        for id in rows
            .iter()
            .filter_map(|(message, _)| project::quotes(message))
        {
            if id <= active.from
                && let Some(row) = ledger::row(&mut conn, self.place.conversation, id).await?
            {
                quoted.push(row.message);
            }
        }
        if let Input::Messages { item, .. } = &mut input {
            let messages = rows.iter().map(|(message, _)| *message).chain(&quoted);
            max_core::project::attach(item, messages);
        }
        active.last_at = rows
            .last()
            .map(|(message, _)| message.at)
            .or(active.last_at);
        if let Err(rejected) = active.run.input(input) {
            warn!(turn = %active.turn, %rejected, "rows didn't fit the core");
        }
        Ok(())
    }

    async fn decide(&mut self, decisions: Vec<Decision>) -> Result<()> {
        let mut decisions = VecDeque::from(decisions);
        while let Some(decision) = decisions.pop_front() {
            match decision {
                Decision::Wake { ids, reason } => {
                    if ids.iter().all(|id| Some(*id) <= self.seen) {
                        debug!(?ids, "dropped a wake for rows a model has seen");
                        continue;
                    }
                    let item = match &reason {
                        Reason::Judged { note } => {
                            Some(Notice::Judged { note }.item(self.single()))
                        }
                        _ => None,
                    };
                    let wake = Wake { ids, item, reason };
                    match self.core.as_mut() {
                        Some(active) => {
                            if let Err(rejected) = active.run.input(Input::Wake(wake)) {
                                warn!(turn = %active.turn, %rejected, "a wake didn't fit the core");
                            }
                        }
                        None => self.start_core(wake).await?,
                    }
                }
                Decision::Classify { batch } => match self.shared.models.intent() {
                    Ok(chosen) => self.classify(chosen, batch),
                    Err(error) => {
                        warn!(%error, "no model to classify with");
                        let now = std::time::Instant::now();
                        decisions.extend(self.intent.verdict(None, now));
                    }
                },
            }
        }
        Ok(())
    }

    fn classify(&mut self, chosen: Chosen, batch: Vec<MessageId>) {
        let persona = self.settings.persona.as_deref().unwrap_or(prompt::PERSONA);
        let job = classify::Job {
            pool: self.shared.services.pool.clone(),
            place: Arc::clone(&self.place),
            chosen,
            persona: persona.to_owned(),
            batch,
            context_lines: classify::CONTEXT_LINES,
            offset: self.shared.services.offset,
        };
        let mailbox = self.mailbox.clone();
        self.side.spawn(move |_| classify::classify(job, mailbox));
    }

    async fn timer(&mut self) -> Result<()> {
        let now = Instant::now();
        if let Some(active) = &self.core {
            if self.stopping.is_some_and(|deadline| now >= deadline) {
                self.end(End::Stopped).await?;
            } else if active.run.is_idle() && now >= active.idle_since + self.idle_window(active) {
                self.end(End::Idle).await?;
            }
        }
        let decisions = self.intent.tick(now.into_std());
        self.decide(decisions).await
    }

    /// Whether the conversation refuses what an event asks: the one place
    /// that says what goes on after `/stop` and as Max shuts down. What
    /// asks is something in the VM, and which of the things there, a
    /// turn's program or another, the host doesn't know: a turn killed
    /// while its program runs may see one more thing said, in the moment
    /// before the program's unit is stopped.
    pub(super) fn refuses(&self, does: Does) -> Option<Refusal> {
        if does.acts && self.settings.stopped {
            return Some(Refusal::Stopped);
        }
        (does.starts && self.stopping.is_some()).then_some(Refusal::Stopping)
    }
}

/// What the host says when something fails, like a log, in a text code
/// block: `error: what: reason`, the reason as it came on one line, cut
/// when long.
fn failure(what: &str, reason: &str) -> String {
    let reason = reason.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut line = format!("error: {what}: ");
    line.extend(reason.chars().take(REASON_CHARS));
    if reason.chars().count() > REASON_CHARS {
        line.push('…');
    }
    command::fenced("text", &line)
}

mod asking;
mod commands;
mod follow_up;
mod links;
mod program;
mod requests;
mod running;
mod saying;
mod settings;
#[cfg(test)]
mod tests;
mod woken;
