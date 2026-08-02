# ADR 001: Context and Memory Foundations

- Status: Accepted
- Date: 2026-08-02
- Tracking issue: [#10](https://github.com/HCHogan/max/issues/10)

## Context

Max is moving from a bounded prompt assembled from recent rows and extracted
memories to an effectively unbounded, rebuildable conversation lifecycle. Max
serves multi-user groups and direct chats concurrently, so a coding-agent
context design cannot be copied without explicit conversation authorization,
lossless source coverage, and deterministic prompt planning.

This ADR fixes the invariants and failure boundaries before new episode,
compartment, and recall stores are introduced.

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
active model window and reserves for system instructions, tools, output,
attachments, current/replied/pinned content, memory, and later tool rounds.

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
  cutover. The only release fallback is a process-wide, token-budgeted read of
  the immutable raw ledger; it does not mutate source or projection state.
- Rebuilds and policy changes cost additional storage and background work, but
  errors remain recoverable because the raw transcript is authoritative.
