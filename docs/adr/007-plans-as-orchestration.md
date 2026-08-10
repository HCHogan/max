# ADR 007: Plans as Orchestration — Fork, Steering, and What the Kernel Is Actually For

- Status: Accepted for the plan core; supersedes the parts of ADR 002 listed
  under "What this retires" below. The IR changes (taint removal, `Fork`,
  `goalResources`, `goalHash`) have landed. The scheduler, the durable plan,
  and the reconciler have not.
- Date: 2026-08-10.

## Context

ADR 002 built a partial-plan IR whose centre of gravity was a deterministic
validator: a kernel boundary between untrusted elaboration and execution, with
effect ceilings as "the substantive prompt-injection defense at this layer" and
information-flow labels reserved for the day plans could reach secrets. Ten
integration steps were sequenced around getting that kernel right.

Six of those steps shipped. Then two questions were asked of the result, and
neither survived contact.

**What is there to verify?** The group-chat threat model was worked through
case by case. Cross-conversation delivery is structurally impossible — no tool
in `Max.Toolset` holds the authority, and `Max.Recall` scopes every memory read
by `conversation_id` in SQL (`Recall.hs:432`). Duplicate sends are already
handled by `ToolOutcomeUnknown` and `tdFailuresPrecedeEffects`. Tool existence
and argument schemas are already checked at `invokeTool`. Runaway cost needs a
fuel counter, not a kernel. Narrowing a deferred trigger's capability is already
`toolAllowedByEffectCeiling`, shipped for ADR 006. The static admissibility
kernel occupied no row in that table that something else did not already
occupy.

**What does taint label?** `TaintPrivate` was meant for values read under a
scope narrower than the turn's audience. In a group chat there is no such
value: the bot's memory of a conversation is scoped to that conversation, and
sending it back into the room it was told in moves nothing. `TaintExternal` was
a real category and the wrong mechanism — sending a query to a search provider
is how search works, and posting a fetched page into the room is the job, so
every goal declassified it and the check always passed. A rule that never
fires is not a defense; it is a rejection waiting to happen to ordinary work.

Meanwhile nothing in `src/` or `app/` imported `Max.Plan.*` at all. A 4200-line
core reachable only from its own tests is not being validated by production; it
is being kept warm.

The reframing that resolves all three: **a plan IR earns its place as an
orchestration substrate, not as a verification one.** What a horizon-1 tool
loop structurally cannot do is issue parallel *reasoning*, keep the working
model's context clean while large results flow through the work, or let a
half-finished decomposition be edited. Those are capability wins. The
verification story was a search for a job to justify machinery that already had
a better one.

Prompt injection does not disappear under this reframing; it moves. What
contains a poisoned page is not seeing it while holding a capability — which is
a narrower tool catalog handed out at spawn, enforced by intersection, not a
label propagated through a type system. ADR 002 already wrote the correct
sentence and filed it under self-refinement: *"Neither a prompt prohibition nor
an audit row substitutes for removing authority the actor should never have
held."* This ADR promotes that sentence from a footnote to the mechanism.

## Decision

### The plan IR is for orchestration; the kernel is a type and budget check

The IR keeps its parser, its total expression language, its schemas, and its
node ids. What shrinks is the claim made for the validator. It answers two
questions and stops:

- **Does this type?** Bindings resolve, projections exist, arguments match
  catalog input schemas, the result matches the goal's expected schema.
- **Does the arithmetic close?** Calls, sends, and effects stay inside the
  ceilings, with fan-out summed (below).

It no longer claims to be the injection boundary, and it no longer carries an
information-flow lattice. Runtime authorization at `invokeTool` was always the
real boundary; ADR 002 said so and then built a second, weaker set of checks
in front of it anyway.

### Fork: a goal splits into subgoals, and the independent ones run at once

The Lean analogy in ADR 002 was drawn at the elaborator and stopped one step
short. Lean's `constructor` turns one goal into several, each an independent
metavariable in the same term. The IR could not express that: `Hole` sits in
tail position, so along any execution path there was at most one open goal and
it was always last. That is a horizon, not a decomposition.

```haskell
data Plan
  = Done !Expr
  | Call !CallNode !Plan
  | Let !Binder !Expr !Plan
  | Fork !ForkNode !Plan     -- n subgoals bound at once, then a continuation
  | Guard !Predicate !Plan !Plan
  | Hole !Goal
```

**`Hole` and `Fork` stay separate nodes rather than one node with a count.**
`Hole ≡ Fork [(x, g)] (Done (EVar x))` holds as a type identity and misses the
distinction that matters: a hole is filled by whoever is already writing this
plan, with everything that author can see; a fork's child is filled by a
separate elaboration that sees only its own `Goal`. Thinking further versus
delegating. Everything else here depends on that being a real distinction in
the IR rather than a scheduling detail.

**Independence is structural, not declared.** Every child of one fork sees the
binding scope at the fork, so no child can read a sibling's result — there is
no syntax for it. Dependent work is two forks, and what the second may read is
exactly what the first bound. Sequencing is therefore *derived* from the
bindings rather than announced by the model, which puts the consequence of a
bad split in the right place: a model that serialized independent work, or
believed dependent work was parallel, costs latency and never correctness.

This matters because of what models are and are not good at. They demonstrably
decompose — a plan or todo list before a hard task is now standard behaviour,
and parallel tool calls in one block are already a declaration of independence
one level down. What a todo list never contains is a return type, a budget, or
a combining step written before the results exist. So the IR asks for as little
as possible and derives the rest: independence is inferred, and only the three
things the model genuinely knows are demanded — what the parts are, what each
returns, and how they combine.

### Sibling budgets add; the kernel checks that they close

This is the one genuinely arithmetic fact a static kernel knows about this
language, and it is new with `Fork`. Alternatives take the worse branch because
only one runs. **Siblings all run, so their grants sum.** Without the sum, three
children each passing the per-child narrowing check on its own hand the plan
three times its budget:

```
fork { a: … budget { calls: 2 }  b: … budget { calls: 2 } }   -- 2 ≤ 3 twice
                                                              -- 4 > 3 together
```

The sum also lands in `Usage`, so a fork that fits alone but not alongside the
calls around it is caught at the root. Both checks stand; the local one names
the fork, which is the message a model can act on.

Budgets are written by the model for now, exactly as a hole's are. Defaulting
them to an even split of the parent's remainder is the intended ergonomic next
step and is deliberately *not* taken yet: its justification — that models have
no calibration for "this subtask is worth three calls" — is an empirical claim,
and the measurement comes first. Shipping the check before the default is the
order that can be corrected by evidence.

### Two policies, not one: when the continuation runs, and when anyone looks

`join_all` versus a completion stream is one choice in an async runtime because
the awaiting task is also the consumer. Here it is two, because the consumer and
the observer are different actors with different prices:

| | governs | values |
|---|---|---|
| `join` | when the **continuation** becomes runnable | `all` (only member today) |
| `watch` | when the **model** is woken to look | `on-failure` (default), `each` |

Conflating them prices every observation at a join or every join at a model
call. `each` is not a join semantics at all — when it fires, the siblings have
not finished and the continuation cannot run; what it buys is the chance to
rewrite the plan partway through.

Both default to the quiet reading: wait for everyone, wake nobody unless
something failed. A fork whose children all succeed costs no model call. `join
any` — first success wins, cancel the rest — has a real use and no
implementation; the syntax position is reserved so adding it is a new word
rather than a new shape.

The wake conditions are the same vocabulary as ADR 006's typed triggers, not a
second one. A `watch` clause is a monitor written inside a plan.

### The front model holds the plan; children hold only their goal

The working model keeps the conversation, the memory, the persona, and the
plan. It decides and edits. It does not do the work.

A child receives its `Goal` and nothing else — no conversation history, no
memory, no persona, no sibling goals. This has one consequence everything else
rests on:

> **A child's prompt is a pure function of its `Goal`.**

Cacheable, reproducible, testable — and, decisively, *comparable*: two goals
with the same bytes are two requests for the same work. Without it, the
declarations on a goal would be decorative, because a child that could read the
conversation would route around them.

It is also a capability win before it is a safety one. A model that has just
read forty kilobytes of scraped HTML writes differently — it shifts register
toward summary and report. Max's persona and its bias toward saying little are
tuned, and that is exactly what large tool results erode, irreversibly within a
turn. Under isolation the front model does not merely see *less*; it sees a
value in the schema it asked for. A useful side effect: ADR 005's replay tiers
were compensating for tool-result bloat, and with the bloat gone the front
model's history is cheap enough to keep verbatim for longer.

### Plans are durable, editable objects; edits reconcile by goal hash

A plan must be changeable mid-flight, including by the user. "Do that, then
also X" is not a correction; it is a new goal with the old one beneath it.
Running children must survive that.

This kills the cheaper alternative outright. A sequence of past tool calls
cannot be rewritten — steering requires the plan to be an addressable data
structure, which is the strongest argument for the IR and stronger than any
made in ADR 002.

Three writers (the front model, the user, completing children) act on one
structure while children run. The model is not asked to decide which children
survive an edit. `goalHash` — SHA-256 over the goal's canonical bytes — gives
each open goal an identity, and reconciliation is a set difference:

```
open goals of the new plan   = desired
running children             = actual
  appeared → dispatch    vanished → stop    unchanged hash → leave alone
```

Desired-versus-actual, as in a React diff or a Kubernetes reconciler. The
wrapping case falls out for free: re-parenting a goal under a larger one does
not touch its bytes, so the subtree already running is undisturbed.

Two id schemes coexist and are not interchangeable. **Path-derived `NodeId`s
address the journal**; they shift when a node is inserted above them, which is
correct for addressing and fatal for identity. **Content hashes are identity.**

Suspension granularity is the effect boundary — the same point the executor
already stops at to journal. Nothing can be suspended cleanly mid-LLM-call;
that is accepted, not worked around.

Plan edits are whole-file rewrites, not an edit language. The thing an edit
language would report explicitly — what changed — the reconciler already gets
free from the hashes, and models rewrite text more reliably than they emit
structured patches.

"The front model always knows the global state" means *able to*, not *invoked
every time*. State lives in Postgres; the reconciler steps the plan forward
mechanically, and a model call happens only at a decision point: a user
message, a child failure, a child result that fails acceptance, a join whose
combining step was left as a hole, an exhausted budget, or a child escalation.

### A fork child is a turn, and the turn graph is the reconciler's other half

ADR 002's `turn_edges` — spawn, depend, fork-from — is not superseded by any of
this. It is the **actual** side of the reconciliation above, which that section
specified without naming where it lives. The plan is mutable intent; the turn
graph is append-only fact. A steer that stops a child rewrites the plan and
leaves the child's turn, its edge, and its journal rows exactly where they are,
because they record what happened rather than what is wanted.

**A fork child is a turn.** This is forced rather than chosen: ADR 004's handle
grammar is turn-qualified, so a child's result is addressable — by the join, by
a later fork, by a monitor trigger, by a user replying to it — only if the child
has a turn number, and its tool calls need journal rows attributable to
something. Each child therefore carries two ids, the same shape as node id
versus goal hash one level up:

| | answers |
|---|---|
| path `NodeId` (`…/k0`) | where it sits in this plan |
| its own turn id | who it is in the journal and the handle space |
| the `turn_edges` spawn row | ties the two together |

**`Fork` compiles to a spawn edge, and is the durable kind.** ADR 002 drew a
line — "a short structured `Fork`/`Join` inside one Plan is likewise separate
from a durable child turn" — and this `Fork` is on the durable side: children
run elaborations, make LLM calls, journal, suspend, and can be steered. The
light reading, concurrent work with no model round in between, is unbuilt, and
`ToolParallelism` already covers the part of it that pays. Recorded because a
reader who assumed the light reading would badly under-price a fork.

The edge kinds fare differently under this. **spawn** is what `Fork` emits and
is load-bearing. **depend** narrows to cross-plan use only: inside one plan the
tree *is* the dependency edge, so there is no row to write and no cycle to
detect — 002's fail-closed cycle check narrows with it. **fork-from** is
untouched; ADR 005 continuations and ADR 006 monitor fires use it as written.

So 002's "the child-plan section becomes a special case of the turn graph"
holds, with the relationship now division of labour rather than containment:

- **Within one owner and one budget**, the plan tree is the dependency
  structure — typed, checked (budget conservation, join schemas, binding
  scope), editable, reconciled by hash.
- **Across owners**, the turn graph is the only structure there is. No shared
  budget, no join, no typing across the boundary. Two principals' tasks are two
  root plans, not two children of one fork; putting them in one fork would let
  one principal's steer move the other's work.

### Unify the history; keep the plan a value

Everything that happened belongs in one append-only causal log: messages,
turns, spawn/depend/fork-from edges, journal effects, monitor fires — and plan
revisions. Current-state tables (open goals, armed monitors, the plan head) are
rebuildable projections of it. This is not a new principle; max has adopted it
twice already, in ADR 002's "journal rows record events, not state" with a
monitor's mutable state kept in its own table, and in ADR 003's "one tree, five
projections, each implemented once".

Putting plan revisions in that log buys the question a steer's debugging
actually asks — *what did the plan look like when this child was dispatched* —
which a mutable row cannot answer.

The plan itself does not dissolve into the graph. Three costs, of which the
third decides it:

- **Query.** "Which goals are open now" becomes a fold over history. It gets
  materialized anyway, so the result is a graph *and* a projection — not one
  thing instead of two.
- **Typing.** Budget conservation, join schemas and binding scope are checks
  over the tree's shape. A generic node/edge store does not remove the tree; it
  makes the validator rebuild it first.
- **Identity.** `goalHash` is cheap because a `Goal` is a self-contained value,
  so "the same goal" is a byte comparison. As a node with edges out to its
  context, "the same goal" becomes subgraph isomorphism — and that comparison
  runs every time anyone in the group says anything. **History may be a graph;
  intent must be a value.**

The four id schemes (conversation, turn, journal row, plan node) are a real
cost, and flattening them into one would not reduce it: they are different
granularities, and the hierarchical spellings — `t#3:r2`, `turn:41:0/c/k0` —
already *are* the compression of exactly that. What reduces the count is
pinning two schemes together, which is what making a fork child a turn does.

### Children speak to the parent; children do not speak to each other

A child may terminate by escalating a message instead of returning a value —
"this page also mentions a third name, want it?" — which travels the existing
wake path and lets the front model rewrite the plan. No new mechanism; `watch`
gains a reason. It also makes the quiet default defensible: nobody is woken
unless something failed, *or a child decided it was worth waking someone*.

Sibling-to-sibling messaging is refused. The front model is the single
serialization point for plan changes — one writer, ordered, versioned — and a
direct sibling channel is an edge that bypasses it. Concretely it would end the
pure-function property (a child's behaviour would depend on its mailbox, so the
hash is no longer identity, so reconciliation, caching and reproducibility all
fail), make the plan's DAG a fiction, admit deadlock in a system where each
message costs an LLM call, and let two children negotiate without a termination
condition. The star topology is N messages; the mesh is N² and unbounded in
time.

The needs behind the request resolve elsewhere: *B needs A's result* is a
dependency edge, already expressible as two forks; *A learned something B
should know* is a plan change, routed through the front model at the cost of
one hop; *both did the same work* is a decomposition bug to fix at the source.
The one case hierarchy genuinely does not cover — shared mutable state, such as
a visited-URL set across parallel crawlers — gets a fork-scoped append-only
store read and written through a tool, if and when a real case appears. Shared
data, not shared context; it creates no implicit ordering edge and enters no
prompt.

### The group's verbs land on the plan, and the missing middle appears

ADR 002 gives multi-principal input a six-verb lattice: steer, annotate,
depend, fork-from, abort, observe. Three are implemented — `!feedback` is
steer, `!btw` is observe, `!kill` is abort — and `annotate` is described there
as the one that matters most for quietness: *"most supplements are not worth a
forced elaboration round."*

It cannot be built in a horizon-1 loop, and the reason is structural rather
than incidental. `Max.Effects.Agent` drains the task inbox at the top of each
round and appends `[feedback]: …` as a synthetic `MsgUser`. That round boundary
is the *only* injection point, so "wait for the next natural pause" and
"interrupt now" name the same act. There is no third thing to mean.

A plan supplies the missing referent. There is now a next decision point that
is not the next round — and it is exactly the schedule `watch on-failure`
already defines:

- **steer** forces a wake: the front model reads the note, rewrites the plan,
  and the reconciler stops the children whose goal hash moved.
- **annotate** attaches the note to the plan and waits: the front model reads
  it at the next decision point it was going to reach anyway.

That is the quietness philosophy expressed as a schedule rather than as a
prompt instruction, which is what ADR 002 asked for and could not spend.

| verb | today | on a plan |
|---|---|---|
| observe (`!btw`) | ledger ingest, no task effect | unchanged — already the degenerate case |
| steer (`!feedback`) | inject text at the next round boundary | wake → rewrite → reconcile |
| annotate | *inexpressible* | attach; read at the next decision point |
| abort (`!kill`) | cancel the dispatch | unchanged for the plan root |

Two things get deleted, both already promised: the drain-and-inject-synthetic-
`MsgUser` path, and with it the `requeueTurnInbox` race — 002's consequence
list already commits to "the sent-prefix watermark and the feedback-raced-
stream requeue path" being *"deleted rather than maintained"*. A note stops
racing a stream because it no longer has to enter the conversation to be
consumed; it enters the plan.

Two things get better without new design. **Durability**: `TaskHandle.thInbox`
is a `TVar [Note]`, so a steer landing during a restart is gone today, and a
plan-scoped row survives. **Granularity**: a steer targets a *task* today; with
path ids it targets a *subgoal* — "查乙那个改成查丙" moves one child's goal
hash and leaves its siblings running, which the horizon-1 loop has no
vocabulary for because it has no subgoals.

`Max.Intent.classifySupplement` is the implicit half of the split and today
returns `Bool` — push into the running task's inbox, or spawn a parallel
dispatch. Those are two of the six verbs, and its codomain grows to the lattice
rather than its call sites multiplying. `Note` already carries
`noteSource :: Maybe DispatchMessage`, which is the attribution the model needs
to weigh "the initiator said stop" against "a bystander disagreed" — social
judgment ADR 002 correctly refuses to hardcode.

What does **not** improve is targeting. Which task an utterance means is still
resolved by reply linkage and intent classification, exactly as before; ADR 002
calls it "a present-tense correctness gap, not a future feature", and more
concurrent plans make it worse rather than better. Finer targets do not help a
system that cannot tell which target was meant.

### A goal is handed addresses, never bodies

`goalResources` lists result handles (ADR 004's `t#<n>:r<n>`) that whoever
fills the goal may resolve. The front model chooses what is relevant, because
that is what having the conversation is for; it does not have to *carry* it.

A goal carrying bytes would grow with whatever it points at and its hash would
move with the content — which defeats `goalHash` as an identity and puts a page
nobody decided to read into a prompt. What enters the child's context is the
address, its schema, and a line of description: thirty tokens, from which the
child decides whether to pull. The same progressive-disclosure shape the skills
system already uses — the listing is visible, the files are not.

The strongest form of this is that a handle carries a schema, so a plan can
*project* through it:

```
let urls = map(h in t#3:r2 => h.url)
```

Twelve search results travel from Postgres into `urls` without entering any
model's context. Not the front model's, not the child's. **Data flows through
the plan without flowing through a context** — and that is the most concrete
argument for keeping the expression language good.

Scope needs no new mechanism: a child's `venHandles` is built from its goal's
list, so referencing an unlisted handle fails validation. You cannot reach what
you were not given.

One risk is recorded rather than solved: choosing which handles to attach is
quality-critical and *unguarded*. A budget error is caught, a type error is
caught, "you forgot the thing they needed" is not — the child simply does worse
work silently. The mitigation is to make it loud: a child that finds itself
short of context escalates rather than guessing, and the child prompt must say
so, because the default failure mode of a model is to press on and invent.

### Capability narrowing is intersection at spawn, not a declaration to check

ADR 002 required a child's budget to be a declared subset and had the validator
reject a widening. The host mints the child's authority anyway, so the correct
construction is `child = parent ∩ declared`, which cannot widen. A plan that
asks for more silently gets less and finds out at runtime; the elaboration
prompt already states the ceiling, so the ergonomic argument for rejecting up
front is thin.

`BudgetNotNarrowing` remains for now as a legible early error and becomes
redundant once a scheduler mints child environments by intersection.

## What this retires in ADR 002

| ADR 002 | Status |
|---|---|
| "Before Max exposes secret-bearing or cross-conversation read capabilities to plans, values need provenance/taint labels" (§ Validate plans…) | **Retired.** No such capability exists or is planned; `Recall` scopes reads in SQL. Taint, `ceIntroduces`, `goalDeclassify`, the `declassify` block and `TaintNotDeclassified` are deleted. |
| "Effect ceilings are also the substantive prompt-injection defense at this layer" | **Reframed.** Containment is a narrowed catalog handed to a quarantined child at spawn. Ceilings remain a budget, not a defense. |
| Validator checks "effect ceiling and resource-scope constraints", "host permission policy", "information flow" (§ Validate plans…, step 4) | **Narrowed** to types, budget arithmetic including fan-out summation, and handle resolution. Authorization stays at `invokeTool`, where it always was. |
| "A future `Spawn` is primarily an elaboration-scope construct, not merely a parallelism primitive" (§ Child plans narrow view and authority) | **Inverted.** Orchestration is the primary motivation; narrowing is what makes delegation safe, not the reason to delegate. |
| "`Spawn` and unbounded `Foreach` are not part of the first implementation slice" | **Superseded.** `Fork` is the first slice, on the *durable child turn* side of 002's own distinction. Unbounded `Foreach`, and the light in-plan `Fork`/`Join` 002 separated it from, both stay out. |
| Sibling edges permitted under "an explicit parent-granted recipient capability" | **Retired.** Siblings do not communicate; see above. |
| "information-flow clearance" as a component of a minted `AgentRef` | **Retired** with taint. Scope, catalog and ceiling remain. |
| Integration steps 7–10 | **Replaced** by the sequence below. Step 7's "short, read-only plan segments behind a feature flag" assumed the value was in validated execution of small plans; it is not. |
| "taint" in the result-envelope contract (§ handles, step 3) and re-hole evidence | **Retired.** `ValueRef` and `Evidence` keep scope and drop the label. |

Everything else in ADR 002 stands, including the journal contract, crash-is-
deoptimization, acceptance verifiers, the narrator projection, the total
expression language, parse-or-reject, and the rejection of opaque code as the
orchestration layer.

## Integration sequence

1. **Delete taint.** Done (`3f805ab`).
2. **`Fork`, `join`/`watch` syntax slots, `goalResources`, `goalHash`.** Done
   (`6eb90fa`).
3. **Persist plans as revisions in the causal log, with a materialized head.**
   Ahead of the executor rather than after it: a plan the user can steer and
   suspend cannot live only in memory. Optimistic concurrency on the head's
   version; a completing child CASes and re-reconciles if the plan moved. The
   feedback inbox moves with it — `TaskHandle.thInbox` is a `TVar [Note]`
   today, so a steer that lands during a restart is lost.
4. **Reconciler.** Desired (the head's open goals) against actual (turns with
   no completion, via `turn_edges`), diffed by goal hash; dispatch and stop
   only. No cancellation semantics yet.
5. **Executor suspends at effect boundaries.** Journal, authorize, resume. This
   is also the durability work — checkpoint-resume for the roadmap's L1.
6. **Split the prompts, and land the verbs.** A front-of-house prompt and a
   child prompt generated from the `Goal` alone. `!feedback` retargets from the
   round-boundary injection to a wake; `annotate` becomes expressible;
   `classifySupplement`'s codomain grows from `Bool` to the verb lattice; the
   `requeueTurnInbox` race is deleted rather than ported.
7. **Measure.** Fork-shaped tasks against the live multi-model harness. The
   open questions are not "will it decompose" — that is established — but
   whether the combining expression can be written before the results exist,
   and whether declared return types are tight enough to be worth anything.
8. **Concurrency and child context projection**, only once 7 says the shape
   holds.

Steps 3–4 are ordered ahead of 5 deliberately; ADR 002 had execution first,
which is the right order for a machine nobody edits.

## Consequences

- The plan core acquires its first consumer. `Fork` gives the front model a
  reason to emit a plan that a horizon-1 loop cannot imitate.
- Long tool results stop entering the working model's context, which protects
  the persona as much as the token budget, and simplifies ADR 005's replay
  tiering.
- The IR gains a second identity scheme. Path ids and content hashes answer
  different questions and confusing them silently breaks reconciliation.
- A fork child costs a turn. Fan-out is priced in turns, journal rows and
  handle space, not only in tokens — which is the correct price, since that is
  what makes a child's result addressable and its work steerable.
- Storage settles before step 3 rather than during it: one append-only causal
  log with rebuildable current-state projections, and the plan head as a value
  beside it. ADR 002's `turn_edges` becomes load-bearing for the first time,
  as the reconciler's actual side.
- `annotate` becomes buildable and the feedback-raced-stream requeue path
  becomes deletable, both because a plan supplies a decision point that is not
  a round boundary. Targeting — which task an utterance meant — is untouched
  and gets harder as concurrent plans multiply.
- Fan-out multiplies cost. `n` children are `n` contexts, and the budget
  arithmetic is the only thing standing between a decomposition and an
  n-times bill.
- A fork is a loss when the combining step cannot be written in advance:
  hanging a hole after the join spends an extra model round and gives back the
  latency the parallelism bought. The guide says so; whether models hear it is
  question 7.
- Deleting taint removes a rejection that could not be explained to a user.
  Nothing that was actually protected loses protection, because the protection
  was in `Recall`'s WHERE clause.
- Steerability is now a hard requirement on everything downstream: any state a
  running plan holds outside Postgres is state a steer can silently strand.

## Rejected alternatives

### A `spawn_subagent` tool instead of an IR node

The cheaper option, and the one Claude Code uses. Rejected on four grounds, of
which the fourth is decisive: budget partition and capability narrowing are
fixed before any child runs, rather than discovered at 10× spend; the combining
step is written before the children run, which forces the model to commit to
what it will do with the results instead of dumping three raw pages into one
window; parallelism is structural rather than contingent on the model
remembering to batch; and **a tool call history cannot be edited**, so
steering, suspension and resume are unavailable in principle rather than
unimplemented.

The tool version remains the right *cheap experiment* for the single question
of whether models decompose well, and is not the right foundation.

### Sibling-to-sibling messaging

See above. Ends the pure-function property, makes the DAG a fiction, admits
deadlock at LLM prices, and rebuilds the context accumulation that isolating
children was for. The escape hatch, if a real case appears, is a fork-scoped
blackboard: shared data, not shared conversation.

### Replacing the IR with a real language (Unison, restricted Python)

Reconsidered seriously when taint collapsed, since a general language would let
the model solve pure-computation problems directly and would make effect
suspension straightforward. Rejected for this layer for the same reason ADR 002
rejected opaque code, plus one new one: **a program is not editable by a
user mid-flight in any way a model can reconcile.** Steering requires a
structure whose open obligations are enumerable, which is what a hole is.
Serializable continuations, Unison's strongest draw, are also obtainable from
deterministic replay over an effect journal — the Temporal/DBOS construction —
which max needs regardless.

The pure-computation argument is real and is answered by the sandbox tool at a
declared coarse boundary, which is where ADR 002 already put it.

### Keeping taint dormant rather than deleting it

Rejected. A dormant lattice still costs two lines of every elaboration prompt,
a field in every goal literal, and a `(schema, taint)` pair threaded through
every inference path — and, worse, it reads to a future maintainer as a
protection that is in force. Reintroducing it if max ever holds a genuinely
cross-scope read is a smaller job than the confusion of carrying it.

### Defaulting child budgets in the same slice as the check

Rejected as premature. The default's justification is an empirical claim about
model calibration that step 7 will actually test.
