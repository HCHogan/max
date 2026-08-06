# ADR 002: Partial Plans and Adaptive Elaboration

- Status: Proposed — split scope. **The journal contract (its own section
  below) ships with v1.0** as the substrate of the durability roadmap
  (issue #14); the elaboration machine itself — validator, frontiers,
  horizon above 1 — remains post-1.0. v1.0 is a convergence release; this
  split lets it converge onto the machine's substrate without opening the
  machine's front.
- Date: 2026-08-03; journal contract and post-cutover revisions 2026-08-05;
  sandbox observability and narrator revisions 2026-08-06.

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

“Infinite horizon” is not a configuration value. It means that validation found
no earlier frontier. Different horizons may produce different model decisions
and answers; changing policy is not a semantics-preserving optimization like a
compiler optimization level.

### Validate plans before execution and authorize every effect at execution

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
honest only for ledger sends.

### The journal contract (v1.0 slice)

The execution journal is shared infrastructure, not part of the deferred
machine. It has five consumers: the horizon-1 production loop (durability
roadmap L2–L4, issue #14), crash-resume replay, the tool-trace digest,
the narrator (its own section below), and — later — this ADR's executor. **It ships with v1.0; the machine does
not.** At horizon 1 the plan is absorbed into the trace, so the loop needs
no `Plan` type to write conforming rows; it needs only this schema.

Rows are normalized execution events, never provider wire messages:

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

Alongside effect nodes the journal carries zero-authority fact rows:
`model_note` records the model's in-band tool-round narration as evidence
for the narrator and the admin timeline, never as something to execute.

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
so the v1.0 implementation keeps `turn_id` foreign-key friendly. The edge
table itself is post-1.0.

### Crash is deoptimization

Process death is a Fault like any other. Recovery re-holes the plan at the
crash point with the journal's facts in the hole's view: completed
results, committed sends, and outcome-unknown tool states — whose view
text is exactly the durability roadmap's
`[工具执行状态未知：服务重启]` injection. Guard failure, operator
feedback, and crash therefore share one deopt path, and the horizon-1 loop
exercises that path in production before the machine ever raises the
horizon.

Resume granularity is the turn, by construction: "continue exactly where
the model was" is a false concept for a nondeterministic elaborator. What
must be exact is the effect state, and that lives in the journal and the
ledger.

A generic fault must not become `reHole` and replay. Only a guard failure,
pre-effect rejection, invalid result shape, process death, or other
known-safe suspension may deopt directly. Committed and outcome-unknown
effects resume after the recorded node; compensation is explicit workflow
logic rather than an implicit retry.

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

- guard or result-schema failure;
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
abandon or reroute — the same deopt path as guard failure, crash, and
feedback. Cycle detection runs at edge creation and fails closed. Parent
`Spawn` edges and sibling depend/fork edges are two kinds in one
`turn_edges` table; the child-plan section below becomes a special case of
the turn graph.

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
reservation above.

### Child plans narrow view and authority

A future `Spawn` is primarily an elaboration-scope construct, not merely a
parallelism primitive. A child receives its own trace, context projection,
authority, effect budget, cancellation scope, and tool catalog. It returns a
typed value plus provenance to the parent; hidden child context does not become
ambient parent context.

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
- policy, validator, prompt, and model-family versions;
- effect ceiling and authority class;
- declared context dependency fingerprint.

A template is instantiated with current scoped values and revalidated on every
use. A context-bearing plan instance is never reused across conversations.
Natural-language Goal text alone is not a safe or useful cache identity.

## Max integration sequence

Step 0 ships with v1.0, independent of everything below: the journal
contract above, written by the current loop under the durability roadmap
(issue #14). Every later step consumes it unchanged. The sandbox effect
class and the narrator both attach to this step — they consume horizon-1
rows and need nothing from the machine.

1. Define a small pure `Max.Plan` IR with `Done`, typed/schema-checked `Call`,
   `Guard`, and `Hole`, plus deterministic codecs and stable node ids.
2. Add tool schema versions, result schemas, and conservative effect metadata
   without changing the model-visible current tool loop.
3. Add `Max.Plan.Validate` and pure tests for binding, schema, effect,
   authority, cardinality, and budget rejection.
4. Add a plan-tool executor seam. The real interpreter calls existing `Tools`;
   preview records calls without executing; symbolic interpretation propagates
   result shapes and stops or forks on unknown values.
5. Integrate short, read-only plan segments behind an explicit feature flag.
   `EffSend`, external writes, reflection, dynamic targets, and feedback remain
   mandatory frontiers.
6. Emit normalized plan events through the current Agent event/trace surfaces,
   and measure LLM calls, tokens, latency, deopts, duplicate effects, and answer
   quality with recorded conversation replay.
7. Expand the allowed frontier only after validator and journal evidence shows
   that the previous class fails closed and deoptimizes safely.
8. Consider approval UI, durable plans, bounded iteration, or child plans as
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
