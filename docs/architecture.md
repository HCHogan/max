# Architecture

Cross-cutting decisions are recorded in:

- [`ADR 001: Context and Memory Foundations`](adr/001-context-memory-foundations.md)
- [`ADR 002: Partial Plans and Adaptive Elaboration`](adr/002-partial-plans-adaptive-elaboration.md)

Layout, runtime data flow, effect stack, and phase status. For behaviour see
[features.md](features.md); for tests and debugging see
[development.md](development.md), and for transport cutover/repair see
[platforms.md](platforms.md).

## Layout

```
flake.nix          devenv shell as a flake module (GHC 9.10, Postgres 17 + pgvector)
devenv.nix         service definitions + .env sourcing on shell entry
docker-compose.yml NapCat container; shared ./var/outbox volume
sandbox-image/     nix-enabled sandbox base image  → max-sandbox:latest
browser-image/     camoufox-mcp + supergateway + camoufox → max-browser:latest
nix/module.nix     NixOS module for production deployment
.github/workflows/ CI: build + pure and PostgreSQL/pgvector tests through the
                   flake dev shell, plus a pure `nix build .#max` so the
                   packaged build can't rot
max.cabal          library + max executable
migrations/*.sql   schema migrations, applied on boot
skills/*.md        builtin skill manuals, baked into the binary (file-embed);
                   self-knowledge also splices docs/features.md + live !help

src/OneBot/        OneBot 11 wire protocol: types (incl. private-chat pseudo-groups),
                   segments, events, actions, server
src/Max/Effects/   effectful 2.5 effects: Http, Blob, Embedding (injectable validated
                   vectors), PlatformApi, Outbound (visible send
                   + persistence), LLM (OpenAI + Anthropic, buffered or streamed),
                   validated Tools catalog, ToolOutput (turn-scoped tool media), Agent
                   (DB effect from upstream effectful-postgresql)
src/Max/LLM/       Stream: SSE framing + the two protocols' delta reducers, pure
src/Max/Http/      Json: bounded buffered POST + domain retries; Stream: SSE folding;
                   both execute through the process-wide HttpRuntime pools
src/Max/HttpRuntime process-wide http-client managers, bounded response scopes,
                    and typed transport failures
src/Max/DB/        postgresql-simple queries: Connection, pinned Transaction,
                   Migrations, Message, Forward,
                   History, ConversationCursor, Session, Files, Memory, Permissions,
                   PlatformIds, Reminder, Stickers, FetchQueue (media work list),
                   Calls, Usage
src/Max/Command/   !cmd DSL: Types, Parser (megaparsec), Dispatcher, Help (the
                   !help text — a leaf module so the self-knowledge skill can
                   splice it at registry init)
src/Max/Session/   Per-conversation session: versioned TVar handle + serialized CAS persistence
src/Max/Sandbox/   Per-group Docker workspace lifecycle + registry
src/Max/Browser/   Per-group camoufox-MCP container lifecycle + registry
src/Max/MCP/       Minimal MCP client (Streamable HTTP)
src/Max/Tools/     Tool implementations (Files, Sandbox, Search, Browser, Memory,
                   Images, Video, Bilibili, Stickers, Pins, Group, Reminder,
                   Skills — progressive disclosure, SelfSource — bounded reads
                   of the allowlisted compile-time source snapshot)
src/Max/           Config (opt-env-conf), Env (BotEnv Reader), Prompt, Handler,
                   Platform.Types/Store/Delivery (canonical conversations,
                   identities, native provenance, cursor/dispatch/delivery
                   leases), QQ normalization, Matrix and iMessage adapters,
                   AgentEvent (typed progress/debug/final-stream port and its
                   ReplySend/Outbound interpreter),
                   ToolContext (neutral per-turn identity/capabilities),
                   Toolset (the full tool list, assembled from BotEnv), Intent
                   (proactive classifier), Skills (write-through registry:
                   builtins baked from skills/ + docs/, DB rows shadowing them),
                   SelfSource (public text snapshot + deterministic bundle hash),
                   EpisodeScheduler (protected quiet-tail timing), Historian +
                   EpisodeStore (durable exact-range P1/P2/P3 capture and scoped
                   memory proposals), Prompt context pipeline (materialized
                   compartment generations + token-sized protected raw tail),
                   MemoryExtract (nightly memory maintenance),
                   Embedding + Embedder
                   (vector worker), Forward/Image/File workers, FetchQueue (their
                   shared claim loop), MediaCaption + Stickers (caption workers),
                   Reminder, Reply (planning), ReplySend (planning made real:
                   placeholders, sending, persistence — shared by final,
                   streamed, and progress text), Render, Roster, Shutdown (graceful
                   drain), Tasks, Tools, BuildInfo (compile-time git rev), Admin
                   (JSON API + panel), Util
app/Main.hs        wires effects + workers + server
```

## Data flow

```
 QQ/NapCat ─┐
 Matrix ────┼─ normalize ─▶ canonical event/message transaction
 iMessage ──┘                 ├─ source provenance + source delivery
                              ├─ mirror endpoint delivery jobs
                              └─ durable dispatch eligibility
                                           │
       ┌──────────────────────── handleEvents ───────────────────────────┐
       │ claim one canonical dispatch after durable ingest              │
       │   1. enqueueImages / enqueueForwards / enqueueFiles → fetch_jobs│
       │   2. classify (@bot / reply-to-bot / private / !cmd) →          │
       │        none / ping / !cmd / agent-turn                          │
       └──────┬──────────┬──────────┬──────────────┬─────────────────────┘
              │          │          │              │
        ┌─────▼────┐ ┌───▼────┐ ┌───▼─────┐ ┌──────▼──────────────────┐
        │img/fwd/  │ │embedWkr│ │!cmd     │ │ agentTurn (async task)  │
        │file wkrs │ │pgvector│ │dispatch │ │  buildContext (+memory) │
        │(claim    │ │backfill│ │(session,│ │  → LLM (tools)          │
        │ fetch_   │ │+ tail  │ │ memory, │ │    └─ tool loop ◀──┐    │
        │ jobs)    │ └────────┘ │ tasks)  │ │  (sandbox/browser/ │    │
        └──────────┘            └─────────┘ │   search/files/mem)┘    │
                                            │  → AgentEvent           │
                                            │      → ReplySend        │
                                            │          → Outbound     │
                                            │             canonical 1×│
                                            │             deliveries N×│
                                            │  → arm episode idle timer│
                                            └─────────────────────────┘
```

QQ and Matrix may be endpoints of the same canonical conversation; iMessage is
standalone. Required dispatch and delivery workers close both post-commit crash
windows. Matrix retries reuse deterministic transaction IDs. Non-idempotent
QQ/iMessage ambiguity is parked until echo/status reconciliation, never placed
back on the retry queue by a timeout. Context, Historian, and memory therefore
see one semantic row regardless of how many transport copies exist.

Historian v2 is episode-scoped rather than per-dispatch. After ten quiet
minutes it selects an oldest-first raw-ledger prefix by the configured model's
token budget (SQL pages are only an implementation detail), then persists an
exact source range/hash as a leased capture job. One structured LLM call emits
P1/P2/P3 chronological summaries plus scoped memory proposals. Publication
atomically validates citations and scope, writes the compartment and proposal
outcomes, applies accepted MemoryStore mutations, and CAS-advances the
historian cursor. A failure advances nothing; restart reclaims the durable job.
Historian completions use the independent `memory.timeout_seconds` (600 seconds
by default) and make one transport attempt per generation/repair call; the
durable queue retries after 1m/5m/15m/1h/6h. New pending ranges
are claimed before overdue retries, so one poison range cannot starve first
attempts while its immutable source remains available for later retry.
Commands/synthetic/forward rows remain in range coverage before transcript
filtering, and active ranges have a database non-overlap constraint. The
pre-cutover deployment boundary is backfilled automatically, oldest gap first
and without rewinding the live cursor. A nightly dream pass (4am local) remains
a separate semantic-memory maintenance lifecycle. It reads the current version
together with its source evidence, requires a concrete evidence/date reason for
every change, updates a chosen keeper before superseding duplicates, and
archives only clearly expired
facts without a replacement. Every operation is a scoped MemoryStore CAS that
appends a version, maintenance evidence, and audit record; automatic actors
cannot mutate permanent memory.

A model response that cannot satisfy the strict `EpisodeCapture` JSON schema
receives one bounded repair turn with explicit field and numeric-id rules. The
repair uses the same capture lease and its extra token/latency cost remains
visible; provider failures and semantic omissions still fall through to the
durable run retry instead of being resampled until they look acceptable.
`max-context-eval` replays hand-labelled, synthetic multi-speaker fixtures
through this exact production request path, requires valid provenance and
memory precision, and reports calls, repairs, provider tokens, cache hits, and
latency. Its separate direct-turn auto-hint fixture exercises a candidate
strong-signal policy which intentionally has no production prompt caller.

The authenticated admin context console is the operational boundary for this
projection lifecycle. It reports exact cursor/coverage lag, range gaps and
overlaps, capture leases/retries/validation, materialization revisions,
body-free prompt budget/tier decisions, memory versions/evidence/audit,
embedding spaces and backlog, and a policy-scoped retrieval trace. Full or
single-compartment rebuilds enqueue ordinary durable Historian runs: the old
active compartment remains live until replacement publication succeeds.
Reindex clears only selected derived vectors while holding the embedding
maintenance lease, then the normal worker backfills them. Integrity checks are
read-only and recompute source hashes, ownership, materialization references,
cursor bounds, and the memory current/version projection.

Every conversation takes the newest active compartment suffix that has no
uncovered raw rows, then pages backward over prompt-eligible messages after the
suffix's exact end cursor until the model-derived token target is covered.
Partial older
backfills stay out of the stable prefix when a raw gap separates them. The pure
`Max.Context.Policy` assigns P1/P2/P3/P4 using coarse age, episode distance,
importance, confidence, and token pressure; P4 remains stored but is omitted
from the default prompt. The selected tiers, source compartment ids/projection
versions, policy version, and exact raw-tail cursor live in a CAS-versioned
`context_materializations` row plus an append-only revision ledger. Normal
turns reuse that revision. Initial enrollment, an active projection
replacement, or raw history crossing the model-derived high-token watermark
publishes one new revision; it folds only enough prepared compartments to aim
the tail back below the low-token watermark. Smaller profiles derive these at
20%/40% of their available prompt window, while 16,384/32,768 token ceilings
keep larger future windows from turning group noise into an oversized verbatim
tail. Store publication locks and
rechecks active source versions, rejects gaps or backward cursor movement, and
records the cache-bust reason. Under exceptional per-turn pressure active
memory is removed first, compartments can degrade one tier at a time, and only
then is the oldest raw tail trimmed. A conversation with no active compartment
automatically pages over the immutable raw ledger and retains the newest rows
up to the same raw-tail token target. A corrupt/stale
materialization instead renders the newest gap-free active compartments at
deterministic base tiers plus their exact raw tail for that turn, without
restoring the retired mention lane or changing source/projection data.
The global `context.force_raw_fallback` release switch bypasses projection reads
for every conversation and uses the same token-budgeted raw ledger; it neither
deletes projections nor stops Historian, so disabling it restores tiered reads.
Planning measures the complete candidate prompt once, then applies
deterministic block-local cost deltas while degrading it; the selection loop no
longer invokes the full renderer for every discarded item. The selected result
is rendered once for the final exact budget and trace observation.
`Max.Context.Types` makes unselected `ContextCandidates` and selected
`SelectedContext` different pipeline values, while `Max.Prompt.System` owns the
stable system prefix. `collectContextPreview` is the read-only collection path
for admin/evaluation: it can be planned and rendered without publishing a
materialization revision or context-plan trace.
At Historian startup, exact oldest-first backfill jobs fill any raw gaps at or
before migration 041's deployment baseline. Each token-sized range stops before
the next active owner, publishes under the ordinary source-hash/exclusion
fences, and leaves the live Historian cursor unchanged.

Rendered summaries carry a random, stable `[episode#<uuid>]` handle rather
than the internal compartment sequence. `context_expand` treats that handle
only as a locator: every page re-applies the current conversation's
`RecallPolicy` in SQL before reading the exact ingest range. Expansion returns
raw ledger rows in ingest order, reports whether the current source hash still
matches the captured hash, paginates without leaving the range, and keeps old
handles expandable after a rebuild supersedes their projection. A handle from
another group or direct chat is indistinguishable from a nonexistent handle.

`context_search` is the volatile unified-recall surface. It searches visible
active/permanent memories, active episode summaries, raw messages, current
session pins, and image/video captions. Lexical candidates use exact substring
or trigram similarity; compatible message, memory, and episode embeddings add
semantic candidates. Conversation policy predicates and embedding
model/dimension checks run in SQL before scoring. The pure selector merges
lexical and semantic forms, collapses raw/pin/caption identities and
provenance-linked memory/episode identities, then applies per-source quotas
before using spare capacity. Recency, episode importance, pins, and permanent
memory are bounded weak boosts rather than authorization inputs. If query
embedding fails, the tool logs attention and returns lexical results instead
of failing the turn. No recall result is injected automatically; the agent
calls this tool only when the conversation needs older detail.

`context_search` is the only model-visible recall surface. The retired
`search_messages` and `memory_search` compatibility tools are not registered:
one policy now owns corpus selection, visibility, ranking, deduplication, and
fallback behavior, and model-generated placeholder filters cannot silently
route a semantic request around it.

## Self-knowledge and source inspection

Self-knowledge uses progressive disclosure rather than keeping implementation
documentation in every prompt. `self-knowledge` merges its short routing and
deployment guide with the exact embedded `docs/features.md` bytes and live
`!help`; `self-architecture` is the embedded `docs/architecture.md`. A DB skill
can shadow either built-in under the ordinary group > DB-global > builtin rule.

Exact implementation questions bypass prose summaries. The globally visible
`inspect_source` tool can list, case-insensitively search, and read numbered
lines from an allowlisted public text bundle embedded by `Max.SelfSource` at
compile time. It covers implementation, tests, migrations, ADRs, docs, skills,
evaluation fixtures, build files, and public config examples. Responses carry
both the compile-time git revision and a SHA-256 over sorted path/content pairs.
The tool has no filesystem capability at runtime: local `max.yaml`, `.env`,
`AGENTS.md`, VCS/build state, secrets, and paths outside its fixed source
allowlist are outside the bundle. Consequently source defaults are evidence
about the shipped binary, not the deployment's effective configuration or
database state.

Unless a profile sets `stream: false` the LLM box reads the completion over SSE
instead of waiting for a whole body. Paragraphs the model has finished with go
out mid-generation as typed `AgentFinalStreamText` events; tool narration and
debug facts use distinct event constructors. `Max.AgentEvent` interprets all
model-authored text through `ReplySend`, while the loop only reports how much
was accepted as `AgentResult.sentPrefix` and the handler sends the rest.
`readyPrefix` will not release a trailing paragraph — it may still grow — so a
one-paragraph reply, which is most of them, still arrives all at once.

## Durability

What a restart keeps and what it drops. Postgres is authoritative throughout;
the in-memory handles are read caches and wakeup bells, never the record.

| Survives a restart | How |
|---|---|
| Messages, sessions, memories, stickers, permissions, skills | written through on every mutation; Session persists revision CAS before publishing its TVar (builtin skills re-seed from the binary) |
| Pending image / video / forward / file fetches | `fetch_jobs` rows claimed under a lease — a dead process's lease expires and the next claim picks the job back up |
| Pending historian capture | leased `episode_capture_runs` rows plus the conversation-scoped historian cursor; boot drains jobs, then re-arms any conversation with newer raw rows |
| Tiered prompt prefix | current `context_materializations` revision plus append-only versions; active compartment ids/versions, tiers, end cursor, policy, fingerprint, and cache-bust reason are durable |
| Episode expansion handles | random UUID on the immutable compartment; scoped lookup recovers the exact raw ingest range, including after supersession |
| Reminders | `reminders` table; the scheduler handle is only a wakeup bell |
| Embeddings, captions | workers poll messages, memories, active episode summaries, stickers, and media for missing/incompatible derived data, so any gap or model change backfills itself |
| Maintenance ownership | independently fenced PostgreSQL leases serialize embedding, memory-dream, and context-rebuild domains without making unrelated maintenance jobs block one another |

| Lost on restart | Why |
|---|---|
| In-flight agent turns | ephemeral by design (`Max.Tasks`). SIGTERM drains them first — `shutdown_drain_seconds`, default 120 — but a crash, or a drain that times out, abandons them |
| Triggers arriving mid-drain | persisted to `messages` and logged, but not dispatched |
| Anything NapCat sends while we're down | it dials in over reverse-WS and doesn't buffer; closing this needs history backfill on reconnect |
| `!use` admin targets | deliberate — just `!use` again |
| Sandbox / browser containers | destroyed on exit, reaped on boot |

Effect stack at the top of `runApp`:
`IOE → Concurrent → Log → Http → Embedding → Blob → WithConnection → PlatformApi → Outbound → LLM → Reader ModelCatalog → Reader BotEnv → Agent`.

### PostgreSQL transaction ownership

Every multi-statement publication uses `Max.DB.Transaction.withTransaction`.
This wrapper acquires one physical pooled connection and interposes the
`WithConnection` effect for the whole body, so every nested `query`/`execute`
uses that same connection. This is required because effectful-postgresql
0.1.0.1's pooled transaction wrapper starts `BEGIN` on one connection while
body operations may otherwise reacquire another. The local wrapper makes
rollback, row locks, advisory transaction locks, and commit visibility real;
the DB suite deliberately throws after an insert and proves no row survives.

### Outbound HTTP ownership

`HttpRuntime` is a process resource created once in `Main`, not another domain
effect. It owns the only production `http-client` managers and is injected into
the interpreters and plain-IO clients that need it:

```
app/Main
  └─ newHttpRuntime
       ├─ StandardPool
       │    strict TLS validation; http-client implicit retry disabled
       └─ LegacyEmsPool
            same validation + explicit AllowEMS for known legacy CDNs
              │
              ├─ Http effect ───── bounded downloads / redirect lookup
              ├─ Http.Json ─────── buffered LLM + Tavily JSON POST
              ├─ Http.Stream ───── LLM SSE POST
              ├─ Embedding effect ─ validated records over a bounded
              │                     OpenAI-compatible JSON POST
              ├─ MCP.Client ────── bounded browser MCP JSON/SSE response
              ├─ Matrix ────────── sync/backfill + idempotent send/media upload
              ├─ iMessage ──────── authenticated bridge catch-up/send/media
              └─ Wechatpad ─────── bounded outbound relay POST
```

The runtime boundary owns request execution, connection reuse, response-body
lifetime, body/diagnostic limits, and transport classification. Protocol
decoding and retry decisions stay with callers. In particular, the primitive
never silently replays a request. Buffered LLM calls use a caller-selected
schedule (normally 2/8 seconds; Historian selects none), while streamed reply
calls retry only before text or tool-call output becomes observable, using the
longer 2/8/20/45/90-second schedule.

The OneBot reverse WebSocket, WeChatPad inbound WebSocket, and browser page
traffic inside the camoufox container are not outbound HTTP clients and remain
outside this runtime. Matrix and iMessage use `StandardPool`; future HTTP
adapters must do the same. Any long-lived WebSocket transport remains a
platform-edge resource.

`ModelCatalog` owns profile discovery and prompt-facing capabilities such as
multimodal input, reasoning effort and history shape. `LLM` owns completion
calls only; its production interpreter uses the catalog internally to resolve
the selected profile's endpoint and credentials. This keeps command and prompt
code from depending on transport secrets or growing catalog operations into the
completion effect.

`PlatformApi` is the low-level capability for raw platform actions and
request/response calls. Its interpreter routes each action to a
`PlatformBackend`; the default QQ backend is implemented by NapCat over the
reverse WebSocket, while backend-specific names stay at that protocol edge.
Visible conversation sends sit one layer above it in `Outbound`.

`Blob` is the sole owner of the configured storage root. Producers receive an
opaque, validated `BlobRef` from `putBlob`; ordinary consumers pass that
reference back to `readBlob` and never assemble a host path themselves. The
boundary has one deliberately loud escape hatch:

```
runBlob(root)
  ├─ putBlob bytes             ──▶ BlobRef
  ├─ readBlob BlobRef          ──▶ bytes
  └─ resolveBlobHostPath ref   ──▶ host path
                                   ├─ Docker cp import
                                   └─ ffmpeg video/GIF frame extraction
```

`BotEnv` therefore carries no blob root. The database still receives derived
`sha256` and `local_path` values for schema compatibility, but readers recover a
`BlobRef` from the digest and do not treat the persisted path as authority.

`Outbound` owns canonical publication, not transport IO. It commits one bot
message, its reply relation, and per-endpoint delivery jobs first; leased
workers then render and send each native copy. Before the turn, `Handler` reads
the intersection of enabled endpoint output capabilities and uses it both to
constrain the prompt grammar and to gate action-token execution. QQ mentions,
faces, and reaction actions additionally require an all-QQ conversation; a
legacy numeric ID is only a locator and never implies the protocol. Matrix
retries with a deterministic transaction key.
Non-idempotent QQ/iMessage timeout is recorded as outcome-unknown and can move
again only after echo or authoritative status reconciliation. A transport can
therefore be down without producing an externally visible message that the
canonical ledger forgot.

`Agent` depends on `LLM`, scoped `Tools`, an explicit `TurnRuntime`, logging,
and its typed `AgentEventSink`; it has no OneBot segment, `Outbound`, or message
persistence dependency.  The production sink is assembled per dispatch in
`Handler`, where reply target, debug policy, and the shared stream budget are
known.

Each `AgentTurn` adds two narrower scopes inside the process stack:

```
Handler
  └─ TurnRuntime + AgentContext (ToolContext + LLM effort)
       └─ Agent
            ├─ validated catalog (schema hash + effects + authority + retry class)
            ├─ runTools (allToolsFor ToolContext)
            │    └─ concrete tool ──queueInlineMedia──▶ ToolOutput
            └─ drainInlineMedia ──▶ next LLM tool round
```

Catalog construction rejects duplicate names, malformed schemas, and
definition/runner drift before the LLM sees the tool list. Calls in one model
round run concurrently only when every definition declares `ParallelSafe`;
write/send/LLM/reflective calls serialize. Results are normalized as rejected,
failed-before-effect, succeeded, committed, or outcome-unknown, while keeping
the existing model-facing error strings. `!version` counts the same gated
inventory used to build the live catalog.

`ToolContext` is opaque and is minted once from the already-authorized inbound
turn identity. It carries current-conversation authority alongside capability
gates; model-provided ids can select resources only inside that scope and
cannot construct another conversation authority. Concrete tools do not import
`Agent`. `ToolOutput` owns a fresh media queue per turn;
draining a round clears queued media but preserves the turn-wide attachment
counter. This prevents concurrent turns from sharing output state and keeps
mutable queue mechanics out of context records. Embedding consumers use the
injectable `Embedding` effect; only its production interpreter holds the HTTP
client/model configuration.

`Handler` creates a `TurnRuntime` at dispatch admission and is its sole
finalizer. The same object carries phase, cancellation, feedback, absorbed
messages, and task identity through context collection and every Agent node;
there is no trigger-id lookup/adoption on the production path. Failed message
persistence is an explicit non-durable ingest state: media jobs, agent dispatch,
and proactive work are suppressed while the event loop remains alive.
Agent regression tests exercise feedback before an LLM node, asynchronous
`!kill`, late feedback racing streamed output, and root-owned cleanup through
this same runtime seam.

Recall authority records both the current turn and its readable source. The
ordinary constructor makes them identical. A separate opaque proof can express
only an explicitly host-authorized group source projected into a direct-message
turn; reversed DM-to-group and same-kind projections cannot be constructed.

Workers are started as one flat list (`withLinkedWorkers` in `app/Main.hs`),
each `link`ed so a worker dying silently takes the process down rather than
leaving a stuck queue behind. An optional worker is an action that does nothing
when its config is absent — the async finishes immediately and linking a
finished async is a no-op, so "feature off" needs no special case.

## Phase status

| Phase | What | Status |
|---|---|---|
| 1–3 | OneBot 11 transport, supervision, persistence (messages/images/forwards) | ✅ |
| 4 | Vector retrieval via pgvector (`context_search`) | ✅ |
| 5 | effectful layering, LLM client, async dispatch | ✅ |
| 6 | !cmd DSL, sessions, agent loop, sandbox/files/search tools | ✅ |
| 7 | Multimodal (inline context images) + browser toolset | ✅ |
| 8 | Long-term memory (tools + extraction + injection) | ✅ |
| 9 | Private chats (pseudo-group pipeline) | ✅ |
| 10 | NixOS module + production deployment | ✅ |
| 11 | Admin JSON API + panel | ✅ |
| 12 | Skills (progressive disclosure) + episode memory extraction | ✅ |
| 13 | Token-planned infinite context + unified Historian/memory lifecycle | ✅ |
| 14 | Merged self-knowledge + exact deployed-source inspection | ✅ |
