# ADR 002: Partial Plans and Adaptive Elaboration

- Status: Proposed — split scope, **partially superseded by
  [ADR 007](007-plans-as-orchestration.md)**. The journal contract (its own
  section below) ships with v1.0 as the substrate of the durability roadmap
  (issue #14); the elaboration machine itself — validator, frontiers,
  horizon above 1 — remains post-1.0. v1.0 is a convergence release; this
  split lets it converge onto the machine's substrate without opening the
  machine's front.

  ADR 007 retires this ADR's information-flow programme, narrows the
  validator's claim, inverts the motivation for child plans, and replaces
  integration steps 7–10. Sections affected are marked inline; ADR 007's
  "What this retires" table is the authoritative list. Everything not marked
  stands.
- Date: 2026-08-03; journal contract and post-cutover revisions 2026-08-05;
  sandbox observability, narrator, and continuity (ADR 005)
  cross-references 2026-08-06; elaboration surface, pull-based hole
  views, harness-write effects, and monitor trigger provenance (ADR 006)
  2026-08-09; partial supersession by ADR 007 marked 2026-08-10.

## Context

Max currently uses a conventional model-driven tool loop in
`Max.Effects.Agent`. On every round it drains feedback, sends the complete
bounded message/tool trace to the selected LLM, and receives either a final
answer or one or more tool calls. Tool calls run concurrently through the
turn-scoped `Tools` effect, their results are appended as protocol messages,
and the model computes the continuation on the next round. The hard limit is
200 LLM rounds per dispatch.

This design is robust and adaptive: every tool result is visible before the
model chooses the next action. It is also expensive for deterministic stretches
of work. Each semantic no-op between tool calls pays another provider round
trip and expands the attention scope with the accumulated wire trace.

Max already has boundaries which a more ambitious executor must preserve:

- `ToolContext` fixes turn identity and capabilities; conversation-aware tools
  derive their host-owned `ConversationScope` rather than accepting an
  authority-bearing group id from the model.
- `Tools` resolves model-visible JSON schemas to concrete effectful runners.
- `AgentEvent` separates progress, debug facts, and streamed final text;
  `ReplySend`/`Outbound` remain the only visible-output boundary.
- `TaskRegistry` provides cancellation, mid-turn feedback, and in-flight
  ownership, but running turns are intentionally ephemeral across restart.
- Context is already planned by token and can present full, compressed, or
  retrieval-expanded views without changing source conversation state.

Max in fact already operates the two extreme policy points: the tool loop
is horizon-1 elaboration, and the sandbox is opaque infinite-horizon code
execution — the "code mode" shape. What is missing is the typed middle.
The Plan IR is code mode with holes and an effect system: it recovers the
mid-flight adjustability that opaque code loses, without paying a model
round for every deterministic step.

The design question is whether ordinary tool calling, dynamic workflows, and
code-style execution should become three separate orchestrators, or policies
over one execution machine.

## Decision

### Model the loop as execution over a partial plan

Max will treat an agent loop as interleaved execution and elaboration over a
pure partial-plan IR:

- **execution** (`↝ε`) advances an already elaborated plan without asking an
  LLM to compute its continuation;
- **elaboration** (`↝λ`) asks an LLM to replace a typed `Hole` with another plan
  segment, which may itself end in further holes.

Execution is *non-elaborative*, not necessarily cheap, pure, deterministic, or
semantics-preserving. A tool can be slow, observe changing state, produce a
partial side effect, or return an ambiguous delivery outcome. The executor and
journal must retain those distinctions.

The following types are illustrative rather than a committed Haskell API:

```haskell
data Goal env a = Goal
  { objective      :: Text
  , expected       :: Schema a
  , acceptance     :: [VerifierRef a]
  , allowedEffects :: EffectBudget
  , authority      :: AuthorityClass
  , contextDeps    :: DependencySet
  }

data Plan env a where
  Done   :: Expr env a -> Plan env a
  Call   :: ToolRef input output
         -> Expr env input
         -> Plan (output ': env) a
         -> Plan env a
  Guard  :: Predicate env -> Plan env a -> Plan env a -> Plan env a
  Hole   :: Goal env a -> Plan env a
```

`Goal`, tool inputs, and tool outputs must retain their expected schema. The IR
must not collapse every binding to an unchecked JSON `Value`, even if its first
implementation uses reified JSON schemas internally. An elaborated replacement
must type-check against the exact environment and result expected by its hole.

`Expr` and `Predicate` are not escape hatches. They form a versioned, total,
pure expression language with no I/O, recursion, unbounded iteration, or host
calls. Its initial vocabulary is deliberately boring: constructors, field and
index projection, comparison, boolean composition, and bounded collection
combinators with a static cost model. General computation remains an explicit
coarse sandbox `Call` (or a future `Compute` node) whose limits and effects the
validator can see; it is never smuggled through an expression evaluator.

Likewise, `Done` produces a candidate result, not proof that the objective was
met. A goal completes only when the value matches `expected` and its
host-resolved acceptance verifiers pass. Exhausted elaboration, execution,
token, or wall-clock fuel suspends or budget-exhausts the goal; it never turns
an unfinished value into success. The first short-plan slice may use an empty
verifier list, but the distinction is part of the IR before durable goals or
monitors depend on it.

`VerifierRef` names a host-registered, versioned verifier with its own
schema, dependency fingerprint, effect declaration, timeout, and output
limit. The model may select only verifiers admitted by the enclosing
goal; emitting shell text does not create a quality gate. Pure verifiers
run in the host's completion checker, while an effectful gate uses the ordinary
journaled tool boundary. An unavailable, stale, failed, or outcome-unknown
verifier cannot certify completion. A failed verifier re-holes the goal
with its bounded output as scoped evidence (taint-carrying as written;
scope-only since ADR 007) and consumes the
ordinary elaboration-attempt fuel. This is the general deoptimization path for
an invalid postcondition, not the `Guard False` path: a valid false predicate
merely selects the Plan's alternate branch.

Plans contain stable `ToolRef`s, expressions, bindings, and node ids—not the
current `Tool es` runner closure. Real execution resolves a reference through a
dedicated plan-tool execution boundary backed by the existing `Tools` effect.
Preview and symbolic interpreters use the same plan without acquiring the real
runner.

Arbitrary Haskell, shell, or Python is not the Plan IR. A sandbox tool may
remain one deliberately coarse capability boundary, but hidden effects inside
an opaque script cannot be advertised as statically inferred fine-grained
effects. That conservatism binds only the declaration layer; what an exec
*did* touch is separately observable after the fact (its own section below).

The executable form and the authoring surface are separate decisions,
and only the first is fixed above. The concrete syntax in which a model
*emits* an elaboration should be a small, restricted, pseudo-code DSL
whose total parser returns either the whole IR or a rejection — never a
partially interpreted plan. RLM-style harnesses of mid-2026 show that
frontier models can use a native programmatic register effectively, but
they do not by themselves prove that this restricted dialect is more
reliable than a schema-shaped AST. That is an implementation hypothesis
the recorded replay set must test. Nothing in the conservatism above
moves: the DSL admits exactly the IR's constructs, the validator sees
only the parsed plan, and a failed parse is an ordinary elaboration
failure, not a license for looser interpretation.

### Existing tool calling is the fallback policy

The current `Max.Effects.Agent` loop remains the production baseline and the
deoptimization target. It is observationally equivalent to elaborating only a
short prefix whose continuation is immediately another hole: the continuation
is represented in the accumulated LLM/tool trace instead of as a long-lived
Plan value.

This is a useful correspondence, not a claim that raw traces are isomorphic.
Different modes have different wire messages, hidden local computation,
concurrency order, retry events, and child scopes. They must instead project to
one normalized execution-event algebra for replay and comparison.

### Use a semantic frontier, not only an integer horizon

Planning depth and elaboration context are independent policy dimensions:

```haskell
data PlanPolicy = PlanPolicy
  { stopBefore :: AbstractState -> PlanNode -> Maybe StopReason
  , maxDepth   :: Int
  , renderView :: Suspension -> Context
  }
```

`maxDepth` is a budget fuse. The actual horizon ends at a semantic frontier,
including:

- a judgment that depends on an unknown tool result;
- a reflective capability or context discovery;
- an effect requiring approval;
- a dynamic resource target that cannot be bounded statically;
- an authority or information-flow boundary;
- an unknown result shape, stale dependency, or exhausted budget;
- a liveness window: in a live group chat, `↝λ` boundaries are also where
  the agent can let new traffic or mid-turn feedback redirect the
  continuation, so the horizon is socially bounded as well as reflectively
  bounded.

The initial policy mapping is:

| Mode | Frontier | Elaboration view |
|---|---|---|
| Current tool loop | after each result-dependent step | full capped turn trace |
| Dynamic partial plan | next semantic/authority frontier | compact trace plus selected evidence |
| Code-style segment | farthest verified frontier | schema, request, and explicit dependencies |

`renderView` is a push-pull contract, not a host-side guess. The pushed
half is a bounded digest: the goal, selected evidence, an aggregate of
older completed work, and a fixed-size recent-node suffix. The pulled
half is addressable: a journal result or turn record that is both in
scope and useful to the model may render as a canonical handle under an
extended ADR 004 grammar. The current `context_expand` implements only
the episode namespace; `t#` (ADR 005) and a result namespace are future
members of the same scoped expansion surface, not present capabilities.

A result handle is syntax, never authority and never the Plan's typed
binding. It resolves under the current conversation, structured resource,
and information-flow scopes to a `ValueRef a` carrying at least the
producing journal row (and Plan node when one exists), output schema,
owning scope, content digest and length, representation metadata, and
retention state. (Provenance/taint as written; dropped by ADR 007.) The handle is turn-qualified rather than a
bare plan-local `node_id` or a
content digest: the same template node can run in more than one turn,
and the same bytes can occur in more than one conversation, but
`t#<n>:r<execution_ordinal>` names exactly one result-bearing journal row
within its group.
The physical `BlobRef` stays internal. When parsed into a candidate
Plan, a result handle becomes a `ValueRef` only after the validator
proves its scope and exact schema against the receiving binding.

Pulls are read-only and grant zero new authority, but they are not
zero-cost: they consume I/O, context tokens, and usually an LLM round.
One `↝λ` therefore runs as a bounded elaboration session: render the
digest, service a limited number of scoped inspect/expand requests, then
parse and validate one candidate segment. The session has separate
round, byte, token, and wall-clock fuel, and the host records the actual
read-set as the hole's `contextDeps`. A dependency that changes during
the session invalidates the candidate before execution. The host still
chooses and prices the bounded digest; pull removes the need to predict
the exact evidence set, not the host's responsibility for scope or
budget.

“Infinite horizon” is not a configuration value. It means that validation found
no earlier frontier. Different horizons may produce different model decisions
and answers; changing policy is not a semantics-preserving optimization like a
compiler optimization level.

### Validate plans before execution and authorize every effect at execution

> **Partially superseded by ADR 007.** The list of checks below is narrowed to
> types, budget arithmetic (including the sibling summation `Fork` introduces),
> and handle resolution. Authorization at `invokeTool` stands unchanged — it
> was always the real boundary. The two paragraphs marked below are retired.

LLM elaboration is untrusted generation. Max will add a deterministic validator
which acts as the kernel boundary missing from the Lean elaborator analogy. It
must reject a plan before execution when any of these checks fail:

- tool existence and catalog/schema version;
- input/output schemas, bindings, and forward references;
- effect ceiling and resource-scope constraints carried by the hole;
- current `ToolContext`, `ConversationScope`, and host permission policy;
- loop, fan-out, call-count, token, media, and wall-clock budgets;
- unsupported opaque or dynamically unbounded behavior.

An initial effect vocabulary is:

```haskell
data PlanEffect
  = EffRead ResourceScope
  | EffWrite ResourceScope
  | EffSend ConversationScope Audience
  | EffLLM
  | EffReflect CapabilityNamespace
```

Effect inference returns an over-approximation including target scope and
multiplicity. “May send” is insufficient for approval; a preview must bind the
normalized effect manifest, authority, and Plan hash. A changed or deoptimized
residual plan requires revalidation and, where applicable, new approval.

Static validation does not replace runtime authorization. Every actual tool
invocation still passes through the same scoped host checks as the current
agent loop. Model-produced importance, effect annotations, ids, or claims never
create authority.

> **Retired (ADR 007).** Both paragraphs below. Ceilings are a budget, not a
> defense: what contains a poisoned page is not seeing it while holding a
> capability — a narrowed catalog handed to a quarantined child at spawn. And
> the information-flow prerequisite guards a capability max does not have:
> `Recall` scopes every memory read by `conversation_id` in SQL, so there is
> no cross-conversation read for a label to catch. Taint is deleted from the
> IR.

Effect ceilings are also the substantive prompt-injection defense at this
layer: an injected instruction can make the model elaborate an arbitrary
plan, but not one that both exceeds its hole's declared bounds and passes
the kernel.

Effect bounds also do not replace information-flow policy. Before Max exposes
secret-bearing or cross-conversation read capabilities to plans, values need
provenance/taint labels preventing restricted data from flowing to a public
reply or broader send target.

`EffReflect` invalidates assumptions about the elaboration environment and
therefore creates a revalidation frontier. It requires another LLM round only
when the existing plan has no verified generic mechanism for consuming the
discovered capability. Tool search is not mathematically required to be
multi-round, although it usually becomes so when only the model can interpret a
new schema.

### Sandbox effects: declared ceilings versus observed manifests

The coarse-boundary rule above answers only the validation-time question:
what a sandbox node may be *declared* to do, a priori, for the effect
ceiling and approval. Execution-time observability is a different layer
with the opposite freedom: the host cannot infer what an opaque script
*will* touch, but it can cheaply record what it *did* touch.

Every sandbox operation therefore journals an observed manifest alongside
its coarse declared label:

- the full command line, exit code, and wall-clock duration;
- stdout/stderr digests (hash and length) plus the spill path when output
  exceeded the cap;
- a filesystem delta: a marker file touched before the exec and a bounded
  `find /work -newer` sweep after it list the paths the command wrote;
  `docker diff` covers writes that landed outside the work volume;
- the network mode the exec ran under.

Observation grants no authority and weakens no boundary — static
inference stays conservative — but it turns "the sandbox did something"
into rows that resume, the admin console, and the narrator can consume.

One hole is named rather than papered over: the default sandbox network
is `bridge`, so an exec running `curl` is an `EffSend` bypass — an
arbitrary external effect the outbound ledger never sees. Recording the
network mode makes the exposure visible per row; closing it (default
`none`, per-sandbox egress grants, or an egress proxy) is authority work
deferred post-1.0. Until then the effect vocabulary's send story is
honest only for ledger sends. The deferral is dated, not open-ended: the
code-mode evidence (see the rejected alternatives) pushes more work into
the sandbox over time, so this hole should be first in line once v1.0
converges. ADR 006's `ExternalPoll` is a distinct host-managed network
effect: it must record its target, redirect/credential policy, response
digest, and outcome through the journal and need not reuse sandbox
mechanics. Holding that feature until ungoverned sandbox egress is closed
may still be a deliberate defense-in-depth release policy; it is not a
claim that a scoped host probe and an ambient sandbox `curl` are
semantically indistinguishable.

### The journal contract (v1.0 slice)

The execution journal is shared infrastructure, not part of the deferred
machine. Its consumers include the horizon-1 production loop (durability
roadmap L2–L4, issue #14), crash-resume replay, the tool-trace digest,
the narrator (its own section below), the continuation view (ADR 005),
monitor arm/fire audit (ADR 006), and — later — this ADR's executor. **It
ships with v1.0; the machine does not.** At horizon 1 the plan is absorbed
into the trace, so the loop needs no `Plan` type to write conforming rows;
it needs only this schema. A monitor's mutable current state remains in
its own table; the journal records its effects and history rather than
becoming the scheduler's state store.

Rows are normalized execution events, never provider wire messages:

- `journal_id` is the canonical row key and stays internal. Each turn-owned
  execution or input instance also receives a persisted, per-turn
  `execution_ordinal`, immutable across that row's state updates, with `UNIQUE
  (turn_id, execution_ordinal)`. A retry or repeated Plan node that creates a
  new row receives a new ordinal; `node_id` remains the logical identity.
  Under ADR 004's scoped-runtime amendment, the model-visible result handle is the
  alternate key `t#<turn_ordinal>:r<execution_ordinal>`. Resolution supplies
  the current conversation, resolves the persisted turn ordinal, then the
  execution ordinal, and rechecks resource and information-flow scope. Rows
  without results do not render a result handle. This scoped form is an
  ownership/provenance choice, not a claim that ADR 004 forbids dense global
  ids.
- `node_id` is stable text identity. The horizon-1 loop writes
  `turn:<turn_id>:<step>`; a future plan executor writes Plan-hash-derived
  ids into the same column, with `plan_hash` nullable and empty at horizon
  1 — both id spaces coexist without migration.
- state ∈ started / rejected / succeeded / failed / committed /
  outcome-unknown;
- normalized input plus tool/schema version; result provenance or bounded
  failure detail; an idempotency key where the effect supports one;
- conservative host-assigned effect labels from the `PlanEffect`
  vocabulary;
- guard/validation decisions and the elaboration or deoptimization reason.

Large results spill uniformly, not only for the sandbox: a result
exceeding its inline cap lands as a scoped artifact. The journal row
retains its `ValueRef` metadata and internal blob reference, while the
model sees only the result handle described above. The resolver reads
through the producing row, rechecks current scope, and returns a bounded
typed view; it never treats possession of a blob digest as authority.
Artifacts required by a live turn or durable Plan are retained for that
lifetime. A missing or expired artifact is a stale dependency that
re-holes the Plan, not an invitation to execute with an empty value. The
journal remains the durable audit/index; the artifact store owns bytes.

Alongside effect nodes the journal carries zero-authority fact rows:
`model_note` records the model's in-band tool-round narration as evidence
for the narrator and the admin timeline, never as something to execute.

Wire items may additionally be archived verbatim as blob-referenced
cache artifacts for ADR 005's replay tier. An archive is disposable —
TTL'd, model-family-bound, never load-bearing: the normalized rows stay
the only record that replay and audit may trust.

Send effects do not get a second journal. Since the ADR 003 cutover, the
canonical ledger is already the durable commit point for every visible
message: `enqueueOutbound` publishes transactionally, and per-endpoint
deliveries carry accepted/confirmed/outcome-unknown with echo
reconciliation. A send node journals only the linkage
`node_id → canonical_message_id`; the durability roadmap's L3
(`turn_id`/`chunk_index` on outbound rows) *is* that linkage, not a
separate mechanism. Other effect classes journal their own two-phase state
(roadmap L4).

Sandbox operations are roadmap L4's first real tenant. An exec writes its
`started` row — command, sandbox id, timeout, network mode — before
`docker exec` launches, so process death mid-command leaves exactly the
outcome-unknown state whose resume view is the durability roadmap's
injection text; completion updates the row with the observed manifest
above. Journal rows record events, not state, and a shell exec is
nondeterministic — replaying the journal can never reconstruct the
volume. The durable unit is the volume itself: sandbox lifecycle metadata
moves to a `sandboxes` table, the in-memory registry becomes a
write-through cache, and boot reconciles instead of reaping — adopt a
live container, rebuild a dead one from image plus surviving volume, mark
the row destroyed only when the volume is gone — with TTL-based GC
replacing the boot reap. The volume carries the current state; the
journal carries the history that produced it. Per-exec volume snapshots
stay out of scope until plan replay/fork needs them. The mechanics belong
to the durability roadmap (issue #14); this contract fixes only the row
semantics.

Durable journals store erased plans and traces. Resume re-runs the kernel
— typecheck, effect bounds, scope authorization — before trusting anything
read back (the `Max.IR` lesson: serialization pinned to one phase, checked
on load). A row that fails the check deoptimizes to a hole instead of
crashing the resume.

One reservation for the multi-principal section below: turn results are
addressable journal values, and a future `turn_edges` table
(`from_turn`, `to_turn`, `kind`, `created_by`) will reference them —
so the v1.0 implementation keeps `turn_id` foreign-key friendly. The
edge table arrives with ADR 005's continuation slice — `fork-from` is
its first tenant, in the degenerate sequential case; the concurrent-turn
verbs stay post-1.0.

### Crash is deoptimization

Process death is a Fault like any other. Recovery re-holes the plan at the
crash point with the journal's facts in the hole's view: completed
results, committed sends, and outcome-unknown tool states — whose view
text is exactly the durability roadmap's
`[工具执行状态未知：服务重启]` injection. An invalid guard evaluation or
failed validated postcondition, operator feedback, and crash therefore share
one deopt path; a valid `Guard False` still takes its ordinary alternate branch.
The horizon-1 loop exercises the deopt path in production before the machine
ever raises the horizon.

Resume granularity is the turn, by construction: "continue exactly where
the model was" is a false concept for a nondeterministic elaborator. What
must be exact is the effect state, and that lives in the journal and the
ledger.

A generic fault must not become `reHole` and replay. Only an invalid guard
evaluation, a failed validated postcondition, pre-effect rejection, invalid
result shape, process death, or other known-safe suspension may deopt directly.
Committed and outcome-unknown effects resume after the recorded node;
compensation is explicit workflow logic rather than an implicit retry.

Elaboration and execution have separate fuel. Elaboration fuel prevents a
`deopt → elaborate → fail` loop; execution budgets bound nodes, loops, fan-out,
and wall time.

### The narrator is a journal projection

Progress narration today is the model's own tool-round text forwarded
verbatim to the chat. That couples two jobs that want different
registers: the working model thinks out loud ("我看看啊…"), while the
user wants a terse, truthful account of where the turn stands. The
narrator decouples them:

- The model's in-band narration is demoted to evidence: it journals as a
  zero-authority `model_note` row and is never shown verbatim.
- The narrator consumes the journal and nothing else. Its input is the
  rows since its last watermark — node transitions, deopts, absorbed
  feedback, `model_note` color; its output is at most one short progress
  message. Journal rows are ground truth and the note supplies only
  intent flavor, a structural bound on hallucinated progress.
- Rendering uses a small model, falling back to the deterministic
  tool-debug template when that fails.

Triggering is edge-triggered on material transitions with a debounce,
never level-triggered per round: a node failure or retry, a deopt or
absorbed feedback (the direction changed), a long-running exec starting,
or elapsed silence past a threshold with newly completed nodes. A pending
narration is cancelled when the final answer lands first, and the first
tool round triggers nothing — a median 10–60s turn should say nothing at
all. Narration draws a per-turn budget, making restraint structural
rather than prompted.

The cost is explicit. Streamed text and narration are currently
disambiguated only after the response ends, which is the entire reason
the sent-prefix watermark exists. Under the narrator, tool-capable calls
no longer release paragraphs mid-response — final answers give up
intra-response streaming (the forced tool-free final call may still
stream) — and in exchange the sent-prefix bookkeeping and the
feedback-raced-a-streamed-answer requeue path are deleted: nothing was
released, so a late note can always re-answer for free.

Narrator output is an ordinary reply through the send path, so it lands
in the canonical ledger with the send linkage like any visible message —
what the narrator said is itself replayable. The narrator does not wait
for the machine: it consumes horizon-1 rows from day one, and serves as
an early second consumer that exercises the journal schema before the
executor arrives.

### Feedback, cancellation, reflection, and policy changes invalidate residual work

The executor checks the existing task inbox and cancellation state between plan
nodes, not only at LLM boundaries. New `!feedback`, an absorbed supplement, or
a poke can invalidate the planned continuation and force a hole whose view
includes the new note. `!kill` remains asynchronous and must cross both the
elaborator and executor without being converted into an ordinary tool failure.
(Feedback is one verb of the routing lattice defined in the next section;
this section describes its executor-side mechanics.)

Other deoptimization triggers include:

- a guard that cannot be evaluated within its validated schema/cost contract
  (a valid false predicate merely selects its branch), result-schema failure,
  or acceptance-verifier failure;
- tool catalog, skill, policy, or prompt version change;
- stale context dependencies;
- a newly discovered capability;
- a narrowed authority/effect budget;
- token, media, call, or time pressure.

The residual plan is revalidated under the current policy. Max may always tier
down to the existing one-step tool loop. Tier-up is allowed only for later
segments or a future dispatch; already observed effects are never regenerated.

### Multi-principal concurrency: the group is a scheduler

A group chat is several principals submitting, steering, and observing
work through one conversation. The machine does not change; what multiple
humans add is **edges between turns**. Concurrent turns are concurrent
`Config`s over one shared world — the canonical ledger plus shared
resources — and every human utterance is, relative to each in-flight turn
and to the dispatcher, a routing event.

Today's `!feedback`/`!btw` pair is a two-value routing policy: the poles
of a verb lattice whose middle is missing. The full vocabulary:

| Verb | Meaning | Machine interpretation |
|---|---|---|
| **steer** (today's feedback) | redirect an in-flight turn | inbox entry + forced hole at the next node |
| **annotate** | add a fact to a turn without interrupting it | inbox entry, consumed at the next natural hole — no forced `↝λ` |
| **depend** | "when that finishes, use the result for Y" | new turn whose initial hole carries a cross-turn dataflow edge |
| **fork-from** | new independent task consuming a turn's result | new turn, initial view includes the result — provenance, not blocking |
| **abort** (today's `!kill`) | terminate | existing semantics |
| **observe** (today's `!btw`, and most chatter) | record only | ledger ingest, no task effect |

steer versus annotate is the quietness philosophy expressed in machine
terms: most supplements are not worth a forced elaboration round.

**Targeting.** With concurrent turns, an untargeted steer is ambiguous —
this is a present-tense correctness gap, not a future feature. The natural
targeting UI is the reply: answering a bot message routes to the turn that
produced it, and the journal contract's send linkage
(`node_id → canonical_message_id`, roadmap L3) is exactly the table that
resolves a replied-to message back to its turn. Explicit command syntax
remains the precise fallback; the intent layer classifies verb and target
for plain language, reusing the existing command/natural-language dual
track.

**Dependency edges are journaled typed futures.** A turn's result is an
addressable journal value, so a depend edge is one row in the same
journal — cross-turn dependencies are crash-safe by construction. A failed
or timed-out dependency needs no new mechanism: it is one more attributed
fact in the dependent hole's view, and the model decides whether to
abandon or reroute — the same deopt path as an invalid guard/postcondition,
crash, and feedback. Cycle detection runs at edge creation and fails closed.
Parent `Spawn` edges and sibling depend/fork edges are two kinds in one
`turn_edges` table; the child-plan section below becomes a special case of
the turn graph.

A monitor (ADR 006) is a deferred continuation, but a world event is not
smuggled into `turn_edges`: that table continues to relate turns only.
Arming persists the intent (goal, typed trigger spec, effect ceiling).
On fire, the durable `monitor_fire` row names the triggering ledger row,
clock tick, or polled observation and links the fresh turn it admitted;
the fresh turn writes `fork-from` to the arming turn when one exists.
The fire record supplies trigger evidence to the initial view while the
turn edge supplies task provenance. Execution and deoptimization after
admission reuse the ordinary machinery; durable trigger evaluation,
deduplication, and admission remain ADR 006's explicit responsibility.
For `ExternalPoll`, ADR 006 materializes the admitted observation as an
immutable, turn-owned `trigger_input` result row; its result handle therefore
still names a producer inside the fresh turn rather than the pre-turn poll.

**Authority and arbitration split.** The host decides *who may create
which edge* to whose turn, through the existing role layers (abort
restricted to the initiator and admins; steer/annotate per group policy).
The model decides *what conflicting input means* — but only because every
inbox fact carries attribution: who said it, in what role, when. "The
initiator said stop" versus "a bystander disagreed" is social judgment the
model weighs; it is never a rule the machine hardcodes. Attribution is the
bridge between the two layers, and model-asserted authority still creates
none.

**Effect scopes double as the lock set.** Concurrent sends are already
ordered by the delivery outbox; concurrent memory writes are already CAS.
The one genuinely shared mutable resource is the per-group sandbox: at
horizon 1 it takes a conservative per-group lease (journal-visible); once
effect inference exists, inferred `EffWrite` scopes give fine-grained
conflict detection for free.

**Zero-ceremony principle.** Verbs are inferred, never demanded; observe
is the overwhelming default; nobody types task ids in casual chat. The
machinery succeeds precisely when it is invisible until two people's work
actually collides. Depend and fork edges only matter for long-running
turns — the median 10–60s turn never creates one, and the machine does
extra work only when an edge exists.

Everything in this section is post-1.0 except the journal-contract
reservation above and the `fork-from` edge, which ADR 005 realizes for
the sequential single-principal case.

### Child plans narrow view and authority

> **Superseded by ADR 007**, which inverts this section's premise. Orchestration
> is the primary motivation for child plans; narrowing is what makes delegating
> safe, not the reason to delegate. `Fork` is the first implementation slice
> rather than a deferred one. Narrowing is enforced by intersection at spawn
> (`child = parent ∩ declared`) rather than by validating a declared subset.
> Sibling communication is refused outright, not permitted under a minted
> capability. Information-flow clearance leaves the minted `AgentRef` with the
> rest of taint; scope, catalog and ceiling remain.

A future `Spawn` is primarily an elaboration-scope construct, not merely a
parallelism primitive. A child receives its own trace, context projection,
authority, effect budget, cancellation scope, and tool catalog. It returns a
typed value plus provenance to the parent; hidden child context does not become
ambient parent context.

Turns and children are host-owned actor endpoints, not social
principals. A child has no independent human authority: its host-minted
`AgentRef` carries an explicit subset of the parent's conversation
scope, tool catalog, information-flow clearance, and effect ceiling.
Attribution always names the human principal whose delegated authority
the actor is consuming.

Four events stay distinct. `Spawn` admits a child and creates the parent
edge; `depend` subscribes a consumer to a producer's typed future; a
completion event fulfills that future with a value plus provenance; and
`steer`/`annotate` delivers an attributed fact through the target's own
inbox abstraction. Completion is not a new dependency edge, and actors
never share an inbox object. A short structured `Fork`/`Join` inside one
Plan is likewise separate from a durable child turn: waiting on the
latter suspends the consumer and resumes it from the fulfillment fact
instead of keeping a worker blocked.

The family registry makes parent, child, and sibling addresses
discoverable; it grants no communication authority by itself. Parent ↔
child messaging may follow capabilities minted at spawn. A sibling edge
requires an explicit parent-granted recipient capability plus the same
scope, taint, rate, and effect checks as every other cross-context flow;
otherwise it could bypass the narrowed views that justified child plans
in the first place. Cross-family and cross-conversation edges remain
refused at the host boundary.

Parallel execution is an additional policy layered on that boundary. It
requires explicit resource ownership, fan-out limits, deterministic result
collection, and cancellation semantics. `Spawn` and unbounded `Foreach` are not
part of the first implementation slice.

### Cache validated templates, not context-bearing plan instances

Max's current skills are static progressive-disclosure instructions, not an
elaboration cache. A future plan cache may store parameterized, validated plan
templates. Its key must include at least:

- normalized goal and expected schema;
- tool catalog/schema hash;
- policy, validator, prompt, elaboration-surface, and model capability
  profile versions;
- effect ceiling and authority class;
- declared template dependencies plus the instantiated, host-observed
  context read-set fingerprint.

A template is instantiated with current scoped values and revalidated on every
use. A context-bearing plan instance is never reused across conversations.
Natural-language Goal text alone is not a safe or useful cache identity.

### Self-refinement is a journaled effect

Skills, prompt notes, plan templates, and (later) child-agent specs form
the harness state: durable objects that shape every future elaboration.
The continual-harness line of mid-2026 agents (Prime Agent's `/refine`)
shows both the value and the failure mode of letting the agent edit that
state. In [Prime Intellect's own Factorio
run](https://www.primeintellect.ai/blog/prime-agent), ambient RCON access
let the agent bypass the game despite an explicit instruction not to
cheat; the refinement loop then turned the exploit into increasingly
efficient cheating skills. The capability boundary provides containment;
versioning and a journal provide review and recovery after the fact.
Neither a prompt prohibition nor an audit row substitutes for removing
authority the actor should never have held.

Concretely, when Max adds self-refinement:

- the base system prompt, validator, authority policy, and effect kernel
  are immutable to model-authored refinement;
- harness writes get their own resource scope (`HarnessScope`) under
  `EffWrite`, subject to ceilings, validation, and role policy like any
  other write; session/turn or conversation scope is the default, while
  global promotion requires explicit administrator approval or an
  offline evaluation gate;
- harness objects use an append-only version store plus a CAS current
  pointer. The journal records the motivating trace, candidate version,
  validation decision, activation, and later outcome — trace-linked by
  construction, not thereby proven beneficial;
- rollback is a CAS activation of a prior immutable version plus a new
  journal event. Replaying audit rows is never the mechanism that
  reconstructs current harness state;
- refinement is an explicit verb, never an ambient background loop, and
  applies only at a turn or hole boundary. A successful activation bumps
  the relevant prompt/skill/template version and forces every affected
  residual Plan to re-hole and revalidate; a cache-key change merely
  prevents reuse and is not itself validation;
- a refined skill or template re-enters through the same validation as a
  fresh one. A proposal that adds executable code or widens tools has a
  stronger promotion gate than a supplemental prompt note.

## Max integration sequence

> **Steps 1–6 shipped as written. Steps 7–10 are replaced by ADR 007's
> sequence**, which puts a durable, steerable plan and a reconciler ahead of
> the executor rather than after it. Step 7's "short, read-only plan segments
> behind a feature flag" assumed the payoff was validated execution of small
> plans; it is fan-out, context isolation, and steering. Step 3's result
> envelope ships without the taint field; step 4's information-flow tests are
> deleted.

Step 0 ships with v1.0, independent of everything below: the journal
contract above, written by the current loop under the durability roadmap
(issue #14). Every later step consumes it unchanged. The sandbox effect
class, the narrator, and ADR 006's monitors all attach to this step —
they consume horizon-1 rows and need nothing from the machine.

1. Define a small pure `Max.Plan` IR with `Done`, typed/schema-checked `Call`,
   `Guard`, and `Hole`; the total `Expr`/`Predicate` language; acceptance
   verifiers; deterministic codecs; and stable node ids.
2. Complete the tool catalog with result schemas, structured resource scopes,
   and effect multiplicity without changing the model-visible current loop.
   Schema versions, coarse effects, parallelism, retry classes, authority, and
   normalized outcomes already exist and are the starting substrate.
3. Add the scoped result envelope and `ValueRef`/artifact resolver, including
   bounded expansion, retention, taint, and observed read-set tracking.
4. Add `Max.Plan.Validate` and pure tests for binding, schema, effect,
   authority, information flow, cardinality, acceptance, and budget rejection.
5. Add the restricted pseudo-code parser and bounded elaboration session.
   Fuzz parse-or-reject behavior; a malformed surface must never produce a
   partial Plan or acquire a looser fallback interpreter.
6. Add a plan-tool executor seam. The real interpreter calls existing `Tools`;
   preview records calls without executing; symbolic interpretation propagates
   result shapes and stops or forks on unknown values.
7. Integrate short, read-only plan segments behind an explicit feature flag.
   `EffSend`, external writes, reflection, dynamic targets, and feedback remain
   mandatory frontiers.
8. Emit normalized plan events through the current Agent event/trace surfaces.
   Recorded replay measures main-model context occupancy, total tree tokens and
   cost, critical-path latency, artifact pulls/bytes, verifier pass rate, deopts,
   duplicate effects, outcome-unknown effects, and answer quality.
9. Expand the allowed frontier only after validator and journal evidence shows
   that the previous class fails closed and deoptimizes safely.
10. Consider approval UI, durable plans, bounded iteration, or child plans as
   separate follow-up decisions.

The production cutover criterion is not fewer LLM calls alone. A plan-enabled
replay set must preserve conversation scope, visible-output behavior,
cancellation/feedback semantics, and answer quality while producing no more
duplicate or outcome-unknown effects than the current loop.

## Consequences

- Tool calling, dynamic workflows, and code-style execution share one IR,
  validator, executor, trace vocabulary, and fallback rather than becoming
  three unrelated orchestration stacks.
- Max can amortize LLM continuation generation across deterministic tool
  stretches and narrow attention to the dependencies of the next hole.
- Dry-run and symbolic modes become meaningful because plans are data, although
  symbolic execution still needs an abstract value domain and must handle path
  explosion or unknown branches honestly.
- The current loop remains available when planning is disabled, validation
  fails, a guard deoptimizes, or a provider cannot reliably produce the IR.
- Group-chat concurrency stops being a special case: multiple principals'
  tasks, cross-task feedback, and task dependencies are edges over the
  same journal, with authority host-checked and conflict arbitration
  model-judged over attributed facts.
- Waiting becomes a first-class durable state: ADR 006's monitors arm
  typed triggers whose fire record admits a fresh turn and whose arming
  turn supplies `fork-from` provenance; reminders collapse into their
  degenerate case. Monitor audit is a third pre-machine tenant of the
  journal beside the narrator and the sandbox.
- Tool metadata, a validator, a journal, and new replay evaluation add
  substantial complexity before large horizons are safe. The journal, the
  send commit point, and the crash-deopt path are shared with (and paid
  for by) the v1.0 durability work, so the machine's residual cost is the
  validator and the elaborator.
- Static effect inference is deliberately conservative. Opaque sandbox code and
  dynamic targets reduce optimization opportunities instead of weakening the
  authority boundary. Observed manifests recover per-exec visibility after the
  fact without pretending the inference got finer.
- Progress UX decouples from the working model's register: narration becomes a
  bounded, edge-triggered projection of the journal, and the streaming/narration
  entanglement — the sent-prefix watermark and the feedback-raced-stream requeue
  path — is deleted rather than maintained.

## Rejected alternatives

### Replace the current loop with arbitrary generated code

Rejected because opaque code defeats precise effect inference, schema
validation, scoped approval, symbolic interpretation, and safe residual replay.
Sandboxing remains useful, but it is a coarse capability boundary rather than
the orchestration IR.

This rejection has acquired stronger opposition since it was written:
[Prime Agent reports](https://www.primeintellect.ai/blog/prime-agent)
95.5% RHAE Best@1 on ARC-AGI-3 with Opus 5 and, in those ARC comparisons,
lower overall token usage than the compared native harnesses. The
opaque-code extreme, paired with a frontier model, is plainly capable;
for a single-principal coding sandbox that trade is plausibly right.
Max's answer is its surface: a multi-principal social deployment with
visible sends, per-principal authority, and standing prompt-injection
exposure. Prime Agent's Factorio run shows the concrete cost of ambient
RCON authority plus a prompt-only prohibition; its refinement loop then
made the discovered exploit reusable. The sandbox tool remains where Max
buys the code-mode wins at a declared coarse boundary. The rejection is
of opaque code as the *orchestration* layer, and it stands on authority
grounds, not capability grounds.

### Build a separate workflow engine beside the agent loop

Rejected because it duplicates tools, traces, cancellation, feedback, output,
and authorization while making deoptimization back to conversational reasoning
an integration problem.

### Treat horizon as a freely tunable integer

Rejected because result-dependent judgment, reflection, authority, approval,
and unknown effects impose semantic frontiers. Depth is only one budget among
several.

### Regard tool calling as intrinsically safer

Rejected. Its frequent model boundaries happen to provide recovery and approval
points, but safety comes from host authorization, validation, exact effect
state, idempotency, and bounded execution. Those checks can exist without an
LLM round and remain required at every real effect.
