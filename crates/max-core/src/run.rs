//! The core: a sans-I/O state machine that decides what a turn does next.
//! Every method is synchronous and one complete transition; nothing here
//! awaits, spawns, reads the clock or touches the network.
//!
//! It keeps what the model is shown: the base context, and the transcript
//! after it. That is also what a run leaves behind, its [`RunRecord`]; the
//! inputs that led there aren't kept, and nothing rebuilds a run from them.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

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

/// What comes in besides the model's output and the tools' results.
/// Neither is a trigger by itself: they wait for the next model call.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Input {
    /// New rows on the timeline.
    Messages {
        ids: Vec<MessageId>,
        item: Item,
        /// People the core hasn't seen yet; `item` carries their roster
        /// lines. Once the model sees them, it can mention them.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        people: Vec<PrincipalId>,
    },
    /// A wake makes a model call due.
    Wake(Wake),
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

/// A call that doesn't fit the core's state. Nothing changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Rejected {
    #[error("the run has ended")]
    Ended,
    #[error("no model call is in flight")]
    NoModelCall,
    #[error("no such tool call is in flight")]
    UnknownCall,
}

/// What a run leaves behind: what the model was shown and what it said.
/// Each model call's request was the base and the transcript up to that
/// call's output.
#[derive(Debug, Serialize)]
pub struct RunRecord<'a> {
    pub spec: &'a RunSpec,
    pub base: &'a Context,
    pub transcript: &'a [Item],
}

/// Tokens counted for a result the core writes itself. They are short, and
/// the core has no tokenizer.
const SYNTHESIZED_TOKENS: u32 = 50;

#[derive(Clone, Debug)]
pub struct Run {
    spec: RunSpec,
    base: Context,
    base_tokens: u32,
    transcript: Vec<Item>,
    /// Inputs since the last model call; the next one shows them.
    pending: Vec<Input>,
    phase: Phase,
    round: u32,
    /// The provider's count for the last request and its output, and how
    /// much of the transcript that covers. A provider that doesn't count
    /// leaves the one before.
    measured: Option<(u32, usize)>,
    /// The wakes since the run was last waiting, the first ones included:
    /// the model hasn't finished with them.
    unhandled: Vec<Wake>,
    /// The base roster and everyone shown since.
    roster: BTreeSet<PrincipalId>,
}

/// Where the run is. Each phase holds what only it has.
#[derive(Clone, Debug)]
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
    /// `first` is already rendered in `base`; its wakes are the run's
    /// first to handle.
    pub fn new(spec: RunSpec, base: Context, first: Vec<Input>) -> Self {
        let base_tokens = base.items.iter().map(|item| item.tokens).sum();
        let roster = base.roster.clone();
        let unhandled = first
            .into_iter()
            .filter_map(|input| match input {
                Input::Wake(wake) => Some(wake),
                Input::Messages { .. } => None,
            })
            .collect();
        Self {
            spec,
            base,
            base_tokens,
            transcript: Vec::new(),
            pending: Vec::new(),
            phase: Phase::ModelDue,
            round: 0,
            measured: None,
            unhandled,
            roster,
        }
    }

    /// A model call or tool batch is in flight. The actor asks for the next
    /// step only when this is false.
    pub fn busy(&self) -> bool {
        matches!(self.phase, Phase::Calling | Phase::Running(_))
    }

    pub fn next_step(&mut self) -> Step {
        match std::mem::replace(&mut self.phase, Phase::Waiting) {
            Phase::ToolsDue(calls) => {
                self.phase = Phase::Running(calls.iter().map(|call| call.id.clone()).collect());
                Step::RunTools(calls)
            }
            Phase::ModelDue => {
                self.show_pending();
                self.round += 1;
                self.phase = Phase::Calling;
                Step::CallModel(Request {
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
                })
            }
            phase => {
                self.phase = phase;
                Step::Idle
            }
        }
    }

    /// The model's output joins the transcript. Its well-formed calls are
    /// due next, and a malformed one gets an error result here.
    pub fn model_output(&mut self, out: ModelOutput) -> Result<(), Rejected> {
        self.calling()?;
        // No request is empty: a count of nothing is no count, and taking it
        // would drop everything before it from the size.
        if out.usage.input > 0 {
            self.measured = Some((
                out.usage.input + out.usage.output,
                self.transcript.len() + out.items.len(),
            ));
        }
        let mut due = Vec::new();
        let mut errors = Vec::new();
        for item in &out.items {
            if let ItemKind::ToolCall(call) = &item.kind {
                match tools::parse(call) {
                    Ok(call) => due.push(call),
                    Err(error) => errors.push((call.id.clone(), error)),
                }
            }
        }
        self.transcript.extend(out.items);
        let malformed = !errors.is_empty();
        for (call, error) in errors {
            self.synthesize(call, error);
        }
        self.phase = if !due.is_empty() {
            Phase::ToolsDue(due)
        } else if malformed || self.trigger_pending() {
            Phase::ModelDue
        } else {
            // The model is through with every wake it saw.
            self.unhandled.clear();
            Phase::Waiting
        };
        Ok(())
    }

    /// The model call was cut off; `text` had already been said.
    pub fn partial_output(&mut self, text: String, tokens: u32) -> Result<(), Rejected> {
        self.calling()?;
        if !text.is_empty() {
            self.transcript
                .push(Item::new(ItemKind::Assistant { text }, tokens));
        }
        self.phase = Phase::ModelDue;
        Ok(())
    }

    pub fn tool_result(&mut self, call: CallId, output: ToolOutput) -> Result<(), Rejected> {
        self.open()?;
        let Phase::Running(open) = &mut self.phase else {
            return Err(Rejected::UnknownCall);
        };
        let Some(at) = open.iter().position(|id| *id == call) else {
            return Err(Rejected::UnknownCall);
        };
        open.remove(at);
        if open.is_empty() {
            self.phase = Phase::ModelDue;
        }
        let tokens = output.tokens;
        self.transcript
            .push(Item::new(ItemKind::ToolResult { call, output }, tokens));
        Ok(())
    }

    /// New rows or a wake, at any time. The core decides when they take
    /// effect: after the tool batch in flight, before the next model call.
    pub fn input(&mut self, input: Input) -> Result<(), Rejected> {
        self.open()?;
        if let Input::Wake(wake) = &input {
            self.unhandled.push(wake.clone());
            if matches!(self.phase, Phase::Waiting) {
                self.phase = Phase::ModelDue;
            }
        }
        self.pending.push(input);
        Ok(())
    }

    pub fn interrupt(&mut self) -> Result<(), Rejected> {
        self.end(Phase::Interrupted)
    }

    pub fn fail(&mut self, reason: FailReason) -> Result<(), Rejected> {
        self.end(Phase::Failed(reason))
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
        self.unhandled.clone()
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
        matches!(self.phase, Phase::Waiting)
    }

    pub fn round(&self) -> u32 {
        self.round
    }

    pub fn record(&self) -> RunRecord<'_> {
        RunRecord {
            spec: &self.spec,
            base: &self.base,
            transcript: &self.transcript,
        }
    }

    /// Ok while the run hasn't ended.
    fn open(&self) -> Result<(), Rejected> {
        match self.phase {
            Phase::Interrupted | Phase::Failed(_) => Err(Rejected::Ended),
            _ => Ok(()),
        }
    }

    fn calling(&self) -> Result<(), Rejected> {
        self.open()?;
        match self.phase {
            Phase::Calling => Ok(()),
            _ => Err(Rejected::NoModelCall),
        }
    }

    /// The open calls get a result here; the run takes no more.
    fn end(&mut self, ended: Phase) -> Result<(), Rejected> {
        self.open()?;
        let open: Vec<CallId> = match std::mem::replace(&mut self.phase, ended) {
            Phase::ToolsDue(calls) => calls.into_iter().map(|call| call.id).collect(),
            Phase::Running(open) => open,
            _ => Vec::new(),
        };
        for call in open {
            self.synthesize(call, "已取消".to_owned());
        }
        Ok(())
    }

    /// Puts the waiting inputs into the transcript as one `[新消息]` block.
    fn show_pending(&mut self) {
        let items: Vec<&Item> = self
            .pending
            .iter()
            .filter_map(|input| match input {
                Input::Messages { item, .. } => Some(item),
                Input::Wake(wake) => wake.item.as_ref(),
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
