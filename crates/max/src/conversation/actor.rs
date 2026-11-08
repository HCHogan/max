//! The actor's loop: commit, route, and drive the core. It awaits only the
//! database; model calls run as tasks in the core's `io` scope and come
//! back as events.

use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use color_eyre::eyre::{Report, Result};
use max_core::ids::{IdentityId, MessageId, PrincipalId, TurnId};
use max_core::intent::{Decision, Entry, EntryKind, Intent, Reason};
use max_core::item::{Item, ItemKind, ModelOutput, Timing};
use max_core::message::{Content, Draft, DraftNode, Message, Node};
use max_core::project::{Budgets, MEMORY_FILE};
use max_core::prompt;
use max_core::render::Mark;
use max_core::run::{FailReason, Input, Outcome, Run, RunSpec, Step, Wake};
use max_db::platform::{self, Settings};
use max_db::{ledger, turns, usage};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::sync::{broadcast, watch};
use tokio::task::AbortHandle;
use tokio::time::{Instant, sleep_until};
use tracing::{debug, info, warn};

use super::ingest::{self, By};
use super::project::{self, Projection};
use super::{
    Act, Event, Place, Post, Poster, Receipt, Subscription, TaskId, classify, model, tool,
};
use crate::bind::Binds;
use crate::command;
use crate::inbound::Inbound;
use crate::llm::{self, Chosen, Models};
use crate::mcp;
use crate::media::pictures::Pictures;
use crate::scope::Scope;
use crate::tokens;
use crate::vm::{self, Vms};
use crate::worker::Rows;
use max_core::limits::MEMORY_FILE_BYTES;

/// How many rows a program following the timeline may fall behind by;
/// further behind, it starts again from the database.
const SUBSCRIBED_ROWS: usize = 256;
/// How long after someone addresses Max their next message may finish
/// what they meant, and start over the model call in flight. People
/// added to an @ 3 to 38 seconds later (2026-11-04).
const FOLLOW_UP: Duration = Duration::from_secs(60);
/// The most times a model call starts over before one finishes.
const MOST_RESTARTS: u32 = 3;
/// The most of a reason a failure line shows: a provider's error page
/// runs to kilobytes.
const REASON_CHARS: usize = 300;

/// What every conversation's actor shares.
pub struct Shared {
    /// The database, and what the tools reach.
    pub services: Arc<mcp::Services>,
    pub models: Arc<Models>,
    pub outbound: UnboundedSender<Outgoing>,
    /// How long a core may go on when Max stops, before it is interrupted.
    pub stop_grace: Duration,
    /// Max's owners, who may run every command.
    pub owners: BTreeSet<PrincipalId>,
    pub binds: Arc<Binds>,
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
}

/// Something Max said, committed, for the platform's sender.
#[derive(Debug)]
pub struct Outgoing {
    pub place: Arc<Place>,
    pub message: Arc<Message>,
    /// Told once it is sent or failed, for a `Post` that waits.
    pub receipt: Option<Receipt>,
}

pub struct Conversation {
    shared: Arc<Shared>,
    place: Arc<Place>,
    settings: Settings,
    head: MessageId,
    /// Everything up to here has been in a model request.
    seen: MessageId,
    core: Option<Active>,
    intent: Intent,
    /// The classifier, and the calls of the programs in the group's VM.
    side: Scope,
    stopping: Option<Instant>,
    next_task: u64,
    mailbox: UnboundedSender<Event>,
    /// Who addressed Max in the last [`FOLLOW_UP`], and when they last did.
    addressed: HashMap<IdentityId, Instant>,
    /// The background agents running; they don't outlive the actor.
    jobs: jobs::Jobs,
    /// The wakes from the group's programs lately, and the held ones.
    woken: woken::Woken,
    /// What the group's programs said lately.
    /// Every row committed, for the programs following the timeline.
    subscribers: broadcast::Sender<Arc<Message>>,
}

struct Active {
    turn: TurnId,
    ordinal: i32,
    run: Run,
    chosen: Chosen,
    io: Scope,
    live: HashSet<TaskId>,
    /// What the model call in flight has said, segment by segment.
    said: Vec<String>,
    segments: i32,
    /// The model call in flight, if one is.
    calling: Option<Calling>,
    /// How many times the model call has started over since one finished.
    restarts: u32,
    /// When the core last said something.
    said_at: Option<Instant>,
    /// The people the model has been shown.
    roster: BTreeSet<PrincipalId>,
    /// The snapshot position: the base context is projected from the
    /// rows up to here; later ones are fed, with their pictures.
    from: MessageId,
    /// Whether someone waits on the run, as [`Run::waited_on`] says, for
    /// its commands: one they wait on moves to the background.
    waiting: watch::Sender<bool>,
    /// When the last row the core saw was sent, for date lines; at first,
    /// when the core started.
    last_at: Option<DateTime<Utc>>,
    idle_since: Instant,
    started: Instant,
}

/// A model call in flight.
struct Calling {
    task: TaskId,
    abort: AbortHandle,
    /// How many segments the core had said when it started.
    segments: i32,
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
    pub async fn new(
        shared: Arc<Shared>,
        place: Arc<Place>,
        mailbox: UnboundedSender<Event>,
    ) -> Result<Self> {
        let mut conn = shared.services.pool.acquire().await?;
        let head = ledger::head(&mut conn, place.conversation)
            .await?
            .unwrap_or(MessageId(0));
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
            jobs: jobs::Jobs::default(),
            woken: woken::Woken::default(),
            subscribers: broadcast::Sender::new(SUBSCRIBED_ROWS),
        })
    }

    /// Until `Event::Stop` and the core is done with; or until an error,
    /// when it gives up.
    pub async fn run(mut self, mut mailbox: UnboundedReceiver<Event>) -> Result<()> {
        let served = self.serve(&mut mailbox).await;
        if let Err(error) = &served {
            self.give_up(error).await;
        }
        served
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

    /// After an error: the core and the jobs are stopped, and the
    /// conversation's unfinished turns end lost, as in a crash, so they
    /// don't look running. A line says so, with the error, if the database
    /// lets it. The next message starts the conversation again.
    async fn give_up(&mut self, error: &Report) {
        let core = self.core.take();
        let jobs = self.cancel_jobs();
        let why = chain(error);
        if let Err(error) = self.wind_up(core, &jobs, &why).await {
            let conversation = self.place.conversation;
            warn!(%conversation, %error, "couldn't wind up after the error");
        }
    }

    async fn wind_up(&mut self, core: Option<Active>, jobs: &[u32], why: &str) -> Result<()> {
        let mut conn = self.shared.services.pool.acquire().await?;
        for turn in turns::unfinished(&mut conn, Some(self.place.conversation)).await? {
            turns::close(&mut conn, turn, &Outcome::Lost, Utc::now()).await?;
        }
        drop(conn);
        if let Some(a) = core {
            drop(a.io);
            let text = failure("the conversation failed", why, &[]);
            self.report_unanswered(&a.run, &text).await?;
        }
        if !jobs.is_empty() {
            let text = failure("the conversation failed", why, jobs);
            let draft = Draft {
                reply_to: None,
                nodes: vec![DraftNode::Text { text }],
            };
            self.say(draft, None, None, By::Host, None).await?;
        }
        Ok(())
    }

    fn deadline(&self) -> Option<Instant> {
        let core = self.core.as_ref().and_then(|a| {
            if self.stopping.is_some() {
                self.stopping
            } else if a.run.idle() {
                Some(a.idle_since + a.chosen.idle_window)
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
                let Some(a) = self.core.as_mut().filter(|a| a.live.contains(&task)) else {
                    debug!(%task, "dropped a stale Said");
                    return Ok(());
                };
                a.said.push(segment.source);
                a.segments += 1;
                a.said_at = Some(Instant::now());
                let (turn, index) = (a.turn, a.segments);
                let said = self
                    .say(segment.draft, Some(turn), Some(index), By::Max, None)
                    .await?;
                if let Some(at) = said
                    && let Some(a) = self.core.as_mut()
                {
                    a.last_at = Some(at);
                }
                Ok(())
            }
            Event::ModelDone { task, out } => {
                if !self.finished(task) {
                    debug!(%task, "dropped a stale ModelDone");
                    return Ok(());
                }
                if let Some(a) = self.core.as_mut() {
                    a.calling = None;
                    a.restarts = 0;
                }
                match out {
                    Ok((out, timing)) => self.model_output(out, timing).await,
                    Err(error) => {
                        warn!(conversation = %self.place.conversation, %error, "the model call failed");
                        self.end(End::Failed(FailReason::Model { error })).await
                    }
                }
            }
            Event::ToolDone { task, call, out } => {
                if self.finished(task)
                    && let Some(a) = self.core.as_mut()
                    && let Err(rejected) = a.run.tool_result(call, out)
                {
                    warn!(turn = %a.turn, %rejected, "a tool result didn't fit");
                }
                Ok(())
            }
            Event::Verdict(verdict) => {
                let decisions = self.intent.verdict(verdict, std::time::Instant::now());
                self.decide(decisions).await
            }
            Event::Jobs {
                request,
                origin,
                reply,
            } => {
                let answer = match self.ended(origin) {
                    Some(refused) => Err(refused),
                    None => self.job_request(request),
                };
                let _ = reply.send(answer);
                Ok(())
            }
            Event::Move {
                moved,
                origin,
                reply,
            } => {
                let answer = match self.ended(origin) {
                    Some(refused) => Err((refused, moved)),
                    None => self.adopt(moved),
                };
                let _ = reply.send(answer);
                Ok(())
            }
            Event::JobAsks { job, question } => self.job_asks(job, question).await,
            Event::JobDone { job, finished } => self.job_done(job, finished).await,
            Event::Woken { text, reply } => self.woken(text, reply).await,
            Event::VmNotice(text) => self.vm_notice(text).await,
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
        self.head = message.id;
        self.shared.rows.send(&self.place, message);
        if self.subscribers.receiver_count() > 0 {
            let _ = self.subscribers.send(Arc::clone(message));
        }
    }

    /// Whether `task` was the current core's, which no longer waits for it.
    fn finished(&mut self, task: TaskId) -> bool {
        self.core.as_mut().is_some_and(|a| a.live.remove(&task))
    }

    fn stop(&mut self) {
        if self.stopping.is_none() {
            self.stopping = Some(Instant::now() + self.shared.stop_grace);
        }
    }

    async fn inbound(&mut self, inbound: Inbound, bound: bool) -> Result<()> {
        // A group bound to an old conversation goes on from its history.
        let continued = self.head > MessageId(0);
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
            let mark = committed.direct.map_or(Mark::None, |direct| direct.mark());
            self.feed(&[(&committed.message, mark)]).await?;
            self.follow_up(&committed).await?;
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
        let Some(a) = self.core.as_mut() else {
            return Ok(());
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let mut input = project::follow_up(
            &mut conn,
            &self.place,
            rows,
            &a.roster,
            a.last_at,
            a.chosen.window,
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
            if id <= a.from
                && let Some(row) = ledger::row(&mut conn, self.place.conversation, id).await?
            {
                quoted.push(row.message);
            }
        }
        if let Input::Messages { people, item, .. } = &mut input {
            a.roster.extend(people.iter());
            let messages = rows.iter().map(|(message, _)| *message).chain(&quoted);
            max_core::project::attach(item, messages);
        }
        a.last_at = rows.last().map(|(message, _)| message.at).or(a.last_at);
        if let Err(rejected) = a.run.input(input) {
            warn!(turn = %a.turn, %rejected, "rows didn't fit the core");
        }
        Ok(())
    }

    /// Starts the model call in flight over when `committed` looks like
    /// the rest of what its sender meant: they addressed Max in the last
    /// [`FOLLOW_UP`], haven't been answered since, and aren't talking to
    /// someone else now. Nothing is lost: the call hasn't said anything,
    /// tools run only after it, and the next one is the same request with
    /// the row added, which the provider has cached. Other wakes, a job's
    /// or the classifier's, wait for the next call: they don't change the
    /// answer someone is waiting for.
    async fn follow_up(&mut self, committed: &ingest::Committed) -> Result<()> {
        let now = Instant::now();
        let sender = committed.sender.identity;
        self.addressed.retain(|_, at| now < *at + FOLLOW_UP);
        let since = self.addressed.get(&sender).copied();
        if committed.direct.is_some() {
            self.addressed.insert(sender, now);
        }
        let Some(since) = since else {
            return Ok(());
        };
        let Some(a) = &self.core else {
            return Ok(());
        };
        let fresh = a
            .calling
            .as_ref()
            .is_some_and(|calling| a.segments == calling.segments);
        if !fresh
            || a.restarts >= MOST_RESTARTS
            || a.said_at.is_some_and(|said| said > since)
            || (committed.direct.is_none() && !self.own_words(committed).await?)
        {
            return Ok(());
        }
        self.start_over();
        Ok(())
    }

    /// Whether a row that isn't to Max isn't to anyone else either: it
    /// mentions nobody, and quotes nobody but its sender.
    async fn own_words(&self, committed: &ingest::Committed) -> Result<bool> {
        let Content::Message { reply_to, nodes } = &committed.message.content else {
            return Ok(false);
        };
        if nodes
            .iter()
            .any(|node| matches!(node, Node::Mention { .. }))
        {
            return Ok(false);
        }
        let Some(target) = reply_to else {
            return Ok(true);
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let row = ledger::row(&mut conn, self.place.conversation, *target).await?;
        Ok(row.is_some_and(|row| row.message.sender.identity == committed.sender.identity))
    }

    /// Takes back the model call in flight; the next step makes it again.
    fn start_over(&mut self) {
        let Some(a) = self.core.as_mut() else {
            return;
        };
        let Some(calling) = a.calling.take() else {
            return;
        };
        if let Err(rejected) = a.run.retract() {
            warn!(turn = %a.turn, %rejected, "couldn't take back a model call");
            a.calling = Some(calling);
            return;
        }
        calling.abort.abort();
        a.live.remove(&calling.task);
        a.restarts += 1;
        info!(conversation = %self.place.conversation, turn = %a.turn, restarts = a.restarts, "a model call starts over");
    }

    async fn decide(&mut self, decisions: Vec<Decision>) -> Result<()> {
        let mut decisions = VecDeque::from(decisions);
        while let Some(decision) = decisions.pop_front() {
            match decision {
                Decision::Wake { ids, reason } => {
                    if ids.iter().all(|id| *id <= self.seen) {
                        debug!(?ids, "dropped a wake for rows a model has seen");
                        continue;
                    }
                    let wake = Wake {
                        ids,
                        item: project::judged(&reason),
                        reason,
                    };
                    match self.core.as_mut() {
                        Some(a) => {
                            if let Err(rejected) = a.run.input(Input::Wake(wake)) {
                                warn!(turn = %a.turn, %rejected, "a wake didn't fit the core");
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

    /// Max's memory file, read from the host's side of /work as the guest
    /// left it, and shown as `project::memory` says; empty without one.
    async fn memory(&self) -> String {
        let Some(dir) = &self.shared.vm_dir else {
            return String::new();
        };
        let work = vm::work(dir, self.place.conversation);
        let file = Path::new(MEMORY_FILE)
            .strip_prefix("/work")
            .unwrap_or(Path::new(MEMORY_FILE))
            .to_path_buf();
        let read =
            tokio::task::spawn_blocking(move || mcp::work::read(&work, &file, MEMORY_FILE_BYTES));
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

    async fn start_core(&mut self, wake: Wake) -> Result<()> {
        if self.stopping.is_some() {
            return Ok(());
        }
        let settings = &self.settings;
        let chosen = self
            .shared
            .models
            .turn(settings.model.as_deref(), settings.effort.as_deref())?;
        let now = Utc::now();
        let persona = settings.persona.as_deref().unwrap_or(prompt::PERSONA);
        let vms = self.shared.vms.as_ref();
        let apis = vms.map_or("", |vms| vms.apis().prompt());
        let projection = Projection {
            place: &self.place,
            system: prompt::system(
                persona,
                &mcp::tool::DECLARATIONS,
                apis,
                vms.map(Vms::idle),
                vms.is_some_and(|vms| vms.operates(self.place.conversation)),
            ),
            window: chosen.window,
            cleared_upto: settings.cleared_upto,
            memory: self.memory().await,
            now,
            offset: self.shared.services.offset,
        };
        let from = self.head;
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
        let roster = context.roster.clone();
        info!(conversation = %self.place.conversation, turn = %started.turn, ordinal = started.ordinal, model = %chosen.reference(), base, "a core starts");
        self.core = Some(Active {
            turn: started.turn,
            ordinal: started.ordinal,
            run: Run::new(spec, context, inputs),
            chosen,
            io: Scope::new(),
            live: HashSet::new(),
            said: Vec::new(),
            segments: 0,
            calling: None,
            restarts: 0,
            said_at: None,
            roster,
            from,
            waiting: watch::Sender::new(false),
            last_at: Some(now),
            idle_since: Instant::now(),
            started: Instant::now(),
        });
        Ok(())
    }

    /// After every event: what the core does next, if nothing is in flight.
    async fn advance(&mut self) -> Result<()> {
        loop {
            let Some(a) = self.core.as_mut() else {
                return Ok(());
            };
            let waited_on = a.run.waited_on();
            a.waiting
                .send_if_modified(|was| std::mem::replace(was, waited_on) != waited_on);
            if a.run.busy() {
                return Ok(());
            }
            // Stopping, a core may finish what it is doing within the grace;
            // one with nothing to do ends now.
            if self.stopping.is_some() && a.run.idle() {
                self.end(End::Idle).await?;
                continue;
            }
            // Over its limits, the core gives up, and near them with
            // nothing to do, it ends; the next trigger starts a new one from
            // the ledger.
            if a.run.at_limit() || (a.run.idle() && a.run.near_limit()) {
                let how = if a.run.idle() {
                    End::Idle
                } else {
                    End::Failed(FailReason::ContextExhausted)
                };
                self.end(how).await?;
                continue;
            }
            match a.run.next_step() {
                Step::CallModel(request) => {
                    self.seen = self.head;
                    self.next_task += 1;
                    let task = TaskId(self.next_task);
                    a.live.insert(task);
                    let chosen = a.chosen.clone();
                    let mailbox = self.mailbox.clone();
                    let pictures = self.shared.pictures.clone();
                    let abort =
                        a.io.spawn(move |_| model::call(chosen, pictures, request, task, mailbox));
                    a.calling = Some(Calling {
                        task,
                        abort,
                        segments: a.segments,
                    });
                    return Ok(());
                }
                Step::RunTools(calls) => {
                    for call in calls {
                        self.next_task += 1;
                        let task = TaskId(self.next_task);
                        a.live.insert(task);
                        let vms = self.shared.vms.clone();
                        let context = mcp::Context {
                            services: Arc::clone(&self.shared.services),
                            place: Arc::clone(&self.place),
                            page_tokens: Budgets::for_window(a.chosen.window).single,
                            video: a.chosen.video,
                            work: None,
                            caller: mcp::Caller::Turn(Poster::new(self.mailbox.clone(), a.turn)),
                        };
                        let mailbox = self.mailbox.clone();
                        let waiting = a.waiting.subscribe();
                        a.io.spawn(move |_| tool::call(vms, context, call, task, mailbox, waiting));
                    }
                    return Ok(());
                }
                Step::Idle => return Ok(()),
            }
        }
    }

    async fn model_output(&mut self, out: ModelOutput, timing: Timing) -> Result<()> {
        let Some(a) = self.core.as_mut() else {
            return Ok(());
        };
        a.said.clear();
        a.idle_since = Instant::now();
        let used = out.usage;
        if let Err(rejected) = a.run.model_output(out) {
            warn!(turn = %a.turn, %rejected, "a model output didn't fit");
        }
        let call = a.chosen.usage(
            usage::Purpose::Turn,
            Some(self.place.conversation),
            Some(a.turn),
            used,
            Some(timing),
        );
        llm::record(&self.shared.services.pool, &call).await;
        Ok(())
    }

    async fn timer(&mut self) -> Result<()> {
        let now = Instant::now();
        if let Some(a) = &self.core {
            if self.stopping.is_some_and(|deadline| now >= deadline) {
                self.end(End::Stopped).await?;
            } else if a.run.idle() && now >= a.idle_since + a.chosen.idle_window {
                self.end(End::Idle).await?;
            }
        }
        let decisions = self.intent.tick(now.into_std());
        self.decide(decisions).await
    }

    /// Wakes Max with `item`: in the running core, or a new one.
    async fn wake_with(&mut self, reason: Reason, item: Item) -> Result<()> {
        let wake = Wake {
            ids: Vec::new(),
            reason,
            item: Some(item),
        };
        match self.core.as_mut() {
            Some(a) => {
                if let Err(rejected) = a.run.input(Input::Wake(wake)) {
                    warn!(turn = %a.turn, %rejected, "a wake didn't fit the core");
                }
            }
            None => self.start_core(wake).await?,
        }
        Ok(())
    }

    async fn end(&mut self, how: End) -> Result<()> {
        let Some(mut a) = self.core.take() else {
            return Ok(());
        };
        // Aborts the model call in flight: started now, not waited for.
        drop(a.io);
        if !a.said.is_empty() {
            let text = a.said.join("\n\n");
            let tokens = tokens::count(&text);
            if let Err(rejected) = a.run.partial_output(text, tokens) {
                warn!(turn = %a.turn, %rejected, "the partial output didn't fit");
            }
        }
        let applied = match &how {
            End::Kill(reason) => {
                info!(turn = %a.turn, reason, "killed");
                a.run.interrupt()
            }
            End::Stopped => a.run.interrupt(),
            End::Failed(reason) => a.run.fail(reason.clone()),
            End::Idle => Ok(()),
        };
        if let Err(rejected) = applied {
            warn!(turn = %a.turn, %rejected, "the ending didn't fit");
        }
        let outcome = a.run.outcome();
        let mut conn = self.shared.services.pool.acquire().await?;
        turns::finish(&mut conn, a.turn, &a.run.record(), &outcome, Utc::now()).await?;
        info!(turn = %a.turn, ?outcome, rounds = a.run.round(), warned = a.run.warned(), "the core ends");
        drop(conn);
        let why = match how {
            End::Failed(FailReason::Model { error }) => {
                failure("the model call failed", &error, &[])
            }
            End::Failed(FailReason::ContextExhausted) => {
                let (tokens, limit) = a.run.context_tokens();
                let reason = format!("{tokens} tokens, limit {limit}");
                failure("the context is full", &reason, &[])
            }
            End::Stopped => {
                let grace = self.shared.stop_grace;
                let reason =
                    format!("Max is shutting down, and the turn outlasted the {grace:?} grace");
                failure("interrupted", &reason, &[])
            }
            End::Kill(_) | End::Idle => return Ok(()),
        };
        self.report_unanswered(&a.run, &why).await
    }

    /// A short line under the latest direct trigger the run didn't get to;
    /// a judged wake goes unanswered, as Max may stay quiet anyway.
    async fn report_unanswered(&mut self, run: &Run, why: &str) -> Result<()> {
        let trigger = run
            .unhandled()
            .into_iter()
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

    /// Why a tool of `origin`'s can no longer act: its turn has ended, by
    /// `/kill` or otherwise, though its call was on the way. Only the
    /// running core's tools act so far; a program's, outside any turn,
    /// always do.
    fn ended(&self, origin: Option<TurnId>) -> Option<String> {
        let turn = origin?;
        if self.core.as_ref().is_some_and(|a| a.turn == turn) {
            return None;
        }
        debug!(%turn, "refused a tool of a turn that has ended");
        Some("这一轮已经结束了，没做".to_owned())
    }

    /// What a tool says or does: a running core's, whose programs' results
    /// tell the core what they did, or a program's Max keeps in the VM.
    async fn post(&mut self, post: Post) -> Result<()> {
        let Post {
            act,
            origin,
            receipt,
        } = post;
        if let Some(refused) = self.ended(origin) {
            if let Some(receipt) = receipt {
                let _ = receipt.send(Err(refused));
            }
            return Ok(());
        }
        let committed = match act {
            Act::Say(draft) => {
                let by = if origin.is_none() {
                    By::Program
                } else {
                    By::Max
                };
                self.say(draft, origin, None, by, receipt).await?
            }
            Act::Unsend(target) => self.unsend(target, origin, receipt).await?,
        };
        if let Some(at) = committed
            && let Some(a) = self.core.as_mut()
            && Some(a.turn) == origin
        {
            a.last_at = Some(at);
        }
        Ok(())
    }

    /// Commits what Max's account says, `by` whom, and hands it to the
    /// sender; when it was committed, if it was. The running core isn't fed it: its own words are in its
    /// transcript, and words from outside it, such as a command's answer,
    /// are in the next core's tail.
    async fn say(
        &mut self,
        draft: Draft,
        turn: Option<TurnId>,
        segment: Option<i32>,
        by: By,
        receipt: Option<Receipt>,
    ) -> Result<Option<DateTime<Utc>>> {
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
        Ok(self.hand_over(said, receipt, "没有能发的东西"))
    }

    /// Takes back `target`, as `say` says something.
    async fn unsend(
        &mut self,
        target: MessageId,
        turn: Option<TurnId>,
        receipt: Option<Receipt>,
    ) -> Result<Option<DateTime<Utc>>> {
        let mut conn = self.shared.services.pool.acquire().await?;
        let unsend = ingest::unsend(
            &mut conn,
            &self.place,
            target,
            turn,
            Utc::now(),
            self.shared.services.offset,
        )
        .await?;
        drop(conn);
        Ok(self.hand_over(unsend, receipt, "这里没有这条消息"))
    }

    /// A row of Max's that was committed, for the sender, and when it
    /// was; if none was, the receipt hears `why` at once.
    fn hand_over(
        &mut self,
        committed: Option<Message>,
        receipt: Option<Receipt>,
        why: &str,
    ) -> Option<DateTime<Utc>> {
        let Some(message) = committed else {
            if let Some(receipt) = receipt {
                let _ = receipt.send(Err(why.to_owned()));
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
        Some(at)
    }
}

/// `error` and its causes, `: ` between them, as `{:#}` has them; a
/// cause its error already ends with is left out, as sqlx's database
/// error ends with its source.
fn chain(error: &Report) -> String {
    let mut line = error.to_string();
    for cause in error.chain().skip(1) {
        let cause = cause.to_string();
        if !line.ends_with(&cause) {
            line.push_str(": ");
            line.push_str(&cause);
        }
    }
    line
}

/// What the host says when something fails, like a log, in a text code
/// block: `error: what: reason`, the reason as it came on one line, cut
/// when long; then the jobs stopped with it, if any.
fn failure(what: &str, reason: &str, stopped: &[u32]) -> String {
    let reason = reason.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut line = format!("error: {what}: ");
    line.extend(reason.chars().take(REASON_CHARS));
    if reason.chars().count() > REASON_CHARS {
        line.push('…');
    }
    if !stopped.is_empty() {
        let jobs: Vec<String> = stopped.iter().map(|job| format!("job#{job}")).collect();
        line.push_str("\nstopped: ");
        line.push_str(&jobs.join(", "));
    }
    command::fenced("text", &line)
}

mod commands;
mod jobs;
mod program;
#[cfg(test)]
mod tests;
mod woken;
