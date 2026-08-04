# ADR 001: Context and Memory Foundations

- Status: Accepted / Implemented
- Date: 2026-08-02
- Tracking issue: [#10](https://github.com/HCHogan/max/issues/10)

## Context

Max replaced its bounded prompt assembled from recent rows and extracted
memories with an effectively unbounded, rebuildable conversation lifecycle. Max
serves multi-user groups and direct chats concurrently, so a coding-agent
context design cannot be copied without explicit conversation authorization,
lossless source coverage, and deterministic prompt planning.

This ADR records the invariants and failure boundaries implemented by the
episode, compartment, memory, materialization, and recall stores.

## Decision

### Raw messages are the immutable fact source

Automatic context or memory maintenance never deletes, rewrites, or moves a
source message. Compartments and memories are projections with provenance. A
projection may be archived or superseded without changing the raw transcript.

Every derived record retains the source conversation, source speakers, and an
exact message/ingest range. A summary can be expanded to raw source text and
rebuilt with a newer prompt or model.

### Settled history has exact coverage

For every conversation enrolled in the new lifecycle, each settled source
message is owned by exactly one of:

1. the token-budgeted protected live tail; or
2. one active chronological compartment.

Active compartment ranges have no gap and no overlap. Publication is
idempotent and validates a strict source range plus source hash. The history
cursor advances only through the last range successfully published. Backlog
processing pages oldest-first from the cursor and cannot skip messages because
of a row limit, restart, timestamp tie, or failed historian call.

### Context and semantic memory share capture, not storage

One settled-episode capture may propose both:

- P1/P2/P3 chronological context summaries; and
- semantic memory mutations.

They retain shared evidence but have independent storage, lifecycle,
authorization, rebuild, and recall behavior. Semantic memories cannot satisfy
chronological coverage and cannot replace a missing compartment.

### Conversation authorization is host-owned

All model-facing message, media, file, pin, forward, and memory operations take
the current `ConversationScope`. A model-provided message/resource id is a
locator, never a capability. A model-provided group id cannot construct or
widen a scope. Privileged unscoped operations are named as admin/diagnostic
operations and are not reachable from agent tools.

Default read matrix:

| Current conversation | Source conversation | Decision |
|---|---|---|
| Group G | Group G | Allow |
| Group G | another group | Deny |
| Group G | any direct chat | Deny |
| Direct chat U | that direct chat | Allow |
| Direct chat U | any group | Deny by default; future explicit one-way policy |
| Direct chat U | another direct chat | Deny |

A future group-to-member-DM projection must verify membership and policy in one
central read boundary. Direct-chat data never flows into a group, and one group
never flows into another. LLM-produced importance, category, or shareability
can affect ranking only; it cannot grant visibility.

### Prompt retention is token-budgeted

The final context is one chronological stream: decayed compartments followed
by a protected raw tail. The live tail has no fixed message-count boundary.
High and low materialization thresholds are token watermarks derived from the
active model input window and attachment/tool-round reserves, with roomy
16,384/32,768 ceilings for noisy verbatim group history. The completion limit
is tracked separately. Current/replied/pinned content and final prompt pressure
remain protected or governed by the pure planner rather than a message count.

Mention, reply, pin, in-flight, and Max-participation information can influence
protection, episode boundaries, summary emphasis, and recall ranking. It does
not create a second independently queried history lane once compartment
rendering replaces the bounded system.

### Failure boundaries are explicit

Fail closed:

- conversation/resource authorization;
- evidence range validation;
- namespace and mutation target validation;
- incompatible or stale embedding use;
- compartment gap/overlap/source-hash validation.

Fail soft:

- historian, embedding, and recall service failure;
- unavailable media or captions;
- a rebuild that has not completely validated and published.

On a fail-soft path Max may answer from the current message, a bounded raw tail,
and last-known-good compartments. It records an observable retry/attention
state, does not advance coverage, and does not replace the last-known-good
projection.

## Consequences

- Store APIs become more explicit: callers carry a conversation scope and
  cannot perform a convenient global lookup from an agent turn.
- Existing globally addressable IDs remain valid storage identifiers, but are
  always combined with scope predicates before model-visible reads or writes.
- PostgreSQL integration tests are required in CI because the security and
  coverage invariants are primarily SQL and transaction behavior.
- The former two-source history query is removed at the all-conversation
  cutover. The release fallback is a process-wide, token-budgeted read of
  the immutable raw ledger; it does not mutate source or projection state.
- Rebuilds and policy changes cost additional storage and background work, but
  errors remain recoverable because the raw transcript is authoritative.

## Prior art: comparative survey (2026-08)

Surveyed against source after ADR 003 shipped: AstrBot (master, 2026-08)
and NekroAgent (d7470d5, 2026-08). Full analysis lives in the 2026-08-05
session; this records the durable conclusions.

Three ontologies of "context". AstrBot: context is a per-conversation
OpenAI message array — multi-conversation switching, LLM compression
written back destructively, long-term memory delegated entirely to a
plugin market with no core memory API. NekroAgent: context is an
ephemeral per-run projection rebuilt from its message ledger — no
assistant turns are retained (history replays as flat text), the window
is tiny (32 messages / 5120 chars, character-counted), and long-term
weight is carried by an opt-in memory subsystem instead of the window.
max: context is a versioned projection over an immutable ledger with
integrity constraints — the design this ADR records.

- **Flat transcripts are convergent.** NekroAgent independently abandoned
  user/assistant turns for group history, for the same reason
  `Max.Context.Types` documents: N speakers break role semantics.
  AstrBot keeps OpenAI turns and its group support (an in-memory deque,
  lost on restart) is visibly a patch on a 1:1 chat shape.
- **Compression philosophies.** AstrBot compresses destructively (the
  summary replaces stored history; a bad summary is forever). NekroAgent
  does not compress at all — the window slides and memory consolidation
  is the answer. max's tiered episodes (P1/P2/P3 coexisting, evidence
  ranges, rebuildable, expandable) is the only auditable-and-reversible
  scheme of the three, and costs roughly the other two systems' combined
  context code to get.
- **Memory: biological versus accounting models.** NekroAgent's memory is
  the most sophisticated competitor: dual episodic/semantic state,
  exponential decay with retrieval reinforcement, an entity/relation
  graph, narrative episode aggregation — but decay mutates weights
  autonomously with no audit trail, it is workspace-scoped (no per-user
  memory), off by default, and the LLM cannot write to it. max's
  version+evidence+mutation ledgers with CAS and actor permissions are
  the opposite bet: even forgetting leaves a reasoned trace (the dream
  worker must justify every shrink). Mirror-image blind spots: their
  cross-platform identity field on entities is an unwired stub; our
  `relationship_context` auto-capture ban is a deliberate ADR decision.
- **Injection versus tools.** AstrBot auto-injects KB top-5 per request
  (with an agentic-mode opt-out); NekroAgent passively injects a memory
  block every run. max is the lone holdout: only the 12-memory block is
  passive, all other recall is the model calling `context_search`. The
  hidden cost is dependence on the model's tool discipline; the payoff is
  an unpolluted prompt.
- **Token accounting.** None of the three counts exactly. AstrBot
  estimates by character coefficients but calibrates with
  provider-reported usage when available; NekroAgent counts characters
  only; max uses its conservative provider-neutral bound.
- **Nobody survives a mid-turn crash.** All three lose in-flight LLM
  turns; max's checkpoint-resume roadmap item remains the only concrete
  plan among them. NekroAgent's durable consolidation cursor and
  checkpointed memory-rebuild tasks are its strongest durability work.
- **Evaluation.** max's offline release gates (Historian fixtures through
  the production prompt, recall fixtures, generated prompt-flow doc under
  CI drift check) have no counterpart in either system.

Worth borrowing: AstrBot's trusted-usage calibration for the token
estimator (our `llm_usage` ledger already holds the data); NekroAgent's
memory admin UI as a form reference for the undecided admin frontend
(graph view, paragraph-to-anchor tracing, freeze/protect operations — our
ContextAdmin already serves the equivalent data); staleness/hit-rate as a
*priority signal* for the dream worker without adopting formula decay;
AstrBot's rerank-provider abstraction if recall precision ever needs it.

Honest costs on our side: no knowledge base or document ingestion (a real
gap — "discuss this PDF" currently has no path outside the sandbox); no
conversation branching; exact-scan recall with no ANN index (fine at
current volume, revisit at 10x); and a complexity budget justified only
because there is exactly one deployment to serve.
