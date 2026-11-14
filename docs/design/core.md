# The core

## The core

Written in-house, sans-I/O (decided 2026-10-26). In 2026-10, rig, yoagent, adk-rust, autoagents, swiftide-agents, aisdk and genai were evaluated, as was pi-agent (a third-party Rust port; the official repository does not contain this code). Their common problem is that each brings its own provider layer or session layer, which conflicts with our own protocol adapters and ledger; they are also far larger than the part we would use: rig-core plus rig-agent come to about 130,000 lines, and yoagent to about 39,000. Writing our own is estimated at 1.2k–1.5k lines, including the adapters for both protocols. Two things are borrowed: rig-agent's `AgentRun`, which writes the loop as a sans-I/O state machine, and the steer semantics of pi and yoagent.

The core is a pure state machine: all its methods are synchronous, and each call is one complete state transition; it does not `await`, does not spawn, does not read the clock and does not touch the network. A sketch, with signatures **TBD**:

```rust
struct Run {
    spec: RunSpec,            // immutable: model profile, window, output limit, the Max tools available to this turn
    base: Context,            // immutable: the base context's entries and roster; the first batch of input is in its volatile block
    transcript: Vec<Item>,    // entries produced in this turn, append-only
    pending: Vec<Input>,      // accumulated messages and Wakes, rendered as one [新消息] ("new messages") block at the next model call
    phase: Phase,             // which phase it is in; each phase's own data lives in the phase, see below
    measured: Option<(u32, usize)>, // the provider-reported token count of the previous request plus its output, and how far into the transcript it covers
    unhandled: Vec<Wake>,     // Wakes since the last idle, the first batch's included: those the model has not finished handling
    roster: BTreeSet<PrincipalId>, // the base's roster, plus newcomers shown to the model since
    // plus round
}

// Changed 2026-10-29: previously five fields, in_flight, due, outstanding, model_due and ended, represented the phase together,
// and the legal combinations were maintained by hand (pointed out by the owner); now it is one enum, and illegal combinations cannot be written
enum Phase {
    ModelDue,                 // the next step is a model call: at the start, after all tool results are back, after a call is interrupted, when there are malformed calls, when a trigger arrives
    Calling,                  // a model call is in flight
    ToolsDue(Vec<Call>),      // well-formed tool calls from the previous output that have not started yet
    Running(Vec<CallId>),     // a tool batch is in flight: the calls that have not returned yet, never empty
    Waiting,                  // nothing in flight and nothing due: ending now loses nothing
    Interrupted,
    Failed(FailReason),
}

enum Step {
    CallModel(Request),       // the request is built in full by the core and not modified afterwards: entries, the two tools, output limit, roster
    RunTools(Vec<Call>),      // calls already parsed into run_code or shell
    Idle,                     // nothing in flight and nothing due; the actor decides whether to wait or to end
}

impl Run {
    fn new(spec: RunSpec, base: Context, first: Vec<Input>) -> Self;
    fn record(&self) -> RunRecord<'_>;              // serialises by borrowing the core's data, without copying
    fn busy(&self) -> bool;                         // a model call or tool is in flight; the actor asks for next_step only when this is false
    fn next_step(&mut self) -> Step;                // starts a call or a batch, and the phase changes accordingly
    fn model_output(&mut self, out: ModelOutput) -> Result<(), Rejected>;
    fn partial_output(&mut self, text: String, tokens: u32) -> Result<(), Rejected>;
    fn tool_result(&mut self, call: CallId, out: ToolOutput) -> Result<(), Rejected>;
    fn input(&mut self, input: Input) -> Result<(), Rejected>; // accepts only Messages and Wake, at any time; the core decides when they take effect
    fn interrupt(&mut self) -> Result<(), Rejected>; // who issued the /kill is recorded in the log
    fn fail(&mut self, reason: FailReason) -> Result<(), Rejected>;
    fn at_limit(&self) -> bool;                     // the transcript plus accumulated input exceeds the limit; the actor ends the core at a boundary
    fn unhandled(&self) -> Vec<Wake>;               // triggers not fully handled; on failure or interruption, used to find the one that gets a one-line reply
    fn idle(&self) -> bool;                         // nothing in flight and nothing due: ending now loses nothing
    fn outcome(&self) -> Outcome;                   // read by the actor at the end
}
```

- Anything inconsistent with the state (a `ModelOutput` that arrives when no model call is in flight, the result of an unknown call, any input after the end) returns `Rejected` and changes nothing.
- Messages that arrive while a model call is in flight do not belong to that request; they wait for the next one (decided 2026-10-28). Originally, so that replay could tell them apart, starting a call and starting a tool batch were each recorded as an input; since replay was dropped (2026-10-29), these are simply phase transitions inside `next_step`.

Rules for which the core is responsible:

- **Building requests**: a request consists of the base context, the transcript and the two fixed tools, and is not trimmed (decided 2026-10-28). Individual inputs and tool results each have a cap (see [Follow-up input](context.md#follow-up-input)); the overall size is governed by the limit below, and hitting the limit ends the run, so a request never exceeds the window. The only exception is images: when they exceed the vision budget, the earlier ones are omitted; see [Multimodal results](tools.md#multimodal-results).
- **Tools**: `run_code` and `shell`, which never change. Which Max tools programs can call is determined by the spec and stays the same for the whole turn; loading a skill does not change it either; see [Pure codemode](tools.md#pure-codemode). A malformed call gets an error result straight away and is not handed to the actor for execution.
- **Token counts are data** (decided 2026-10-28): the core does not estimate tokens. The base context, each input and each tool result come in carrying token counts already estimated by `max`; model output uses the usage returned by the provider. Size is calculated from the input tokens the provider reported for the previous request, plus the entries added since, so estimation error falls only on that increment. The counts are stored in the snapshot along with the entries. When the provider reports no usage (input is 0), this is not taken as a measurement, and accumulation continues from the previous measurement or estimate (changed 2026-10-30, found in review: previously everything before was treated as 0, and the core could never reach the limit).
- **Round and token limits** (changed 2026-10-28):

  ```
  available  = C − output reserve − margin
  core limit = min(available − base context, C / 2)
  ```

  C is the model's window; the output reserve is the model's configured `max_output`, or C / 8 if it is not set (the Haskell version's approach); the margin absorbs estimation error and is proposed at 5% of C. When the transcript plus accumulated input exceeds the core limit and the model has also seen the nearly-full reminder described below, `at_limit` becomes true, and the actor ends the run at the next boundary: if the core is idle, this counts as a normal end; otherwise `Failed(ContextExhausted)` is recorded, and the unhandled direct triggers get a one-line reply (changed 2026-10-29; previously the unhandled triggers were handed to a new core; see step 4 of [Processing flow](actor.md#processing-flow)). When the base context alone fills the available space, the limit is 0, which likewise counts as hitting the limit. The limit takes accumulated input into account, so a request cannot overflow. Example: for a model with a 400k window and a 128k `max_output`, about 252k is available, and with a 100k base context the core limit is 152k; calculating by C / 2 alone would give 200k, and the request would exceed the 272k of input that the provider allows.
- **Definition of handled**: once the model has seen an input, that input is handled when the model reaches an output with no tool calls and the core becomes idle, whether or not it replied. When a model that has seen the nearly-full reminder says something, what it has seen also counts as handled; see below. The mark is set at the moment the core becomes idle, without waiting for the actor's next `next_step` call. `unhandled` returns the triggers among the first batch and the inputs passed in later that are not yet handled (`Wake`, and later job results and automations); messages are not included, since they are in the ledger. When the core fails or is interrupted, the actor uses it to find the direct triggers that get a one-line reply; see [What the group sees](actor.md#what-the-group-sees).
- **Timing of input**: after all results of the current tool batch are back, and before the next model call. A batch of input causes a model call only if it contains a trigger (`Wake`, job result, automation). Messages themselves are not triggers; when to wake is decided by [Intent](intent.md#intent-1); when there are only messages, they are kept and go in with the next model call.
- **Reminder after working heads-down for too long** (2026-10-31): when the model has called tools 12 times in a row without saying a word in the group (output from which the segmenter cuts no message does not count, nor does `[silence]`), a `[maxx 提醒]` ("maxx reminder") section is appended after the last result of that tool batch: first say in the group what it is doing and how much longer it will take; if much work remains, hand it to a background agent; answer anyone who is waiting first. Saying something resets the count, and so does a reminder, so another reminder comes after a further 12 calls. The reason: on 2026-10-31, a turn in conversation 9 was asked to turn the previous night's changes into a PR; it installed dependencies, ran tests and changed code directly within the turn, made 49 tool calls and took 41 minutes before saying its first word, and did not answer two people who @-mentioned it in the meantime.
- **Nearly-full reminder** (2026-11-01, proposed by the owner): when the transcript plus accumulated input passes 90% of the core limit (`near_limit`), a `[maxx 提醒]` is appended at the end before the next model call, at most once per run: the context is nearly used up; wrap up now, and say clearly in the group how far it got, what it found and what remains; the next turn cannot see this turn's tool results, only what was said in the group; if the remaining work is to continue, hand it to a background agent, and call no other tools.
  - After the reminder has been given, `at_limit` holds only once the limit is exceeded. If no reminder has been given and a batch of tool results jumps straight from below 90% to beyond the limit, this one call carrying the reminder is still made first: on a model with a small window, the gap between 90% and the limit is only a few thousand tokens, while a single result can be up to 15% of C. This call uses the headroom: the output reserve plus 5% of C.
  - When a reminded model says something, the triggers it has seen count as handled, even if the same output also calls tools (to hand over to an agent). That way, if it hits the limit after reporting progress and handing the work over, it does not add an error message saying that the context is full.
  - If the core passes 90% while idle, it ends at once, without waiting for the idle window; the next trigger starts a new core, projected afresh from the ledger.
  - The reason: a turn that hit the limit replied only with a single line, "读不完" ("too much to get through"), everything its tools had found was lost, and the next turn could see only what was said in the group. Up to 2026-11-01, not one of 392 turns had hit the limit: on a 1M window the core limit is about 524k, and the turn that grew the most grew by 176k. The reminder mainly guards against models with small windows, and against very long tasks in future.
- **Interruption**: tool calls that have not returned get a "已取消" ("cancelled") result filled in, so that the history stays valid. Responses requires every `function_call` to have a corresponding output.
- **Idle detection**: when the model's output in this round is text only, with no tool calls, and the accumulated input contains no trigger, `next_step` returns `Idle`. Ending is decided by the actor: expiry of the idle window, hitting the limit, `/kill`, failure, restart. If the whole run never said anything, the outcome is `Silent`; whether something was said is determined by running the model's text through the segmenter: if a message is cut out, it counts.

## I/O tasks and protocol adapters

The conversation actor spawns the I/O that the core needs as tasks, attached to that core's `io` scope, and their results return to the actor's mailbox as events (decided 2026-10-28; see [The conversation actor](actor.md#the-conversation-actor-1)). Tasks share no mutable state with one another or with the actor.

- **Model calls**: one task per `CallModel`. It holds the model client and the segmenter: it hands the request to the protocol adapter layer to be downgraded into the wire format, sends it and reads the stream; each time a segment is cut from the streamed text it sends `Said`, and when the stream ends it sends `ModelDone`. Retryable errors are retried within the task, provided that no `Said` has been sent yet; once one has been sent, there is no retry and the error is reported straight away, and the text already entered in the ledger is recorded by the actor as `partial_output` (decided 2026-10-28). Otherwise a retry would send the paragraphs already sent all over again from the beginning, which is most likely to happen during evening packet loss. As soon as a `run_code` or `shell` call appears in the stream, the VM service is notified to start the group VM.
- **`run_code` and `shell`**: one task per call, run in the group VM, sending `ToolDone` when finished. Several calls in the same batch run concurrently, and whichever finishes first is fed to the core first.
- **Intent classification**: attached to `side`, sending `Verdict` when finished; see [Intent](intent.md#intent-1).
- **Receipts**: each task holds a receipt (`Report`); on normal completion it uses it to send its completion event, and if the task is aborted or panics, the receipt sends a "no result" event from its `Drop`. Every task therefore has exactly one completion event, which goes through the same mailbox as its `Said` events and is queued after them.
- **Stale events**: each task has a number that increases within the conversation and is never reused, and all its events carry it. Events from a task that is not in flight for the current core (events arriving after the core has ended) are simply dropped.

The protocol adapter layer is stateless and retains nothing between calls. Downgrading only removes entries or adjusts their shape; it never adds content:

- An `opaque` whose `source` does not match the current model is simply dropped. The model within a turn is fixed by the spec, so the two always match under normal circumstances; this rule is only a safety net.
- **Responses**: all reasoning entries from the current turn are sent back.
- **Chat**: several entries from the same round are joined back into one assistant message; `reasoning_content` is sent back within the current turn's tool-call loop.
- For how images and videos in tool results are downgraded, see [Multimodal results](tools.md#multimodal-results).
