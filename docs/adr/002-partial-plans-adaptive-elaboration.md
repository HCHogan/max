# ADR 002: Partial Plans and Adaptive Elaboration

- Status: Proposed
- Date: 2026-08-03

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
effects.

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
- an unknown result shape, stale dependency, or exhausted budget.

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

### Journal execution and deopt only from a known effect state

Each executed node receives a stable node id under a Plan hash. The execution
journal records at least:

- normalized input and tool/schema version;
- started, rejected, succeeded, failed, committed, or outcome-unknown state;
- result/provenance or bounded failure detail;
- idempotency key when the effect supports one;
- guard and validation decisions;
- elaboration/deoptimization reason.

The first implementation may keep this journal in memory because Max turns are
already ephemeral. A plan must become durably journaled before it may survive a
restart, detach into background work, or promise durable workflow completion.

A generic fault must not become `reHole` and replay. Only a guard failure,
pre-effect rejection, invalid result shape, or other known-safe suspension may
deopt directly. Committed and outcome-unknown effects resume after the recorded
node; compensation is explicit workflow logic rather than an implicit retry.

Elaboration and execution have separate fuel. Elaboration fuel prevents a
`deopt → elaborate → fail` loop; execution budgets bound nodes, loops, fan-out,
and wall time.

### Feedback, cancellation, reflection, and policy changes invalidate residual work

The executor checks the existing task inbox and cancellation state between plan
nodes, not only at LLM boundaries. New `!feedback`, an absorbed supplement, or
a poke can invalidate the planned continuation and force a hole whose view
includes the new note. `!kill` remains asynchronous and must cross both the
elaborator and executor without being converted into an ordinary tool failure.

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
- Tool metadata, a validator, a journal, and new replay evaluation add
  substantial complexity before large horizons are safe.
- Static effect inference is deliberately conservative. Opaque sandbox code and
  dynamic targets reduce optimization opportunities instead of weakening the
  authority boundary.

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
