//! The core: a sans-I/O state machine that decides what a turn does next.
//! Every method is synchronous and one complete transition; nothing here
//! awaits, spawns, reads the clock or touches the network.
//!
//! Every input method builds an [`Input`] and applies it, and the core keeps
//! the inputs. A snapshot is that log, and replaying it rebuilds the core
//! exactly. Starting a model call or a tool batch is logged too, so replay
//! knows which inputs a call saw. What the core makes up itself, such as the
//! results it fills in for cancelled calls, isn't logged; replay makes it
//! again.

mod record;

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

pub use record::{CORE_VERSION, ReplayError, RunRecord};

use crate::ids::{CallId, MessageId, PrincipalId};
use crate::intent::Reason;
use crate::item::{Item, ItemKind, ModelOutput, ModelTag, ToolOutput};
use crate::segment::Segmenter;
use crate::tools::{self, Call, TOOLS, ToolSpec};

/// What a run is allowed: fixed for the turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunSpec {
    pub model: ModelTag,
    /// The model's context window, C.
    pub window: u32,
    /// The model's output limit; reserves C / 8 when it has none.
    pub max_output: Option<u32>,
}

impl RunSpec {
    /// How big transcript and waiting inputs may grow before the core gives
    /// up: the window minus output, a 5% margin and the base context,
    /// and never more than half the window.
    pub fn limit(&self, base: u32) -> u32 {
        let c = self.window;
        let available = c
            .saturating_sub(self.max_output.unwrap_or(c / 8))
            .saturating_sub(c / 20);
        available.saturating_sub(base).min(c / 2)
    }
}

/// Projected once before the core starts, then fixed. The first inputs are
/// already rendered in it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Context {
    pub items: Vec<Item>,
    /// The people its roster shows; see [`Segmenter`].
    pub roster: BTreeSet<PrincipalId>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Input {
    /// The core started a model call.
    CalledModel,
    /// The core started the tool calls from the last model output.
    RanTools,
    ModelOutput(ModelOutput),
    /// The model call was cut off; `text` had already been said.
    PartialOutput {
        text: String,
        tokens: u32,
    },
    ToolResult {
        call: CallId,
        output: ToolOutput,
    },
    /// New rows on the timeline. Not a trigger: they wait for the next
    /// model call.
    Messages {
        ids: Vec<MessageId>,
        item: Item,
        /// People the core hasn't seen yet; `item` carries their roster
        /// lines. Once the model sees them, it can mention them.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        people: Vec<PrincipalId>,
    },
    Wake(Wake),
    Interrupt {
        reason: String,
    },
    Fail {
        reason: FailReason,
    },
}

/// intent woke the core.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Wake {
    /// The rows it is about.
    pub ids: Vec<MessageId>,
    pub reason: Reason,
    /// What the model is shown, such as `[判定：在追问]`. None for a
    /// direct trigger, whose rows are marked already.
    pub item: Option<Item>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FailReason {
    Model {
        error: String,
    },
    /// The core grew past its limit, or its first inputs alone are over
    /// it.
    ContextExhausted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Outcome {
    Answered,
    Silent,
    Interrupted,
    Failed {
        reason: FailReason,
    },
    /// Running when the process crashed.
    Lost,
}

#[derive(Debug)]
pub enum Step {
    /// The request is complete; nothing changes it afterwards.
    CallModel(Request),
    RunTools(Vec<Call>),
    /// Nothing to do until something arrives. Whether to wait or end is the
    /// actor's call.
    Idle,
}

#[derive(Debug)]
pub struct Request {
    pub model: ModelTag,
    pub items: Vec<Item>,
    pub tools: &'static [ToolSpec],
    pub max_output: Option<u32>,
    /// For the segmenter in the model call.
    pub roster: BTreeSet<PrincipalId>,
}

/// An input that doesn't fit the core's state. It is not applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Rejected {
    #[error("the run has ended")]
    Ended,
    #[error("a model call or tool batch is in flight")]
    Busy,
    #[error("the tool calls are due first")]
    ToolsDue,
    #[error("nothing of the kind is due")]
    NothingDue,
    #[error("no model call is in flight")]
    NoModelCall,
    #[error("no such tool call is in flight")]
    UnknownCall,
    #[error("only messages and wakes come in through input()")]
    NotAnInput,
}

/// Tokens counted for a result the core writes itself. They are short, and
/// the core has no tokenizer.
const SYNTHESIZED_TOKENS: u32 = 50;

#[derive(Clone, Debug, PartialEq)]
pub struct Run {
    spec: RunSpec,
    base: Context,
    base_tokens: u32,
    first: Vec<Input>,
    log: Vec<Input>,
    transcript: Vec<Item>,
    /// Inputs since the last model call; the next one shows them.
    pending: Vec<Input>,
    phase: Phase,
    round: u32,
    /// The provider's count for the last request and its output, and how
    /// much of the transcript that covers.
    measured: Option<(u32, usize)>,
    /// The log's length when the core last went idle: every input before
    /// that is handled.
    handled: Option<usize>,
    /// The base roster and everyone shown since.
    roster: BTreeSet<PrincipalId>,
}

/// Where the run is. Each phase holds what only it has.
#[derive(Clone, Debug, PartialEq)]
enum Phase {
    /// A model call is next: at the start, after the tool results, after
    /// a cut-off call or a malformed tool call, and when a trigger comes.
    ModelDue,
    Calling,
    /// The well-formed calls from the last model output, not started yet.
    ToolsDue(Vec<Call>),
    /// A tool batch in flight: the calls without a result, never none.
    Running(Vec<CallId>),
    /// Nothing in flight and nothing due: ending the run now loses nothing.
    Waiting,
    Interrupted,
    Failed(FailReason),
}

impl Run {
    pub fn new(spec: RunSpec, base: Context, first: Vec<Input>) -> Self {
        let base_tokens = base.items.iter().map(|item| item.tokens).sum();
        let roster = base.roster.clone();
        Self {
            spec,
            base,
            base_tokens,
            first,
            log: Vec::new(),
            transcript: Vec::new(),
            pending: Vec::new(),
            phase: Phase::ModelDue,
            round: 0,
            measured: None,
            handled: None,
            roster,
        }
    }

    /// A model call or tool batch is in flight. The actor asks for the next
    /// step only when this is false.
    pub fn busy(&self) -> bool {
        matches!(self.phase, Phase::Calling | Phase::Running(_))
    }

    pub fn next_step(&mut self) -> Step {
        match &self.phase {
            Phase::ToolsDue(calls) => {
                let calls = calls.clone();
                self.record(Input::RanTools);
                Step::RunTools(calls)
            }
            Phase::ModelDue => {
                self.record(Input::CalledModel);
                Step::CallModel(self.request())
            }
            _ => Step::Idle,
        }
    }

    /// The model call that starts now.
    fn request(&self) -> Request {
        Request {
            model: self.spec.model.clone(),
            items: self
                .base
                .items
                .iter()
                .chain(&self.transcript)
                .cloned()
                .collect(),
            tools: &TOOLS,
            max_output: self.spec.max_output,
            roster: self.roster.clone(),
        }
    }

    pub fn model_output(&mut self, out: ModelOutput) -> Result<(), Rejected> {
        self.apply(Input::ModelOutput(out))
    }

    pub fn partial_output(&mut self, text: String, tokens: u32) -> Result<(), Rejected> {
        self.apply(Input::PartialOutput { text, tokens })
    }

    pub fn tool_result(&mut self, call: CallId, output: ToolOutput) -> Result<(), Rejected> {
        self.apply(Input::ToolResult { call, output })
    }

    /// New rows or a wake, at any time. The core decides when they take
    /// effect: after the tool batch in flight, before the next model call.
    pub fn input(&mut self, input: Input) -> Result<(), Rejected> {
        match input {
            Input::Messages { .. } | Input::Wake(_) => self.apply(input),
            _ => Err(Rejected::NotAnInput),
        }
    }

    pub fn interrupt(&mut self, reason: String) -> Result<(), Rejected> {
        self.apply(Input::Interrupt { reason })
    }

    pub fn fail(&mut self, reason: FailReason) -> Result<(), Rejected> {
        self.apply(Input::Fail { reason })
    }

    /// Transcript and waiting inputs are over the limit, or the first inputs
    /// alone leave no room. The actor ends the run there.
    pub fn at_limit(&self) -> bool {
        let limit = self.spec.limit(self.base_tokens);
        limit == 0 || self.size() > self.base_tokens + limit
    }

    /// The wakes the model hasn't finished with: seen by a model call that
    /// didn't reach an output without tool calls, or not seen yet.
    pub fn unhandled(&self) -> Vec<Wake> {
        let first = if self.handled.is_none() {
            &self.first[..]
        } else {
            &[]
        };
        let since = &self.log[self.handled.unwrap_or(0)..];
        first
            .iter()
            .chain(since)
            .filter_map(|input| match input {
                Input::Wake(wake) => Some(wake.clone()),
                _ => None,
            })
            .collect()
    }

    /// For a run that has ended or is idle.
    pub fn outcome(&self) -> Outcome {
        match &self.phase {
            Phase::Interrupted => Outcome::Interrupted,
            Phase::Failed(reason) => Outcome::Failed {
                reason: reason.clone(),
            },
            _ if self.said() => Outcome::Answered,
            _ => Outcome::Silent,
        }
    }

    /// The core is waiting for nothing and has nothing to do: ending it now
    /// loses nothing.
    pub fn idle(&self) -> bool {
        self.phase == Phase::Waiting
    }

    pub fn round(&self) -> u32 {
        self.round
    }

    fn apply(&mut self, input: Input) -> Result<(), Rejected> {
        self.check(&input)?;
        self.record(input);
        Ok(())
    }

    fn check(&self, input: &Input) -> Result<(), Rejected> {
        use Phase::{Calling, Failed, Interrupted, ModelDue, Running, ToolsDue, Waiting};
        match (input, &self.phase) {
            (_, Interrupted | Failed(_)) => Err(Rejected::Ended),
            (Input::CalledModel | Input::RanTools, Calling | Running(_)) => Err(Rejected::Busy),
            (Input::CalledModel, ToolsDue(_)) => Err(Rejected::ToolsDue),
            (Input::CalledModel, Waiting) | (Input::RanTools, ModelDue | Waiting) => {
                Err(Rejected::NothingDue)
            }
            (Input::ModelOutput(_) | Input::PartialOutput { .. }, phase) if *phase != Calling => {
                Err(Rejected::NoModelCall)
            }
            (Input::ToolResult { call, .. }, Running(open)) if open.contains(call) => Ok(()),
            (Input::ToolResult { .. }, _) => Err(Rejected::UnknownCall),
            _ => Ok(()),
        }
    }

    /// Applies an input that fits and logs it.
    fn record(&mut self, input: Input) {
        let phase = std::mem::replace(&mut self.phase, Phase::Waiting);
        self.phase = match (&input, phase) {
            (Input::CalledModel, _) => {
                self.show_pending();
                self.round += 1;
                Phase::Calling
            }
            (Input::RanTools, Phase::ToolsDue(calls)) => {
                Phase::Running(calls.into_iter().map(|call| call.id).collect())
            }
            (Input::ModelOutput(out), _) => self.output(out),
            (Input::PartialOutput { text, tokens }, _) => {
                if !text.is_empty() {
                    let text = text.clone();
                    self.transcript
                        .push(Item::new(ItemKind::Assistant { text }, *tokens));
                }
                Phase::ModelDue
            }
            (Input::ToolResult { call, output }, Phase::Running(mut open)) => {
                self.transcript.push(Item::new(
                    ItemKind::ToolResult {
                        call: call.clone(),
                        output: output.clone(),
                    },
                    output.tokens,
                ));
                open.retain(|id| id != call);
                if open.is_empty() {
                    Phase::ModelDue
                } else {
                    Phase::Running(open)
                }
            }
            (Input::Messages { .. }, phase) => {
                self.pending.push(input.clone());
                phase
            }
            (Input::Wake(_), phase) => {
                self.pending.push(input.clone());
                match phase {
                    Phase::Waiting => Phase::ModelDue,
                    phase => phase,
                }
            }
            (Input::Interrupt { .. }, phase) => {
                self.cancel(phase);
                Phase::Interrupted
            }
            (Input::Fail { reason }, phase) => {
                self.cancel(phase);
                Phase::Failed(reason.clone())
            }
            // `check` turns the rest away.
            (_, phase) => phase,
        };
        self.log.push(input);
        if self.idle() {
            self.handled = Some(self.log.len());
        }
    }

    /// The model's output joins the transcript; its well-formed calls are
    /// due, and a malformed one gets an error result here.
    fn output(&mut self, out: &ModelOutput) -> Phase {
        self.transcript.extend(out.items.iter().cloned());
        self.measured = Some((out.usage.input + out.usage.output, self.transcript.len()));
        let mut due = Vec::new();
        let mut malformed = false;
        for item in &out.items {
            if let ItemKind::ToolCall(call) = &item.kind {
                match tools::parse(call) {
                    Ok(call) => due.push(call),
                    Err(error) => {
                        self.synthesize(call.id.clone(), error);
                        malformed = true;
                    }
                }
            }
        }
        if !due.is_empty() {
            Phase::ToolsDue(due)
        } else if malformed || self.trigger_pending() {
            Phase::ModelDue
        } else {
            Phase::Waiting
        }
    }

    /// An interrupted or failed run's open calls get a result here.
    fn cancel(&mut self, phase: Phase) {
        let open: Vec<CallId> = match phase {
            Phase::ToolsDue(calls) => calls.into_iter().map(|call| call.id).collect(),
            Phase::Running(open) => open,
            _ => Vec::new(),
        };
        for call in open {
            self.synthesize(call, "已取消".to_owned());
        }
    }

    /// Puts the waiting inputs into the transcript as one `[新消息]` block.
    fn show_pending(&mut self) {
        let items: Vec<&Item> = self
            .pending
            .iter()
            .filter_map(|input| match input {
                Input::Messages { item, .. } => Some(item),
                Input::Wake(wake) => wake.item.as_ref(),
                _ => None,
            })
            .collect();
        for input in &self.pending {
            if let Input::Messages { people, .. } = input {
                self.roster.extend(people);
            }
        }
        if !items.is_empty() {
            let mut text = "[新消息]".to_owned();
            let mut images = Vec::new();
            for item in &items {
                if let ItemKind::User {
                    text: line,
                    images: more,
                } = &item.kind
                {
                    text.push('\n');
                    text.push_str(line);
                    images.extend(more);
                }
            }
            let tokens = items.iter().map(|item| item.tokens).sum();
            self.transcript
                .push(Item::new(ItemKind::User { text, images }, tokens));
        }
        self.pending.clear();
    }

    fn synthesize(&mut self, call: CallId, error: String) {
        let output = ToolOutput::text(error, true, SYNTHESIZED_TOKENS);
        self.transcript.push(Item::new(
            ItemKind::ToolResult { call, output },
            SYNTHESIZED_TOKENS,
        ));
    }

    fn trigger_pending(&self) -> bool {
        self.pending
            .iter()
            .any(|input| matches!(input, Input::Wake(_)))
    }

    /// The provider's last count plus everything after it, waiting inputs
    /// included; before the first call, the estimates alone.
    fn size(&self) -> u32 {
        let (measured, covered) = self.measured.unwrap_or((self.base_tokens, 0));
        let after: u32 = self.transcript[covered..]
            .iter()
            .map(|item| item.tokens)
            .sum();
        let pending: u32 = self
            .pending
            .iter()
            .map(|input| match input {
                Input::Messages { item, .. } => item.tokens,
                Input::Wake(wake) => wake.item.as_ref().map_or(0, |item| item.tokens),
                _ => 0,
            })
            .sum();
        measured + after + pending
    }

    /// Whether anything the model wrote went out: text that the segmenter
    /// turns into a message or a reaction.
    fn said(&self) -> bool {
        self.transcript.iter().any(|item| match &item.kind {
            ItemKind::Assistant { text } => {
                let mut segmenter = Segmenter::new(self.roster.clone());
                let mut segments = segmenter.push(text);
                segments.extend(segmenter.finish());
                !segments.is_empty()
            }
            _ => false,
        })
    }
}

#[cfg(test)]
mod tests;
