# Architecture

Cross-cutting decisions for the context/memory redesign are recorded in
[`ADR 001: Context and Memory Foundations`](adr/001-context-memory-foundations.md).

Layout, runtime data flow, effect stack, and phase status. For behaviour see
[features.md](features.md); for tests and debugging see
[development.md](development.md).

## Layout

```
flake.nix          devenv shell as a flake module (GHC 9.10, Postgres 17 + pgvector)
devenv.nix         service definitions + .env sourcing on shell entry
docker-compose.yml NapCat container; shared ./var/outbox volume
sandbox-image/     nix-enabled sandbox base image  → max-sandbox:latest
browser-image/     camoufox-mcp + supergateway + camoufox → max-browser:latest
nix/module.nix     NixOS module for production deployment
.github/workflows/ CI: build + max-test through the flake dev shell, plus a pure
                   `nix build .#max` so the packaged build can't rot
max.cabal          library + max executable
migrations/*.sql   schema migrations, applied on boot
skills/*.md        builtin skill manuals, baked into the binary (file-embed);
                   first line = index description, body behind use_skill

src/OneBot/        OneBot 11 wire protocol: types (incl. private-chat pseudo-groups),
                   segments, events, actions, server
src/Max/Effects/   effectful 2.5 effects: Http, Blob, PlatformApi, Outbound (visible send
                   + persistence), LLM (OpenAI + Anthropic, buffered or streamed),
                   Tools, ToolOutput (turn-scoped tool media), Agent
                   (DB effect from upstream effectful-postgresql)
src/Max/LLM/       Stream: SSE framing + the two protocols' delta reducers, pure
src/Max/Http/      Json: bounded buffered POST + domain retries; Stream: SSE folding;
                   both execute through the process-wide HttpRuntime pools
src/Max/HttpRuntime process-wide http-client managers, bounded response scopes,
                    and typed transport failures
src/Max/DB/        postgresql-simple queries: Connection, Migrations, Message, Forward,
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
                   Skills — use_skill, the progressive-disclosure reader)
src/Max/           Config (opt-env-conf), Env (BotEnv Reader), Prompt, Handler,
                   AgentEvent (typed progress/debug/final-stream port and its
                   ReplySend/Outbound interpreter),
                   ToolContext (neutral per-turn identity/capabilities),
                   Toolset (the full tool list, assembled from BotEnv), Intent
                   (proactive classifier), Skills (write-through registry:
                   builtins baked from skills/ + docs/, DB rows shadowing them),
                   EpisodeScheduler (protected quiet-tail timing), Historian +
                   EpisodeStore (durable exact-range P1/P2/P3 capture and scoped
                   memory proposals), Prompt context pipeline (feature-gated
                   compartment generations + token-sized raw tail),
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
                                                ┌──────────────────┐
                  NapCat ────reverse-WS────────▶│ OneBot.Server    │
                         ◀─send_{group,private}─│ event queue      │
                                                └────────┬─────────┘
                                                         │
                                                         ▼
       ┌──────────────────────── handleEvents ───────────────────────────┐
       │ EvGroupMessage gm (group, or private as pseudo-group)  →        │
       │   1. bump episode quiet boundary; insertGroupMessage (Postgres) │
       │   2. enqueueImages / enqueueForwards / enqueueFiles → fetch_jobs│
       │   3. classify (@bot / reply-to-bot / private / !cmd) →          │
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
                                            │  → arm episode idle timer│
                                            └─────────────────────────┘

Historian v2 is episode-scoped rather than per-dispatch. After ten quiet
minutes it selects an oldest-first raw-ledger prefix by the configured model's
token budget (SQL pages are only an implementation detail), then persists an
exact source range/hash as a leased capture job. One structured LLM call emits
P1/P2/P3 chronological summaries plus scoped memory proposals. Publication
atomically validates citations and scope, writes the compartment and proposal
outcomes, applies accepted MemoryStore mutations, and CAS-advances the
historian cursor. A failure advances nothing; restart reclaims the durable job.
Commands/synthetic/forward rows remain in range coverage before transcript
filtering, and active ranges have a database non-overlap constraint. The legacy
deployment boundary can be backfilled explicitly without rewinding the live
cursor. A nightly dream pass (4am local) remains a separate semantic-memory
maintenance lifecycle.

Prompt reads are cut over per conversation with
`unbounded_context_groups`. A canaried conversation takes the newest active
compartment suffix that has no uncovered raw rows, then reads every
prompt-eligible message after the suffix's exact end cursor. Partial older
backfills stay out of the stable prefix when a raw gap separates them. The pure
ContextPolicy assigns P1/P2/P3/P4 using coarse age, episode distance,
importance, confidence, and token pressure; P4 remains stored but is omitted
from the default prompt. Under pressure active memory is removed first,
compartments degrade one tier at a time, and only then is the oldest raw tail
trimmed. A conversation with no active compartment automatically uses the
legacy reader, and removing it from the allowlist rolls back prompt reads
without changing raw messages, capture jobs, or projections.
```

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
| Reminders | `reminders` table; the scheduler handle is only a wakeup bell |
| Embeddings, captions | workers poll for `NULL` columns, so any gap backfills itself |

| Lost on restart | Why |
|---|---|
| In-flight agent turns | ephemeral by design (`Max.Tasks`). SIGTERM drains them first — `shutdown_drain_seconds`, default 120 — but a crash, or a drain that times out, abandons them |
| Triggers arriving mid-drain | persisted to `messages` and logged, but not dispatched |
| Anything NapCat sends while we're down | it dials in over reverse-WS and doesn't buffer; closing this needs history backfill on reconnect |
| `!use` admin targets | deliberate — just `!use` again |
| Sandbox / browser containers | destroyed on exit, reaped on boot |

Effect stack at the top of `runApp`:
`IOE → Concurrent → Log → Http → Blob → WithConnection → PlatformApi → Outbound → LLM → Reader ModelCatalog → Reader BotEnv → Agent`.

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
              ├─ Embedding ─────── bounded OpenAI-compatible JSON POST
              ├─ MCP.Client ────── bounded browser MCP JSON/SSE response
              └─ Wechatpad ─────── bounded outbound relay POST
```

The runtime boundary owns request execution, connection reuse, response-body
lifetime, body/diagnostic limits, and transport classification. Protocol
decoding and retry decisions stay with callers. In particular, the primitive
never silently replays a request; buffered LLM calls retry from
`Max.Http.Json`, while `Max.Http.Stream` retries only before text or tool-call
output becomes observable.

The OneBot reverse WebSocket, WeChatPad inbound WebSocket, and browser page
traffic inside the camoufox container are not outbound HTTP clients and remain
outside this runtime. Future Matrix/Telegram HTTP adapters should use
`StandardPool`; any long-lived WebSocket transport remains a platform-edge
resource.

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

`Outbound` owns the send-response-persist invariant: a visible message is sent
through the platform router, its assigned `message_id` is extracted, and the
exact surface segments are recorded.  A result distinguishes rejection from
delivery without a durable row, so callers never retry something the user may
already have seen.

`Agent` depends on `LLM`, scoped `Tools`, task/concurrency primitives, logging,
and its typed `AgentEventSink`; it has no OneBot segment, `Outbound`, or message
persistence dependency.  The production sink is assembled per dispatch in
`Handler`, where reply target, debug policy, and the shared stream budget are
known.

Each `AgentTurn` adds two narrower scopes inside the process stack:

```
Handler
  └─ AgentContext (ToolContext + LLM effort)
       └─ Agent
            ├─ runTools (allToolsFor ToolContext)
            │    └─ concrete tool ──queueInlineMedia──▶ ToolOutput
            └─ drainInlineMedia ──▶ next LLM tool round
```

`ToolContext` contains only turn identity and capability gates, so concrete
tools do not import `Agent`. `ToolOutput` owns a fresh media queue per turn;
draining a round clears queued media but preserves the turn-wide attachment
counter. This prevents concurrent turns from sharing output state and keeps
mutable queue mechanics out of context records. Capability reporting uses a
pure gate projection rather than constructing tools with dummy ids.

Workers are started as one flat list (`withLinkedWorkers` in `app/Main.hs`),
each `link`ed so a worker dying silently takes the process down rather than
leaving a stuck queue behind. An optional worker is an action that does nothing
when its config is absent — the async finishes immediately and linking a
finished async is a no-op, so "feature off" needs no special case.

## Phase status

| Phase | What | Status |
|---|---|---|
| 1–3 | OneBot 11 transport, supervision, persistence (messages/images/forwards) | ✅ |
| 4 | Vector retrieval via pgvector (semantic search_messages, memory_search) | ✅ |
| 5 | effectful layering, LLM client, async dispatch | ✅ |
| 6 | !cmd DSL, sessions, agent loop, sandbox/files/search tools | ✅ |
| 7 | Multimodal (inline context images) + browser toolset | ✅ |
| 8 | Long-term memory (tools + extraction + injection) | ✅ |
| 9 | Private chats (pseudo-group pipeline) | ✅ |
| 10 | NixOS module + production deployment | ✅ |
| 11 | Admin JSON API + panel | ✅ |
| 12 | Skills (progressive disclosure) + episode memory extraction | ✅ |
| 13 | Token-planned infinite context + unified Historian/memory lifecycle | 🚧 |
