# Intent

Intent decides when to wake the core. **Every inbound message goes
through it**, @s and replies included, so it sees everything, and the
rules and the small model's classification are in one place. What is left
is deliberately small: the rule for direct triggers, the small model, and
an hourly cap; why it has no gates or signals beside is in
[decisions/rare-cases-fail-plainly.md](../decisions/rare-cases-fail-plainly.md).

Like [the core](core.md), intent is a pure state machine in `max-core`
(`intent.rs`), a field of the conversation actor:

```rust
// Synchronous, no I/O, no clock: the actor passes the time in
impl Intent {
    pub fn observe(&mut self, entry: &Entry) -> Vec<Decision>; // every row entered: others' messages, events and commands
    pub fn verdict(&mut self, v: Option<Verdict>, now: Instant) -> Vec<Decision>; // the answer for the batch in flight; None on failure
    pub fn forget(&mut self);                               // /stop: drop what waits for the classifier
    pub fn set_proactive(&mut self, on: bool);              // /proactive
}

pub enum EntryKind { Direct /* an @, a reply to Max, a private message */, Command, Chatter /* the rest, events included */ }

pub enum Decision {
    Wake { ids: Vec<MessageId>, reason: Reason }, // feed the core an Input::Wake, or start one
    Classify { batch: Vec<MessageId> },           // the actor runs the small model in side
}

pub struct Verdict { pub trigger: bool, pub reason: String }
```

Its values are constants in `max-core`; there are no configuration
options.

## Direct triggers

- **Direct triggers**: an @ of Max, a reply to Max, and any message in a
  private chat. They don't call the small model, aren't capped, and wake
  at once.
- **Nothing is held back for a second half.** People do finish an @ in a
  second message, and when its sender's next message arrives before the
  model call has said anything, the call is taken back and made again with
  it; the conditions are in
  [Starting a model call over](actor.md#starting-a-model-call-over). That
  costs nothing when no second half comes, which a wait before the wake
  would; why there is none is in
  [decisions/no-debounce.md](../decisions/no-debounce.md).
- **Commands** aren't triggers; the actor runs them.

## The small model

- **What is classified**: all chatter, while `/proactive` is on. A
  hand-typed "@max" is plain text and goes this way too.
- **Batching**: a conversation has at most one classification in flight.
  Chatter arriving meanwhile is collected and classified together when it
  returns, the latest 30 messages (`BATCH`). So classification keeps pace
  with the small model: in a lively chat one batch follows another, rather
  than one call per message.
- **Input**: the latest 15 messages as context (the tail's line format)
  and the messages to judge. `[mention#N]` becomes `@name`, and an @ of
  Max `@maxx`: the small model has no roster, so it tells from names whom
  a message is for. The prompt says in a line what maxx can do, and
  nothing of its persona: a small model reads a persona that likes to
  join in as a reason to.
- **Output**: one line of JSON, a short `reason` (cut at 40 characters, as
  it becomes the `[判定 …]` line) and then `trigger`, in that order, so
  that the verdict follows what the model has just said the message is.
  The prompt says most messages are members talking to each other, and
  names the two cases that wake Max, each with examples: someone calls it
  or wants something of it without an @, a hand-typed "@maxx" among them;
  someone asks the whole chat a question that nobody has answered. The
  rest is false, and the prompt gives examples of it rather than rules:
  a short answer to someone else, an @ of or a reply to another member,
  telling someone to go ask an AI, talk about Max, telling Max off, small
  talk, other bots' announcements, pasted code and notices. A follow-up to Max's own words
  isn't a reason: answers to Max are replies or @s, which wake it
  directly, and a small model that sees Max just spoke calls whatever
  comes next a follow-up. Why the prompt is written so is in
  [decisions/classifier-by-example.md](../decisions/classifier-by-example.md).
- **Where a verdict goes**: it comes back to the mailbox and the actor
  passes it to `intent.verdict`. With one classification in flight and its
  batch remembered, no task id is needed; a failed or panicked
  classification must still send `None`, or the conversation would never
  classify again. A positive verdict becomes `Wake { reason: Judged }` with
  the batch's ids. Every `Wake`, a direct trigger's too, follows one rule:
  if every message it concerns is at or below `seen`, it is void,
  since those messages were already in a request and the model made its own
  choice about them (messages before a `/kill` are voided so too). A wake
  that isn't void becomes an `Input::Wake`: it starts a core, recorded as
  its trigger, or is fed to the running one. A verdict shows as a line in
  `[新消息]`, such as `[判定：在追问你刚才的回答]`; a direct trigger adds no
  line, since its message is already marked `@你` or `回复你的 #123`.
- **The cap**: at most 20 verdict wakes per conversation per hour
  (`JUDGED_WAKES_PER_HOUR`), against a runaway small model; direct triggers
  don't count. Verdicts past it are dropped. It sits above what a lively
  chat reaches by itself, about 15 an hour, two thirds of them while
  Max's core is still up from its last answer: a cap of 8 is full on most
  days in the busiest group, and then drops verdicts that are right, a
  message that names Max without an @ among them. `/proactive` switches
  classification per conversation, and `/status` shows it.
- **Output limit**: 1000 tokens (`MAX_OUTPUT` in `classify.rs`): a model
  that reasons first (`deepseek-v4.1-flash` at low effort thinks for about
  100 tokens, and up to 280) was cut off one call in eight at 300, and a
  cut-off call is a failure.
- **Failure**: no retry; it is logged and the batch dropped. Intent only
  advises, the messages are all in the ledger, and the provider's own
  retries cover transient errors.
- **The model**: `[llm] intent` picks a small model. A turn started by a
  verdict uses the conversation's own model, as an @'s turn does.
- Each classification records an `llm_usage` row of purpose `intent`.

## State held only in memory

Collected chatter, the batch in flight and the hourly counts live in the
actor's memory and are lost on restart; there is no table for them.
