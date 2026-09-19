# Architecture

Cross-cutting decisions are recorded in:

- [`ADR 001: Context and Memory Foundations`](adr/001-context-memory-foundations.md)
- [`ADR 002: Partial Plans and Adaptive Elaboration`](adr/002-partial-plans-adaptive-elaboration.md)
  — planning direction superseded by ADR 008; reliability contracts retained
- [`ADR 003: Message IR and Capability-Tiered Rendering`](adr/003-message-ir-capability-rendering.md)
- [`ADR 004: Canonical Handles and the Identity the Model Addresses`](adr/004-canonical-handles-for-the-model.md)
- [`ADR 005: Turn Continuity — Journal Projections and Verbatim Replay`](adr/005-turn-continuity.md)
- [`ADR 006: Monitors — Typed Triggers and the Unified Scheduler`](adr/006-monitors-typed-triggers.md)
- [`ADR 007: Plans as Orchestration — Fork, Steering, and What the Kernel Is Actually For`](adr/007-plans-as-orchestration.md)
  — existing implementation; authoring direction superseded by ADR 008
- [`ADR 008: Durable Tasks and Conversation Coordination`](adr/008-durable-tasks-conversation-coordination.md)
  — implemented cutover candidate; production validation pending

Layout, runtime data flow, effect stack, and phase status. For behaviour see
[features.md](features.md); for tests and debugging see
[development.md](development.md), and for transport cutover/repair see
[platforms.md](platforms.md).

Configuration is read once at startup. One supervised worker group owns the
process resources; changes take effect after a bounded shutdown and restart.
See [`runbooks/config-restart.md`](runbooks/config-restart.md).

## Layout

```
flake.nix          devenv shell as a flake module (GHC 9.10, Postgres 17 + pgvector)
devenv.nix         service definitions + .env sourcing on shell entry
nix/runtime.nix    max-stack.target, Haskell broker and systemd templates
nix/sandbox-guest.nix Prebuilt NixOS sandbox, shared read-only host store
nix/napcat-module.nix Native NapCat and dedicated outbox handoff
browser-image/     Camoufox MCP patches and acceptance fixtures
nix/module.nix     NixOS module for production deployment
.github/workflows/ CI: independent build/lint, pure-test and
                   PostgreSQL/pgvector-test jobs through the flake dev shell,
                   plus a pure `nix build .#max` so one failure cannot hide
                   another and the packaged build cannot rot
max.cabal          library + max executable
migrations/*.sql   schema migrations, applied on boot
skills/*.md        builtin skill manuals, baked into the binary (file-embed);
                   self-knowledge navigates the source snapshot + splices live
                   !help and this build's !version identity

src/OneBot/        OneBot 11 wire protocol: types (incl. private-chat pseudo-groups),
                   segments, events, actions, server
src/Max/Effects/   effectful 2.5 effects: Http, Blob, Embedding (injectable validated
                   vectors), PlatformQuery/Interaction/Account, Outbound (visible send
                   + persistence), LLM (OpenAI + Anthropic + Responses, buffered or streamed),
                   Tools execution, ToolDirectory, ToolOutput/ToolOutputRead,
                   ToolControl, TaskQuery/TaskControl/TaskExecution, TurnQuery,
                   Agent (DB effect from upstream effectful-postgresql)
src/Max/Tool/      pure tool catalog, schemas, host metadata and loop control
src/Max/Agent/     local admission, diagnostic storage, inbox contracts and Jobs assembly
src/Max/Execution/ shared tool budgets, invocation and outcome recording
src/Max/LLM/       Types/Protocol/Stream: pure codecs and stream reconstruction;
                   Configuration/Admission/Transport/Observability: call components
src/Max/Http/      Json: bounded buffered POST + domain retries; Stream: SSE folding;
                   both execute through the process-wide HttpRuntime pools
src/Max/HttpRuntime process-wide http-client managers, bounded response scopes,
                    and typed transport failures
src/Max/DB/        postgresql-simple queries: Connection, pinned Transaction,
                   Migrations, Message, Forward,
                   History, ConversationCursor, Session, Files, Memory, Permissions,
                   PlatformIds, Reminder, Stickers, MediaMissing (derived media),
                   Calls, Usage
src/Max/Command/   !cmd DSL: Types, Parser (megaparsec), Dispatcher, Help (the
                   !help text — a leaf module so the self-knowledge skill can
                   splice it at registry init)
src/Max/Session/   Per-conversation session: versioned TVar handle + serialized CAS persistence
src/Max/Sandbox/   Per-group NixOS workspace lifecycle + registry
src/Max/Browser/   Per-group camoufox host + per-turn MCP/browser lifecycle
src/Max/MCP/       Minimal MCP client (Streamable HTTP)
src/Max/Tools/     Tool implementations (Files, Sandbox, Search, Browser, Memory,
                   Images, Video, Bilibili, Stickers, Pins, Group, Reminder,
                   Skills — progressive disclosure, SelfSource — bounded reads
                   of the allowlisted compile-time source snapshot)
src/Max/           Config (opt-env-conf), Env (BotEnv Reader), Prompt, Handler,
                   Platform.Types/Store/Delivery (canonical conversations,
                   identities, native provenance, ingest cursors and receipts), QQ normalization, Matrix and iMessage adapters,
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
                   typed local queues), Media (missing-source scan), MediaCaption + Stickers (caption workers),
                   Conversation (local queue), Turn + Task, Monitor
                   (typed trigger scheduler), Reminder, Reply (planning),
                   ReplySend (planning made real:
                   placeholders, sending, persistence — shared by final,
                   streamed, and progress text), Render, Roster, Shutdown (graceful
                   drain), Tasks, Worker (required/optional/restartable
                   supervision),
                   Tools, BuildInfo (compile-time git rev), Admin (JSON API +
                   panel and operational health counters), Util
app/Main.hs        wires effects + workers + server
```

## Data flow

```
 QQ/NapCat ─┐
 Matrix ────┼─ normalize ─▶ canonical event/message transaction
 iMessage ──┘                 ├─ source provenance + source delivery
                              ├─ mirror endpoint delivery jobs
                              └─ fresh live event → bounded STM queue
                                           │
       ┌──────────────────────── handleEvents ───────────────────────────┐
       │ read one committed message from the process queue              │
       │   1. enqueueImages / enqueueForwards / enqueueFiles → local queues│
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

QQ, Matrix, and a configured iMessage chat may be endpoints of the same
canonical conversation; an iMessage endpoint may also remain standalone.
The ingress queue belongs to the running process. Restart preserves messages but
never reconstructs old dispatch or delivery work. Per-platform senders serialize
each destination and keep retry schedules in memory.
Matrix retries reuse deterministic transaction IDs. Non-idempotent
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
and without rewinding the live cursor. Recorded memory expiry dates are processed without a model or execution lease.
Version and source changes reject stale expiry, and permanent memories stay
protected. The model-driven dream pass has been retired.

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
materialization revision or context-plan trace. Its consumer receives only
`ContextQuery`; `Prompt.Runtime` installs the read-only interpreter.
`Prompt.Collect` and `Prompt.History` load snapshots, `Prompt.Render` contains
pure planning/rendering/cost accounting, and `Prompt.Materialize` alone owns
materialization publication. The ordinary prompt facade assembles those phases;
preview does not select a write path through a runtime boolean.
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
documentation in every prompt. `self-knowledge` is the single entry point: a
navigation map over the embedded source snapshot plus the live `!help` splice.
Behaviour, architecture, design rationale and schema are read through
`inspect_source` from the files themselves (`docs/`, `docs/adr/`,
`migrations/000_baseline.sql`, `src/`), never mirrored into skill bodies that
would drift. A DB skill can shadow the built-in under the ordinary
group > DB-global > builtin rule.

Exact implementation questions bypass prose summaries. After loading `self-knowledge`, the
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
instead of waiting for a whole body. Safe fragments go
out mid-generation as typed `AgentFinalStreamText` events; tool narration and
debug facts use distinct event constructors. `Max.AgentEvent` interprets all
model-authored text through `ReplySend`, while the loop only reports how much
was accepted as `AgentResult.sentPrefix` and the handler sends the rest.
`readyPrefix` releases completed paragraphs, or plain-text sentences after
at least 48 characters. At 240 characters it also allows word/CJK boundaries.
It holds markup and incomplete tokens. The sender reserves its last message
slot for the final tail, and only acknowledged fragments advance `sentPrefix`.

## Durability

Postgres retains user data and completed results. Execution queues and running
Jobs belong to the process; a restart does not resume them.

| Survives a restart | How |
|---|---|
| Messages, sessions, memories, stickers, permissions, skills | written through on every mutation; Session persists revision CAS before publishing its TVar (builtin skills re-seed from the binary) |
| Media sources and completed attachments | Canonical messages retain URLs/native references; startup and periodic scans discover missing images/videos/files/forward content. Typed bounded queues execute reads locally, prioritizing live ingress. `forward_expansions` distinguishes an empty completed expansion from partial import; old `fetch_jobs` are archived diagnostics |
| Pending historian capture | leased `episode_capture_runs` rows plus the conversation-scoped historian cursor; boot drains jobs, then re-arms any conversation with newer raw rows |
| Tiered prompt prefix | current `context_materializations` revision plus append-only versions; active compartment ids/versions, tiers, end cursor, policy, fingerprint, and cache-bust reason are durable |
| Episode expansion handles | random UUID on the immutable compartment; scoped lookup recovers the exact raw ingest range, including after supersession |
| Monitors and reminders | `monitors` and `monitor_fires` hold TimeCron/LedgerMatch state, retry, provenance, caps and one-time Jobs admission; the scheduler handle is only a wakeup bell |
| Embeddings, captions | workers poll messages, memories, active episode summaries, stickers, and media for missing/incompatible derived data, so any gap or model change backfills itself |
| Embedding ownership | one process-local lock serializes the worker and explicit reindex; conditional writes reject changed source content and memory versions |
| Agent turn record and effect facts | `agent_turns` assigns a conversation-scoped ordinal at admission; `execution_journal` stores completed diagnostics with locally allocated result ordinals. Diagnostic write failure is logged without changing a completed outcome. Boot ends interrupted turns as crashed; it never reopens their model loop; visible output rows carry `(agent_turn_id, turn_chunk_index)` |
| Background Jobs and child work | Bounded STM state holds goals, ownership, budgets, results, feedback and joins. Workers use the ordinary agent runtime and stop on restart. The public ID sequence is retained; old task tables are historical only. Child grants remain bounded by their parent |
| Sandbox workspaces | `sandboxes` persists lifecycle metadata and the root-owned runtime work directory holds current state. Boot adopts only a running container carrying the current broker generation and matching systemd invocation; otherwise it rebuilds a non-root, capability-free, resource-capped, read-only shell around the surviving volume. NixOS owns network provisioning and host/private/peer filtering; Haskell owns instance reconciliation and the privileged broker API. Only a positively absent volume marks the workspace destroyed, and 14-day sliding TTL GC replaces shutdown/boot reaping |

| Lost on restart | Why |
|---|---|
| In-flight agent turns and tool calls | Local tasks and provider calls stop with the process. Completed diagnostics remain available; interrupted model rounds and uncertain external effects are not automatically replayed |
| Triggers arriving mid-drain | persisted to `messages` and logged, but not dispatched |
| QQ events unavailable from NapCat's bounded history actions | Reconnect atomically queues a recovery barrier before live frames, then pulls latest and last-seen-sequence pages for known enabled group/friend endpoints. Rows older than the reconnect second enter as non-dispatching, non-mirroring `Backfill` and native event identity removes overlap. `qq_backfill_runs` records counts and stop reasons. NapCat still exposes no durable cursor or offline-complete notices, so reactions, recalls, malformed rows and messages outside the bounded windows remain possible source gaps |
| `!use` admin targets | deliberate — just `!use` again |
| Browser hosts and turn instances | ephemeral: each conversation's lightweight container host is destroyed on exit and reaped on boot; every turn's independent MCP transport and camoufox browse session is terminated when that turn finishes |

Effect stack at the top of `runApp`:
`IOE → Concurrent → Log → Http → BlobHost → Blob → WithConnection → Outbound → LLM → Reader ModelCatalog → Reader BotEnv → PlatformAccount → PlatformInteraction → PlatformQuery → Embedding → Agent`.

### Sandbox concurrency

Independent `sandbox_exec` calls can run in parallel, including from different
tasks in one conversation. There is no task-wide sandbox reservation; legacy
`task_resource_owners` rows are retained as unused schema history and do not
grant or deny access. Tool admission still checks the current task and group,
and the registry still rejects a sandbox owned by another conversation.

Shared access gates in the registry and root broker protect command lifetimes.
Lifecycle writers close admission and drain all users before rebuilding or
removing an instance. Package roots are serialized only for the same instance
and package expression. Guest commands use distinct systemd units; observation
markers and output spills use unique IDs. Cancellation releases only that
command's access, and filesystem observations describe the shared workspace.

### Skill visibility and SSH operations

ADR-010 separates the authorized tool ceiling from the current model catalog.
`use_skill` emits typed `LoadSkills` control; the agent updates its local visibility
snapshot between rounds. Full instructions and fixed dependencies load together.
Successful host receipts retain the current turn's loaded bundles; a new turn
starts with base tools. Catalog and invocation admission share the snapshot, so
same-batch calls cannot use a just-loaded capability early. Loaded manuals and
the latest tool results survive normal result trimming.

The `operations` skill loads sandbox tools after the broker confirms the group
has the dedicated Tailscale network. Commands use ordinary SSH, and background
operations inherit the parent shell grants. Remote systemd jobs retain long-running
work across SSH disconnects; see [SSH operations](runbooks/ssh-operations.md).
Task profiles select tools (`research`, `browser`, `sandbox`); skills describe
methods (`sandbox` for shell mechanics, `operations` for fleet work); conversation
configuration selects networking. Neither a task profile nor skill loading changes network access:
the broker selects it from the canonical conversation and configured group list.
There is no separate read-only SSH grant within an enabled operations network.

Legacy `operations` task/monitor profiles and frozen snapshots decode as `sandbox`;
new writes use `sandbox`. Original rows and journals remain unchanged. Each explicit workflow child call
creates new work; there is no cross-call result reuse or restart continuation.

`max.service` and the broker client use `max-service`; the broker runs as root.
The dedicated client and network belong to `max-stack.target` and `max.slice`.
Fleet SSH targets authenticate `max`, a separate full-sudo operator account.
Persisted skill receipts and `/work` checkouts can predate a release; deployment
does not rewrite old task goals, monitors, DB skill overrides or workspace files.

`Conversation` serializes foreground work per conversation using STM tickets.
There are at most 256 tickets per conversation and 1,024 across the process.
Waiting turns retain their original dispatch context; they are not reclassified.
Only explicit feedback from the active initiator enters its inbox, in canonical
ingestion order. Unread feedback becomes an independent turn when the owner exits.
Queued foreground requests precede queued task notices. Commands remain responsive.

`!kill` revokes process-local publication authority before signalling the worker.
The dispatch finalizer releases its queue ticket even if database cleanup fails.
Interrupted foreground turns end without restart continuation; published prefixes
remain recorded. Jobs own detached work, child results and feedback in STM. A
parent awaiting children holds no worker slot. Each root shares 200 tool calls
and 400 model rounds; children inherit its deadline and grant fingerprints.
Cancellation and replacement fence the old generation before signalling it.
Outbound copies belong to bounded process queues; restart never reconstructs them.

### PostgreSQL transaction ownership

Every multi-statement publication uses `Max.DB.Transaction.withTransaction`.
This wrapper acquires one physical pooled connection and interposes the
`WithConnection` effect for the whole body, so every nested `query`/`execute`
uses that same connection. This is required because effectful-postgresql
0.1.0.1's pooled transaction wrapper starts `BEGIN` on one connection while
body operations may otherwise reacquire another. The local wrapper makes
rollback, row locks, advisory transaction locks, and commit visibility real.
Nested operations use savepoints and cannot commit their caller's transaction.
The wrapper introduces an opaque `InTransaction` effect. Authorization and
mutation helpers that depend on row locks require this evidence, so an ordinary
`WithConnection` caller cannot invoke them outside a transaction. Standalone
cache publication still requires a completed outermost commit. Dispatch and
delivery readers decode typed canonical bodies; corrupt JSON raises
`ConversionFailed` before transport execution.
Jobs reserve calls and model rounds atomically in STM before execution. Completed
tool results remain queryable in PostgreSQL; diagnostic write failures are logged
without changing a completed outcome. Uncertain effects are never replayed or
used to refund a reservation.

Task tools are assembled with bound conversation, caller and execution scopes.
Their code holds TaskQuery/TaskControl/TaskExecution and TurnQuery capabilities,
without raw SQL, Blob or IO access. Task control checks local liveness and rechecks the bound caller under a
conversation transaction; administrative authority is absent from that interface.
Monitor and reminder tools similarly receive MonitorQuery/MonitorControl;
list/history readers have no control capability. Host assembly supplies one
clock value per invocation. The write interpreter rechecks the bound actor,
conversation and live turn in the definition transaction; elaborated
arming also requires the host role, and the frozen grants come from assembly.
Task, monitor and memory control use the same caller-authorization primitive.
Memory tools hold MemoryQuery/MemoryControl. Their actor, evidence and permanent
lifecycle come from the interpreter; source identity and live turn are
rechecked with the write. Explicit saves and Historian proposals share locked
admission for the 30-item namespace capacity; Historian also rejects exact
duplicates within that transaction. Publication takes the conversation lock
before run/cursor rows, matching the tool write lock order.
Time parsing and cron calculation are pure modules, independent of tools and
the scheduler. Task list/detail, monitor history and the admin work overview
are decoded into domain values and rendered by Haskell.
Standalone multi-query details run in a read-only repeatable snapshot; nested
reads inherit the caller transaction. SQL retains filters, limits and aggregates.
Conversation built-ins use ConversationQuery for scoped message, forward,
recall and episode reads, plus TurnQuery for cleared-watermark trace access.
History/media/episode/recall read types do not import store implementations.
Prompt and tool reads share the pure Context.Media renderer; media enrichment
runs only after scoped rows have been selected.
MediaQuery supplies scoped image/video/file reads, and StickerQuery owns the
compatible, unbanned shared-library search. Group tools use the conversation
roster reader. Known identities are recorded per endpoint at ingest or a
contentless interaction; sharing a bot account does not reveal another room
or authorize a foreign mention. Migration 097 reconstructs this projection
from canonical senders/mentions, turn initiators and each endpoint's own account.
PinControl allows pin/unpin only; its authorization runs after
the local Session mutex and database row lock, immediately before the update
in the same transaction. Session cache publication follows COMMIT and rejects
nested transactions that could later roll back.
Image preparation is a host callback owning ffmpeg. Browser workspace ownership
is established in Browser.ToolRuntime before native MCP tools run. The domain
browser and file tools receive scoped `Browser` and `FileTransfer` operations. Their host interpreters own MCP sessions, output allocation,
canonical caption resolution and persistence. `Sandbox` binds a group without
exposing its registry or mutable entries; `Search` and `SkillLoading` similarly
hide network credentials and skill registry mechanics from their consumers.
Compile-negative architecture fixtures verify that each capability, including
`ContextQuery`, cannot be used to perform arbitrary IO.

The Agent loop receives separate local admission, diagnostic storage and inbox
contracts from `Agent.Runtime`; it imports no database implementation. Jobs
reserve shared budgets in STM. Tool invocation does not depend on a pre-effect
database write. Outcomes and large result artifacts remain queryable through
scoped `t#…:r…` references; cancellation records an unknown outcome when possible.
A process crash can leave the last result absent, and never causes replay.
Successful skill loaders emit typed `LoadSkills` controls through a per-invocation
`ToolControl` scope. They take effect in the next model round. Normal final text
ends the loop, with no finish or yield tool protocol.

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
              └─ WechatHook ────── bounded outbound hook POST
```

The runtime boundary owns request execution, connection reuse, response-body
lifetime, body/diagnostic limits, and transport classification. Protocol
decoding and retry decisions stay with callers. In particular, the primitive
never silently replays a request. Buffered LLM calls use a caller-selected
schedule (normally 2/8 seconds; Historian selects none), while streamed reply
calls retry only before text or tool-call output becomes observable, using the
longer 2/8/20/45/90-second schedule. `Http.Failure` and `LLM.Failure` retain
structured causes through `AgentFailure` into task settlement. HTTP 408/429/5xx
and temporary connection failures are retryable; diagnostic words such as
"provider" or "timeout" in a 4xx body do not override its status. Partial streams
have their own terminal outcome and never trigger a durable automatic replay.

The OneBot reverse WebSocket and browser page
traffic inside the camoufox container are not outbound HTTP clients and remain
outside this runtime. Matrix and iMessage use `StandardPool`; future HTTP
adapters must do the same. Any long-lived WebSocket transport remains a
platform-edge resource.

The browser registry shares only a ordinary systemd browser service per conversation.
Task browser sessions have no automatic checkpoint/restore. Only an explicit
`!browser save` exports an encrypted, origin-filtered profile; an owner can use
that retained profile in a later job. Ambiguous actions block further use until
explicit reset confirms closure. Cancellation and `!clear --all` revoke access
before the next action, including jobs that have not opened a browser yet.

Foreground turns and process-owned background Jobs each own a separate MCP client,
Streamable-HTTP session, camoufox browse session, and operation lock. Sibling
turns in one group therefore navigate concurrently without page-state or MCP
request-id interference; calls inside one stateful page remain ordered. Turn
finalization closes the browse session and terminates its MCP transport with a
bounded cleanup, while `!clear --all` and process exit retain the stronger
container teardown fallback.

`ModelCatalog` owns profile discovery and prompt-facing capabilities such as
multimodal input, reasoning effort and history shape. `LLM` owns completion
calls only; its production interpreter uses the catalog internally to resolve
the selected profile's endpoint and credentials. This keeps command and prompt
code from depending on transport secrets or growing catalog operations into the
completion effect.

`PlatformQuery` reads typed group metadata, members, file addresses and forward
payloads. `PlatformInteraction` permits poke; `PlatformAccount` permits responding
to friend requests and is only required at ingress. Roster and permission readers
do not receive either write capability. Each interpreter routes through the same
canonical endpoint ownership check; a missing foreign backend cannot fall back to
QQ. The platform backends are fixed at startup.
Raw `OneBot.Action` and response envelopes stay in the platform adapters and
interpreters. Content and recorded reactions continue through `Outbound`.

The current reverse-WebSocket client is generation-tagged. The dedicated QQ
history query checks its generation before and after each call, and returns
`PlatformGenerationChanged` if replaced; recovery never decides this from error
text. Cleanup from a superseded socket cannot erase a newer published client.

Assembly installs `Blob` and `BlobHost` with the same configured storage root.
Producers receive an opaque, validated `BlobRef` from `putBlob`; ordinary consumers
only need content access. Host path bridging is a separate capability supplied to
the sandbox import and ffmpeg adapters:

```
Blob
  ├─ putBlob bytes             ──▶ BlobRef
  └─ readBlob BlobRef          ──▶ bytes
BlobHost
  └─ resolveBlobHostPath ref   ──▶ host path (unprivileged runtime client / ffmpeg)
```

`BotEnv` therefore carries no blob root. The database still receives derived
`sha256` and `local_path` values for schema compatibility, but readers recover a
`BlobRef` from the digest and do not treat the persisted path as authority.

`Outbound` commits a bot message, reply relation and endpoint copies, then queues
those copies in memory. The bounded queue owns ordering and retries; database
rows retain native receipts and diagnostics. Each platform has one sender, and
a delayed retry blocks only later copies to that destination. Restart closes
unfinished rows without resending them. Inbound dispatch also uses a bounded
queue of freshly committed messages; the handler hands model work to the
conversation queue and never reruns a failed command automatically.
Before the turn, `Handler` reads
the conversation's semantic output capabilities. Content with a total lower
path remains available across mixed endpoints; native encoding is decided per
endpoint. QQ faces and reactions require an enabled QQ endpoint, and reaction
targets still require a valid native copy.

Canonical publication returns `Published` or `PublicationFailed`; it makes no
claim about physical delivery. `ReplySend` spends budget only on committed
chunks and stops at the first failure. Stream publication failure escapes the
provider retry path, preserving the committed prefix without replaying it.
`Max.Reply.Resolve` supplies the shared model-text resolver for replies,
reminders and artifact captions, with no publication or transport authority.
Sandbox images and files both publish blob-backed canonical messages; bounded
container reads precede host allocation. The QQ delivery adapter alone owns
file-upload staging and the NapCat mount path.

Migration 092 records every wire chunk in `message_delivery_parts`, including
its fingerprint, stable transaction key, status and native receipt. Echoes,
replies and actions resolve through `message_delivery_copies`, including
historical single-receipt deliveries. Reconciliation confirms individual parts;
the parent becomes confirmed only when all parts are proven. A retry must keep
the same wire plan and skips successful parts. Matrix may replay uncertain
parts with stable transaction keys; QQ/iMessage require proof of no effect
before retrying an uncertain part.

`Max.Concurrent.Lease` remains around fetch and maintenance work pending their
cutover. `Max.Concurrent.Lock` supplies keyed locks and entry-owned mutexes.
Delivery has no lease heartbeat or SQL claim. Receipt reconciliation can confirm
historical sends, but its retry admission is restricted to IDs allocated after
this process started.

The Mac-side iMessage bridge derives native-reply capability from a live
`imsg status` probe instead of configuration. Max records capability changes on
the endpoint, so the prompt grammar and relation resolver move together. A
resolved relation is sent as `reply_to`; both the bridge policy boundary and
`imsg` reject it when the injected IMCore helper is unavailable. There is no
silent downgrade after native-reply execution has been selected. Ordinary
sends stay on AppleScript. IMCore's immediate best-effort GUID is never allowed
to identify a native reply; the authoritative catch-up echo confirms it, and
the delivery store discards any provider receipt already owned by another row
instead of violating endpoint provenance uniqueness.

`Agent` depends on `LLM`, scoped `Tools`, an explicit `TurnRuntime`, logging,
and its typed `AgentEventSink`; it has no OneBot segment, `Outbound`, or message
persistence dependency.  The production sink is assembled per dispatch in
`Handler`, where reply target, debug policy, and the shared stream budget are
known.

Each `AgentTurn` installs narrower scopes inside the process stack:

```
Handler
  └─ TurnRuntime + AgentContext (ToolContext + LLM effort)
       └─ Agent
            ├─ ToolDirectory ◀── pure ToolCatalog (schema + host metadata)
            ├─ runToolsWith ◀── ToolRegistry (validated closures)
            │    └─ concrete tool ──queueInlineMedia──▶ ToolOutput
            └─ ToolOutputRead ──drainInlineMedia──▶ next LLM tool round
```

Catalog construction rejects duplicate names, malformed schemas, and
definition/runner drift before the LLM sees the tool list. Calls in one model
round run concurrently only when every definition declares `ParallelSafe` or
`ParallelIndependent`. The latter explicitly permits independent sandbox writes;
other write/send/LLM/reflective calls serialize. Parallelism does not make a write
safe to retry. Results are normalized as rejected,
failed-before-effect, succeeded, committed, or outcome-unknown, while keeping
the existing model-facing error strings. `!version` counts the same gated
inventory used to build the live catalog.

`Max.Schema` parses tool schemas and workflow `Contract`s into a shared typed
validation tree, retaining the original JSON for provider requests and hashes.
The workflow dialect remains stricter. `Max.Tool.Arguments` combines an
applicative argument parser with schema generation; skill loading, search and
pins use it so their fields have one definition. Other legacy
tool schemas are parsed and checked at catalog construction.

`OutcomeRunner` reports `ToolOutcome` directly, and hoisting preserves it.
A mutating `LegacyRunner` returning `Left` remains outcome-unknown; the kernel
never derives a pre-effect guarantee from catalog metadata. The historical
`tdFailuresPrecedeEffects` field exists only to preserve durable catalog/grant
fingerprints. Exceptions and timeouts remain conservative for both runner forms.
Shared invocation labels and budgets use `Concurrent` MVars/TVars, including
under timeout races; they are not thread-local state.

`Turn.Start` distinguishes new foreground requests from task execution/notices. `TaskCommand` requires a
`TaskRevision` for replacement, while its mutation boundary distinguishes
`DurableTaskId`, `GroupId` and `PrincipalId`. `Dispatch.Lease` settles the short
ingress claim when the process queue accepts it. No lease renewal runs during
the foreground model loop.

`ToolContext` is opaque and is minted once from the already-authorized inbound
turn identity. It carries current-conversation authority alongside capability
gates; model-provided ids can select resources only inside that scope and
cannot construct another conversation authority. Concrete tools do not import
`Agent`. `Max.AgentEvent` is the pure output protocol; `Max.AgentOutput` owns its
production sink and reply publication. Assembly creates one fresh media queue per
turn and installs separate `ToolOutput` producer and `ToolOutputRead` consumer
interpreters over it;
draining a round clears queued media but preserves the turn-wide attachment
counter. This prevents concurrent turns from sharing output state and keeps
mutable queue mechanics out of context records. Embedding consumers use the
injectable `Embedding` effect. Its assembly supplies a client resolver from the
current leased scope; the effect no longer imports `BotEnv`. The bounded `Http`
effect preserves typed transport, status and size-limit failures, with compatibility
pool policy chosen by its interpreter for QQ/Bilibili media downloads.

`scripts/check-architecture.py` checks pure-domain imports, raw RPC placement and
approved host-path adapters. Compiler fixtures prove that read-only directories,
platform queries and media producers cannot acquire the corresponding write or
consume permissions. A positive fixture must compile before any denial is accepted.

Tools that append to that turn-wide media queue are classified as stateful and
run sequentially within the turn, which makes attachment order and the shared
budget deterministic. Independent turns still have independent queues and run
in parallel.

`Handler` creates a `TurnRuntime` at dispatch admission and is its sole
finalizer. The same object carries phase, cancellation, feedback, absorbed
messages, and task identity through context collection and every Agent node;
there is no trigger-id lookup/adoption on the production path. Failed message
persistence is an explicit non-durable ingest state: media jobs, agent dispatch,
and proactive work are suppressed while the event loop remains alive.
The shutdown slot, durable turn, in-memory runtime, and child async are handed
off under asynchronous-exception masking; before publication the caller owns
rollback, and after publication the child finalizer owns every resource. The
child body itself is restored to the normal cancellable state.
Agent regression tests exercise feedback before an LLM node, asynchronous
`!kill`, late feedback racing streamed output, and root-owned cleanup through
this same runtime seam.

Recall authority records both the current turn and its readable source. The
ordinary constructor makes them identical. A separate opaque proof can express
only an explicitly host-authorized group source projected into a direct-message
turn; reversed DM-to-group and same-kind projections cannot be constructed.

Workers are assembled once at startup and supervised
through `withWorkers`. Required queue owners (fetch, monitor, dispatch, Jobs,
delivery) turn either an exception or a normal return into process failure.
Config-disabled workers are omitted. Enabled optional edges (embedding,
Historian, intent, admin, WeChat, Matrix, iMessage) are `RestartableWorker`s:
synchronous failures stay inside that edge and retry with bounded exponential
backoff, while asynchronous shutdown still propagates. The bounded
shutdown-drain action is the only `OptionalWorker` whose normal return is part
of its contract. The process owns one OneBot listener and client slot.

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
| 15 | Canonical message IR, identities, per-endpoint capability lowering, QQ/Matrix/iMessage/WeChat ingress and mirror delivery | ✅ |
| 16 | Durable turns/journal replay, typed monitors, reconnect QQ history audit | ✅, with QQ coverage explicitly best-effort |
| 17 | Historical Plan DSL and fork/checkpoint orchestration | Retired by ADR 008; execution journal and turn runtime retained |
| 18 | Configuration lifetime, admin timeline and operational health | Configuration generations retired; changes now restart the service. Live health acceptance remains pending. |
| 19 | ADR 008 durable task interface, monitor-to-task admission, durable inboxes and conversation frontend | Initial cutover reported complete by operator; follow-up adds fivefold quotas, provider admission, progress/retries and Plan retirement (migration 088) |

Remaining work is intentionally narrower than these completed phases:

- ADR 004: explicit cross-platform principal merge.
- ADR 005: small-model thought/digest cache and narrator unification.
- ADR 006/008: monitor-to-task admission, overlap/revision/cancellation and admin
  visibility are implemented. `ExternalPoll` remains deliberately deferred.
- ADR 008: validate real task outcomes and production health at the coordinated
  switch; token/cost ceilings and arbitrary task-specific result schemas are
  not claimed. Migration 088 archives old Plan work without replay and removes
  its runtime. New Task data, reservations and journal evidence survive upgrade.
  Ordinary hole elaboration, adaptive horizon, and expanded Plan grammar are
  retired directions, not unfinished milestones.
- ADR 003 operations: share iMessage bridge circuit state with outbound
  delivery so a known-down edge does not create avoidable ambiguity, and add a
  typed reconciliation/acknowledgement lifecycle for durable terminal debt.
