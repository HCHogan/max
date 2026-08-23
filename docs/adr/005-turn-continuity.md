# ADR 005: Turn Continuity — Journal Projections and Verbatim Replay

- Status: Implemented through slice 4: durable turns/journal archives, `t#`
  expansion, reply-linked digest continuation, bounded provider-wire replay,
  ledger deduplication, drift checks and crash recovery are production paths.
  Slice 5's small-model 「思路」/`turn_digests` cache and narrator renderer
  unification remain deferred polish; the deterministic digest is the floor.
- Date: 2026-08-06; persisted turn-ordinal handle contract 2026-08-09.

## Context

A dispatch's working state dies with the dispatch. The agent loop
returns its full trace — wire-verbatim assistant messages including
provider reasoning, tool calls, and results — and the handler epilogue
logs its length and drops it. What survives today: visible replies in
the canonical ledger, episode summaries of the *conversation* (ADR 001),
and — once the v1.0 journal contract lands — normalized effect rows
(ADR 002).

Continuations arrive as ordinary dispatches, minutes or days later:
「把刚才的图改成对数坐标」. The new turn sees the visible conversation
but none of the invisible work: which tools ran with what results, what
failed and was retried, what the sandbox now contains, and why the model
chose the approach it chose.

Two provider facts shape the mechanism:

- Reasoning is increasingly opaque — encrypted reasoning items, signed
  thinking blocks. Opaque reasoning cannot be read, summarized, or
  paraphrased. It can only be replayed verbatim, to the same model
  family.
- Replaying prior reasoning measurably improves agentic performance
  (OpenAI's reasoning-item reuse guidance). Continuity of reasoning
  therefore requires the wire bytes; no projection can carry it.

ADR 002 fixes the ground rules this ADR composes: "continue exactly
where the model was" is a false concept — resume granularity is the
turn, and exact effect state lives in the journal; journal rows are
normalized events, never provider wire messages; the turn graph reserves
`fork-from` edges. ADR 004 gives every referent a canonical handle.

## Decision

### Continuation is a new turn with the old turn projected into view

A continued task never resumes the old dispatch. It opens a new turn and
places the old turn's record in that turn's view — the same move as
ADR 002's crash deoptimization, at a longer distance. One projection
machine, three windows:

| Consumer | Window | When |
|---|---|---|
| narrator (ADR 002) | journal delta of a running turn | mid-turn, edge-triggered |
| crash-resume hole view | complete journal, unknowns marked | after restart, same turn |
| continuation view (this ADR) | complete journal of a finished turn | any later turn |

Injecting turn T's view into new turn U writes one
`turn_edges (U, T, fork-from, created_by)` row — the first tenant of
ADR 002's reserved edge table, in the degenerate sequential case. The
turn graph carries real data before any concurrency lands on it.

### The write path: turns, fact rows, segment archives

**`agent_turns`** is the durable turn identity (also the L2 checkpoint
substrate of issue #14): turn id, group, persisted group-scoped
`turn_ordinal`, trigger canonical message id, status (running / succeeded /
silence / aborted / crashed), profile, started/finished timestamps, token
usage. `UNIQUE (conversation_id, turn_ordinal)` backs the model-visible
`t#<n>` handle; the ordinal is allocated at turn creation, never while
rendering. It joins `#<nnnn>` and `s<n>` in the amended ADR 004 handle
grammar.

**Journal rows** follow the ADR 002 contract unchanged — effect rows
plus zero-authority fact rows (`model_note`). Nothing here relaxes the
red line: rows are normalized events, never wire messages.

**The trace archive** is the new artifact: per turn, one blob holding
provider, model, and the wire items *this turn appended* — its own
trigger, reasoning blobs, tool calls, results, and final message, but
not any replayed prefix it inherited (see chains below). The archive is
a cache, not truth: it hangs off a blob reference on the turn, is
disposable, and nothing that must be trusted is ever read from it.
Capture is nearly free — the loop already carries the provider message
verbatim for in-dispatch round-tripping, and the epilogue currently
drops it; archiving writes down what is already in hand.

Retention: archives get a TTL (default 14 days) and a per-group LRU cap
(default 50 turns); expiry silently drops a turn to the digest tier,
which is the common path anyway. Journal rows and digests are permanent
and compact. Chat-only turns (no tool calls) journal almost nothing and
render no continuity surface.

### The read path: three disclosure levels

**Level 0 — standing lines.** The prompt gains a `[recent turns]` block
beside the compartment summaries: one line per recent worked turn,
token-planned, chat-only turns omitted.

    [recent turns — 工作记录，细节用 t# 句柄调 context_expand]
    t#42 14:32 ✓「画了销量周环比图」· 5 tools · sandbox s1 ↦ #1234
    t#41 13:07 ✗ aborted「重构 nix module」· 12 tools

Defaults: last 24 h, at most 5 worked turns, cut by the planner.

**Level 1 — automatic injection.** The precise trigger is the reply: a
trigger message replying to a bot message resolves through the L3 send
linkage (`node_id → canonical_message_id`) to the turn that produced it.
An in-flight target is a steer (ADR 002's routing lattice); a finished
target is a continuation. Injection has two tiers — verbatim replay when
the validity predicate below holds, digest otherwise. No task-boundary
classifier exists: a vague 「继续搞刚才那个」 with no reply lands on
Level 0 lines and the model pulls.

**Level 2 — model-pulled.** `context_expand` grows a `t#` namespace
beside `episode#`: the full normalized trace view — tool sequence with
key arguments and result summaries, failures and retries, the sandbox
observed manifest, the `model_note` line. Opaque reasoning is never
rendered here (it cannot be read); plain-text reasoning, where a
provider exposes it, is quoted only on explicit request and attributed
as 「你当时的思考（原文，仅供参考）」.

### Replay is a cache with a validity predicate

The verbatim tier rebuilds the continuation request as:

    [system prompt — current S2, never the archived S1]
    [verbatim segments — the fork-from chain's wire items, oldest first]
    [ambient delta note — host-composed, see below]
    [current message — the trigger, ordinary grammar]

The enabling observation: in ordinary agentic use, reasoning items are
*always* replayed into a grown context — every round adds tool results
and messages after the blob was produced. Encrypted and signed reasoning
verify item integrity, not surroundings. Cross-dispatch replay is the
same operation at a longer distance, so the question is never "may the
ambient change" — it is "how does the model learn what changed."

The system prompt is always current: policy, roles, and capability text
must not be resurrected. This usually costs nothing — the clock already
lives outside the system prompt, so the current prompt is frequently
byte-identical to the archived one and provider prefix caching still
hits up to the divergence point.

Per-provider replay filtering (what DeepSeek strips, what Anthropic
ignores in non-final assistant turns, what OpenAI round-trips) is the
same code path the loop already uses within a dispatch — no second rule
set.

Ledger dedup: messages covered by a replayed segment (the old trigger
and the old replies) are stubbed out of the conversation window, so the
model never sees them twice.

### The ambient delta note

Deterministic, host-composed from the journal and the ledger — the
crash-resume epistemology at continuation distance: drift is never
hidden, it is an attributed fact.

    以上是你之前完成 t#42 的完整工作过程（原样保留，含你当时的思考）。
    距它结束已过 2h13m。期间：
    · 群里新增 47 条消息，其中 #1258 hank「数据我更新了一版」
    · 沙盒 s1 仍在；/work: sales.csv 被 t#43 覆写（14:55），analysis.py、out.png 未动
    · 工具目录、技能无变化

Three drift classes, three sources. Elapsed time and intervening
conversation come from the ledger, bounded by the planner — no relevance
classifier in v1. World-state drift comes from diffing the sandbox
observed manifests of intervening turns in pure code — ADR 002's
observation layer paying out a second time. Catalog and prompt version
changes come from the journal's own version columns. References inside
old reasoning stay resolvable because they are canonical handles — an
unplanned payoff of ADR 004: handles make archived traces
drift-resistant.

### Validity predicate and model stickiness

Replay degrades to digest — the always-available floor — when any of:

- **model family changed** — opaque blobs are foreign bytes to another
  model. Degraded replay may keep the plain-text tool trace and strip
  reasoning items; full digest is always correct.
- **archive expired or evicted** — TTL/LRU above, plus any
  provider-side validity window on encrypted content.
- **tool catalog or prompt major version changed** — archived calls no
  longer match live schemas; the delta note says so (the same trigger
  ADR 002 lists for deoptimization).
- **chain budget exhausted** — only older segments fall (below).

Continuation prefers the forked turn's profile — soft stickiness: the
router may still override, at the price of the digest tier. A task chain
is not a hard model lease.

### Chains: segment archives with a compression frontier

t#44 forks t#43 forks t#42. Archives store segments, so the replay
builder walks the fork-from chain newest-first, admitting verbatim
segments until the chain token budget is spent; everything older renders
as digest. v1 keeps the simple shape — a contiguous verbatim suffix over
a digest prefix, no interleaving. This is the compartment idea applied
to task chains: recent work at full fidelity, older work compressed, the
planner owning the boundary.

### Digest production

Two layers, both cheap. The deterministic skeleton — tool sequence, file
manifest, failures, sandbox liveness — folds out of the journal in pure
code; Level 0 lines use only this plus the final reply's first line. The
「思路」 paragraph — a few sentences of approach and key decisions —
renders lazily from the turn's readable self-narration (`model_note`
rows, plain-text reasoning where the provider exposes it, the final
answer) on first use, by a small model, and caches forever in
`turn_digests`: a finished turn's journal is immutable, so the
projection never invalidates — the standard rebuildable-projection
shape. The renderer is shared with the narrator — one projection, an
incremental window and a complete one — and the crash hole view is its
complete-with-unknowns variant.

### !clear and visibility

`!clear` hides — Level 0 stops rendering cleared turns and reply
resolution stops crossing the clear point — but journal rows remain:
they are audit, not conversation. `!clear --all` keeps its existing
sandbox destruction; archives die by TTL rather than by command.

## Max integration sequence

1. `agent_turns` + journal writing + archive capture in the dispatch
   epilogue — turn the drop into a write. Shares its substrate with
   issue #14's L2; needs nothing from the machine.
2. Level 0 lines and the `context_expand` `t#` namespace, deterministic
   skeleton only.
3. Reply-targeted Level 1 injection at the digest tier, writing
   `turn_edges` rows. Requires L3 linkage.
4. The replay tier: segment builder, validity predicate, delta note
   renderer, ledger dedup.
5. Small-model 「思路」 rendering with the `turn_digests` cache; merge
   renderers when the narrator lands.

Steps 1–3 deliver durable work records and automatic continuation;
step 4 delivers reasoning continuity; step 5 is polish. The replay
tier's acceptance bar mirrors ADR 002's: on a replayed continuation set
it must produce no more duplicate or outcome-unknown effects than the
digest tier, and no worse answers.

## Consequences

- The invisible half of a dispatch becomes durable, addressable (`t#`),
  and projectable; continuation stops re-deriving work and re-asking
  questions the journal can answer.
- Reasoning continuity survives encryption: the archive carries blobs
  the journal is forbidden to hold, without weakening the journal's red
  line — the archive is disposable cache, rows remain the only trusted
  record.
- One projection machine serves the narrator, crash resume, and
  continuation; `fork-from` edges carry real data before
  multi-principal concurrency arrives.
- Costs: blob storage (bounded by TTL and LRU), ledger-window dedup,
  per-provider replay filters kept honest, and soft model stickiness
  coupling routing to continuity quality.

## Rejected alternatives

### Verbatim replay as the only mechanism

Rejected: blobs are model-family-bound and expiring, chains grow without
bound, and a predicate failure would then have no floor. The digest tier
is the deoptimization target replay requires.

### Digest as the only mechanism

Rejected — it was this ADR's first draft. Opaque reasoning cannot be
paraphrased, and replayed reasoning measurably improves capability; a
projection cannot carry either.

### Replaying the archived system prompt for cache hits

Rejected: policy, roles, and capability text must be current, and the
current prompt is usually byte-identical anyway. Correctness over cache.

### A task-boundary classifier

Rejected: reply targeting is precise, handles are the zero-ceremony
fallback, and observe remains the overwhelming default. No new
classifier.

### Reconstructing ambient identity

Rejected as incoherent: the world moved. Drift is surfaced as an
attributed fact — the delta note — never hidden.
