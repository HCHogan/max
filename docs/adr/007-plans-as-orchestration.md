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

Step 6 below moved the annotate row's `today` column: it now lands in the inbox
unannounced and dies with the turn rather than reviving. What it still shares
with steer is *when* it arrives, and that is the half a plan pays for.

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

**The router decides when, the front model decides what.** This division is
load-bearing and easy to lose, because the verbs are named after intentions and
intentions are exactly what a cheap classifier reading four lines of history is
worst at. What genuinely has to be settled at ingest is scheduling — the front
model is either not running yet or is mid-round, and a reaction that arrives
twenty seconds late has already failed. What must not be settled at ingest is
meaning: whether a note changes the plan, which subgoal it moves, whether it
deserves an answer at all. Those need the conversation, the memory and the plan,
and the front model is the only thing holding all three.

The invariant that keeps the line where it belongs: **the router may delay a
note or attach it quietly; it may never end one.** It reports its reading as a
label the front model can disregard, and every note that reaches an inbox
survives to a model that can answer it — or say `[silence]`, which is the same
restraint arrived at by whoever is qualified to exercise it. Quietness bought by
letting the router discard is quietness bought against the one thing this design
is for.

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

### What wakes the front model, and what merely continues

A plan runs without a model. `stepPlan` walks to a call, the host invokes it,
`resumeWith` continues; no LLM is involved and nothing enters anyone's context.
That is where "the front model does not get filled up by long tool results"
actually comes from — not from summarisation, but from the model not being on
the path at all.

So the interesting question is the complement: what *does* wake it.

| trigger | who raises it | how often |
|---|---|---|
| A hole or bind the plan reached | the plan | **most** |
| A message — anyone, about anything | outside | some |
| A child finishing | the scheduler | **only if `watch` says so** |
| A monitor firing (ADR 006) | time or condition | rare |
| A deopt — budget spent, path gone, tool refused | the executor | exceptional |

The third row is the one worth reading twice. Under `join all` + `watch
on-failure`, children completing *successfully* do not wake anybody: the join
expression is evaluated and the plan continues. Only a failure does. Which
child-completion is a wake and which is not was decided by whoever wrote the
fork, before any child ran — and that is what the combining expression was
bought with.

### A revision is a whole plan, not a patch

The front model changes a plan by writing a new one, in the same dialect it
wrote the first one in. There is no patch language, no diff format, no
node-addressing edit vocabulary.

Three reasons, in order of weight. A patch grammar is a second language to
write, validate, and get subtly wrong, and it would be exercised on exactly the
paths that matter most. Models are measured at writing whole plans — 47/48 — and
not at patching them; the ability we have evidence for is the one to use.
And most decisively, **the diff is derived rather than authored**: `goalHash`
already makes "which subgoal actually moved" a byte comparison, so the
reconciler computes the consequences — stop this child, dispatch that one, leave
the third alone — from two plans, without anyone having to describe the change.
An authored patch would be a second, redundant, disagreeable account of
something already computable.

`plan_revisions.cause` was built with the values `initial`, `elaboration`,
`steer`, `child`, `rehole`. Those are the wake reasons from the table above.
Concurrency is `plans.head_revision` as a compare-and-set token: a steer landing
while a child completes means one revision wins and the other re-reads and
retries, which `revisePlan` already reports as `Left (RevisionConflict head)`.

### Waking is elaboration; there is no second prompt

The strongest structural claim here, and the one that keeps the surface small.

A woken front model is in the same position as an agent filling a hole. Its
environment is what has already run — bindings in scope, handles resolved. Its
objective is what remains. Its output is a plan. That is `frontPrompt` against a
populated `venBindings`/`venHandles`, which is the same projection `childEnv`
performs for a subgoal, pointed at the parent instead.

Two awkward cases fall out rather than needing handling:

- **A steer arriving after work has been done.** Someone says 改成后天的 and a
  search has already run with the wrong date. Nothing rolls back; the completed
  search is simply a binding in scope, and the revision is a plan for the
  remainder that may use it or ignore it. There is no undo because there is
  nothing to undo — only a next plan to write.
- **A child that failed.** Its binder never got a value, so it is not in the
  environment. A revision cannot reference it, not by policy but because the
  name does not exist.

`PathNotInPlan` is the backstop: a checkpoint pointing into a plan that has
since been replaced reports rather than guesses.

### A waiting plan is an armed suspension, not a row to poll

Nothing scans the `plans` table looking for work. A plan waiting on children is
the thing ADR 006 already named — an armed suspension with typed triggers — and
a child finishing fires one at its parent. Recovery after a restart is the
reconciler reading spawn edges against unfinished child turns, which is the same
comparison it makes when nothing has crashed.

*Recorded as a direction rather than a verified fit:* whether ADR 006's trigger
types can carry a plan wake without widening needs checking against that ADR
before this is built, not after.

### The front model keeps the fast tools; slow work is what delegation is for

`Fork` has a better justification than "two things at once finish sooner". The
front model is the one that has to stay able to answer, and every slow tool it
holds is a stretch of time the group is talking to something deaf.

So the split is by **latency, not by capability**: `Browser`, `Sandbox`,
`Video`, image generation — the seconds-to-minutes tools — belong in children,
where blocking costs nothing because nobody is waiting on that context to
speak. The front model keeps `plan`, search, memory, reply.

A tendency rather than a gate. One browser fetch that *is* the whole task should
not be forced through a child, and fork's budget arithmetic already prices the
alternative honestly.

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
   Done (`20fe52a`). Ahead of the executor rather than after it: a plan the
   user can steer and suspend cannot live only in memory. `plan_revisions` is
   the append-only half and `plans.head_revision` is both the pointer and the
   compare-and-set token. The feedback inbox stays a `TVar` until step 6 lands
   its reader; moving it sooner would leave a table nobody queries.
4. **Reconciler.** Done (`Max.Plan.Reconcile` + the `spawn` edge kind). Desired
   (the head's fork children) against actual (spawn edges whose child turn has
   not finished), diffed by goal hash; dispatch and stop only. Matching is by
   multiset, because two byte-identical subgoals in one fork are a legitimate
   request for two independent answers. No cancellation semantics yet: the
   reconciler decides, and step 5's scheduler acts.
5. **Executor suspends at effect boundaries.** Done. Execution is a pure step
   function over a serializable `ExecState`: it walks to a call, hands back the
   concrete arguments, and stops. The caller journals, authorizes, invokes, and
   resumes. This is also the durability work — a crash between two calls loses
   the call in flight and nothing else — and it is what makes an approval
   boundary possible at all, since a ceiling bounds what a plan *may* ask for
   and only a suspension shows what it is *actually* asking. A checkpoint whose
   path no longer exists in the plan reports rather than guesses, which is the
   ordinary outcome of a steer landing mid-walk.
6. **Split the prompts, and land the verbs.** Partly done, and the step splits
   cleanly along one line: *does this need a plan to be running?*

   **The prompts are split.** `frontPrompt` is today's bytes unchanged — worth
   saying, because that is what step 7's 46/48 measured, and churning it would
   have invalidated the number to no purpose. `childPrompt` is new, and the
   substance is not the briefing paragraph but `Max.Plan.Validate.childEnv`: the
   projection that takes a parent environment and a subgoal and returns the
   world as that subgoal sees it. Bindings restrict to `goalInputs`, handles to
   `goalResources`, and the catalog to the tools this goal's budget and
   authority could actually pay for. The last of those is not a correctness
   requirement — the kernel rejects an over-effectful call anyway — but listing
   a tool a child can never call advertises a guaranteed rejection as an option,
   which is the same argument the goal section already makes for released
   handles. Everything narrows and nothing widens, so the projection is
   idempotent and a child of a child is strictly poorer than its parent without
   anyone tracking depth. The guide comes first in both prompts, byte-identical,
   so the two roles share one prefix cache.

   **The verb lattice is landed, three-valued rather than six.**
   `classifySupplement` returns `steer` / `fyi` / `new`, and `Note` carries
   which one put it there. *Observe is deliberately not inferrable*: it is
   `annotate` with the note thrown away, and there is no reading of "a
   classifier silently ignored a message addressed to the bot" that is safer
   than keeping the note. It stays what it has been — a verb the user types.

   Annotate is a real verb today, with two consequences rather than a rename: it
   does not wear the 托腮 that promises a note was acted on, and it reaches the
   model as `[fyi]` rather than `[feedback]`, because one tag for both tells the
   model that 「顺便说一句我明天休假」 is an instruction. Pokes were reclassified
   as annotations while the distinction was being made: a poke says somebody is
   there, not what to do differently.

   **It was three consequences for one commit, and the third was wrong.** An
   annotation the running turn never got to was being dropped instead of
   re-dispatched, on the grounds that reviving 「顺便说一句」 as a turn of its own
   is the sound of a bot that talks too much. It is — but the router was the
   wrong actor to prevent it. That is the router ending a message: deciding,
   from four lines of history and a model chosen for being cheap, that something
   somebody said to the bot will never be read by anything that could answer it.
   The revived turn can already say `[silence]`. Restored, and the invariant is
   now pinned by a test rather than by an argument.

   The general shape of the mistake is worth naming, because the next two steps
   can make it again: with no plan running, the verb's real job — *when does the
   front model look* — has nowhere to land, so it drifts toward the jobs that do
   have somewhere to land, which are the front model's.

   **Two parts do not land, and the reason is the same for both.** `!feedback`
   cannot retarget to a wake and the `requeueTurnInbox` race cannot be deleted,
   because there is no plan to wake and the drain-and-inject-synthetic-`MsgUser`
   path is still the only path a note has into a turn. Deleting the requeue
   today would not remove a race; it would drop steers that arrive during a
   streamed answer. This is exactly the argument this ADR makes above — the
   round boundary is the only injection point, so *"wait for the next natural
   pause"* and *"interrupt now"* name the same act — arriving as a scheduling
   fact rather than as prose. What annotate has today is the *promise* half of
   the distinction; it gets the *schedule* half when a plan supplies a next
   decision point that is not the next round.

   So the honest state of the table above: the `today` column moved for
   annotate, and the `on a plan` column is still ahead for steer.
7. **Measure.** Done. Three models × 16 tasks, six of them fork-shaped and
   three of those deliberately wanting no fork.

   **The first finding was a configuration bug wearing a capability's
   clothes.** At production's `max_tokens: 4096`, two of the three models
   returned a 200 with no content on the tasks that needed splitting — five
   of deepseek's eight silences and three of minimax's four were fork-shaped.
   They were not decomposing badly; they were spending the whole ceiling
   thinking and never reaching the writing. Raised to 32768, **silence went to
   zero for both**.

   | profile | silent @4096 | silent @32768 | admitted @4096 | admitted @32768 |
   |---|---|---|---|---|
   | gpt-5.6-luna | 0 | — | 15/16 (93%) | — |
   | minimax-m3 | 4 | **0** | 11/12 (91%) | 12/16 (75%) |
   | deepseek-flash | 8 | **0** | 7/8 (87%) | 15/16 (93%) |

   Minimax's rate *falling* when the silences disappear is the exclusion bias
   made visible: the harness leaves silent replies out of every rate, which is
   correct for measuring a dialect and means a headline rate is computed over
   whatever a model managed to reach. Worth keeping, worth never quoting
   alone.

   With the ceiling raised, fan-out is not a one-model capability: all three
   forked, and the dependent-halves task was forked by all three.

   On the two open questions, over the nine forks across both runs:

   - **The join was never punted. Nine forks, zero holes after a join.** Every
     model that forked wrote its combining expression before any child had
     run. This was the question the step existed to answer and the answer is
     clean.
   - **Types are still mostly skipped**: six of seventeen subgoals asked for
     anything narrower than `text`. Reported rather than scored — a weather
     blurb genuinely is text — but the two clearest wins reproduced the
     guide's `{name: text, bio: text}` closely, so the example is doing more
     of the work than the rule is.
   - **Nobody forked a task that did not want one.** Strictly-sequential,
     single-lookup and judgement-heavy joins drew zero forks across all three
     models. Weak evidence — forking is still uncommon overall — but it is
     evidence in the right direction.

   Two findings nobody asked for, both recorded as fixtures:

   - **A child cannot be handed a parent's binding.** On the dependent-halves
     task the model inlined an entire framework string into both subgoal
     objectives, because a `Goal` carries text, a schema and handles — and a
     parent binding is none of those. Correct behaviour, and fine for a short
     string; for a large value it is exactly the context bloat forks exist to
     avoid.
   - **`let x = hole …` is now the dominant parse failure**: five of the six
     across every run, from two of the three models, and all four in the
     raised-ceiling run. gpt-5.6-luna wrote the legal spelling of the same
     intent — a one-child `fork { summary: hole … }`. This is the same shape
     of finding, at the same magnitude, that produced `Let`.

     It covers two distinct motivations, and only one of them is delegation.
     Minimax wrote `let topic = hole "需要搜索的具体话题" : text budget
     { calls: 0, sends: 0, … }` and then used `topic` in two searches: not
     work to hand to a child, but **a value it does not know yet**. A
     one-child fork models that badly — nothing wants a child turn, only a
     filled-in blank.

   Two smaller ones. `text` is reserved because it names a type and is also
   the most obvious name for a string; one otherwise-correct plan died on it.
   And a `VerifierSchemaMismatch` arrived as the price of doing the right
   thing: minimax typed both subgoals `{hotel: text}` / `{food: text}` and
   attached the one admitted verifier, which accepts `text`. The kernel is
   right to refuse a gate that cannot read what it gates — the prompt is at
   fault for listing admitted verifiers without saying what each accepts.

   **Acted on, then re-measured against the same tasks and configuration.**
   `Bind`, `goalInputs`, a shorter reserved list, and verifier types in the
   prompt:

   | | before | after |
   |---|---|---|
   | parsed | 44/48 (92%) | **47/48 (98%)** |
   | admitted | 42/48 (88%) | **46/48 (96%)** |
   | models at 100% admitted | 0 | **2** |
   | typed subgoals | 6/17 (35%) | **7/13 (54%)** |
   | punted joins | 0 | 0 |
   | `let x = hole …` | unparseable | **23 uses** |
   | `inputs { … }` | did not exist | **21 uses** |

   Both new forms were adopted immediately and heavily, and the workaround
   that motivated one of them is gone: on the dependent-halves task all three
   models now compute the framework once and pass it by name, where the same
   model previously inlined the whole string into both objectives.

   The interesting number is that **forks went down**, 9 to 6, and that is the
   change working rather than failing. The three-cities task went from forked
   by about half the replies to forked by none: given a cheaper way to defer,
   every model wrote three searches inline and deferred only the writing.
   Forking it had meant three isolated child elaborations to make three tool
   calls. A hole that binds is the construct that was missing, and its absence
   was being paid for in fan-out.

   The two remaining failures are both worth having. One is a plan that ends
   in `let x = hole …` with nothing after it — a plan must still produce a
   result, and the new form made it possible to forget that. The other is
   structurally the best plan in any run — zero-call bind for the unknown
   topic, three searches, a summarising bind taking all four bindings through
   `inputs`, a send — and it spends four calls against a ceiling of three.
   That is arithmetic, not a misunderstanding.
   **Steps 1–7 built a complete plan core that nothing calls.** Worth stating
   plainly, because the original step 8 assumed otherwise: `frontPrompt` has no
   caller in `src/`, `executePlan` is invoked only by tests, `Reconcile` is a
   pure function nobody consults, and `recordChildSpawn` writes a table with no
   writer. The sequence below is the wiring, and it is ordered so that each step
   ships dark — doing nothing at all until the step after it arrives.

8. **Everything said about a running turn goes to the front model.** Delete
   `classifySupplement`. When a turn is running and a message is absorbable, it
   lands in that turn's inbox; the front model reads it and decides whether to
   answer it, ignore it, or change what it is doing. The verbs stop being a
   router's codomain and become the front model's action space, which is where
   ADR 002 always described them living.

   This dissolves rather than improves the targeting problem ADR 002 called "a
   present-tense correctness gap": if the front model can address two things in
   one reply, mis-routing stops being a failure mode and becomes extra context.
   It also removes the last place a cheap classifier could speak for an
   expensive one.

   Two costs, both accepted deliberately. **Parallel dispatch disappears** — a
   second question no longer gets its own concurrent turn. That is a repair, not
   a regression: two turns in one group cannot see each other, may both speak,
   and interleave their output; parallelism belongs inside a plan where it is
   structured. **Latency** — an unrelated question waits for the next decision
   point. Bounded by one front-model round, and shrinking as steps 9–11 make
   decision points denser and move slow tools into children.

   Ships dark in the sense that matters: no plan is required for it, and the
   behaviour it removes was itself an inference.

9. **`plan` becomes a tool the front model may call.** Not a host heuristic
   deciding which turns deserve a plan — models already write plans unprompted
   before hard work, and asking a cheap classifier to guess what the expensive
   model already knows is the same mistake step 8 deletes. The front model does
   two searches, sees the shape of the problem, and calls `plan`. Never calling
   it is today's behaviour exactly, which is what makes this shippable.

   The dialect guide is ~4k tokens and cannot ride in every turn's system
   prompt; it arrives through the progressive disclosure the skills system
   already implements. One extra round trip, paid only by turns that plan.

    **The catalog bridge landed first, and it found the real bottleneck.**
    `Max.Plan.Catalog` joins hand-written plan schemas against the live tool
    registry. Writing them is the work, and it is per-tool: a tool returns
    `Value` and *nothing in max says what shape*. The argument side is declared,
    because the model needs a JSON Schema to call anything; the result side
    never had to exist, because a result went into a context as text and a model
    reads whatever arrives. A plan cannot — `hits[0].title` must type-check
    before anything runs — so each plannable tool's result is read off its
    implementation by hand.

    So the plannable set is a list, not a filter over the registry, and it
    starts at two. A tool absent from it is one nobody has read closely enough
    to say what it returns, and guessing is worse than omitting: a wrong result
    schema type-checks plans against a lie and surfaces as a null at runtime,
    which is precisely what the kernel exists to prevent. Inputs are declared
    twice — here and as the tool's JSON Schema — so the derivation nobody wants
    in production sits in `Max.Plan.CatalogSpec`, making drift a build break.

    This resizes step 10: connecting the executor is small, and *making enough
    of max plannable to be worth executing* is the part that scales with the
    tool count.

10. **Execute plans for real.** Done for the front-of-house path, together with
    step 9, because the two do not separate: a plan tool whose plans do not run
    is either theatre or a data-collection instrument, and the model would still
    have to do the work by hand.

    `plan_guide` returns the dialect with this turn's real catalog and ceilings
    in it; `plan_run` parses, validates and executes, and only the `done` value
    comes back. The seam was the interesting part — a tool's `toolRun` sits one
    effect layer *below* `Tools`, so `executePlan` cannot run inside an ordinary
    tool; but `runTools` nests, so a plan runs in a sub-catalog built from the
    plannable subset of what this dispatch already resolved. Same effect row,
    same authorization, same journal — and the subset never contains `plan_run`,
    so recursion is impossible by construction rather than by a guard.

    **Measured against a real model, and the answer is sharply conditional.**
    Two prompt shapes, five runs each, deepseek on the production tool schemas:

    | task shape | reached for `plan_guide` |
    |---|---|
    | three independent lookups | **0/5** |
    | explicitly multi-step, with a dependency | **5/5** |

    The zero is right, not a failure. Three independent searches are already
    parallel as native tool calls, and a plan would buy nothing but an extra
    round trip for the guide. What a plan buys is *dependency* and *projection*
    — and on that shape the model took it every time, batching `plan_guide`
    alongside the `memory_list` call it knew it would need.

    The plan it then wrote reads memory, projects a preference out of it,
    synthesises three queries with `concat`, and formats six projected fields
    into one string: four calls against a ceiling of four, zero holes. Twelve
    search results passed through it and none entered the model's context.

    **It was refused on the first attempt, and the kernel was wrong.** The model
    wrote `memory_list@1({ scope: "group" })`; synthesis gives a text literal the
    type `text`, `admits` rightly refuses text where an enum is expected, and
    the grammar has `enum(…)` as a type with *no literal form for one*. So there
    was no correct spelling: every enum-typed parameter max has was uncallable
    from a plan, and the model was being told its only option was wrong.
    Literal membership is decidable in the checking direction and unknowable in
    the synthesising one, which is the ordinary reason a bidirectional checker
    keeps them apart. Fixed there; the same plan is now admitted.

    **An admitted plan is now written down.** `plan_run` opens revision 1
    against the turn that produced it, before executing rather than after: the
    row records what was *admitted*, and an admitted plan that then died is
    exactly the one worth having. It is also the identity later work hangs off —
    spawn edges reference a plan id, a steer replaces a head revision, and
    neither exists until somebody writes the first one. Step 3 built these
    tables deliberately ahead of the executor and left them with no writer; this
    is the writer. Best-effort and injected as a `PlanRecorder`: the plan is
    admissible whatever the database says, and letting bookkeeping veto work the
    kernel approved would trade an answer for a record.

11. **Dispatch fork children.** `Reconcile` gets a caller and a scheduler that
    acts on it. `goalInputs` and `goalResources` resolve from schemas to actual
    values and handles at spawn — `childEnv` already does the static half.

    **Not a small increment on step 10, and the reason is structural.** A tool's
    `toolRun` has no `LLM` in its effect row, so a child cannot be elaborated
    from inside `plan_run` — and it should not be even if it could. ADR 002
    separated durable child turns from a light in-plan `Fork`/`Join` and this
    ADR kept that separation; a child elaborated synchronously inside a tool
    call has no spawn edge, cannot be stopped, does not survive a restart, and
    cannot be reconciled when the plan it belongs to is revised. It would be the
    light version wearing the durable one's name.

    So step 11 is the move this ADR has been describing all along: plan
    execution stops living inside one tool call and becomes a durable object the
    dispatch loop drives — `AtFork` suspends instead of ending, the scheduler
    dispatches, and the plan resumes on a wake. Everything §"waking is
    elaboration" and §"a waiting plan is an armed suspension" describe is that
    step, and revision 1 having a writer is its precondition.

    **Widening the plannable set does not substitute for it, and the reason
    corrects an earlier reading of the 0/5.** Fork earns its scheduler when a
    child can do what a plan cannot — iterate, judge, or block on something slow
    — which suggested making the slow tools plannable first. That is backwards.
    Until there are children, a slow tool in the plannable set only lets the
    *front* model's own inline plan block for thirty seconds, which is the thing
    §"the front model keeps the fast tools" exists to prevent. Slow tools arrive
    *with* step 11 or after it, never before.

    So the set widened along the axis that helps today: fast conversation reads.
    `get_message_by_id` and `context_search` join it, and both were declarable
    because each has exactly one success shape — `contextSearchSummary` already
    calls itself the stable model-facing shape and is kept pure to stay that
    way. Four tools, all drift-checked against the live JSON Schema, all
    agreeing.

    **Two tools were looked at and refused, which is the more useful result.**
    `browser_navigate` and `browser_snapshot` return whatever the browser
    container handed back; max does not constrain it, so there is no shape to
    declare. `view_zhihu` has a clean `{url, text, note}` *and* a fallback
    branch returning the raw payload when it does not recognise one. Declaring
    either would type-check plans against a shape the tool does not always
    produce, and the failure would land at runtime on a projection — the exact
    error the kernel exists to prevent, reintroduced by its own catalog.

    Which sharpens what "make a tool plannable" costs. It is not *read the
    implementation and write the schema down*; it is **give the success path one
    total shape**, and that is a change to the tool. Most of max's tools were
    written for a consumer that reads whatever arrives, so having one shape was
    never a requirement. Now it is, for any tool a plan may call.

12. **Concurrency and child context projection**, only once the shape holds.

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
