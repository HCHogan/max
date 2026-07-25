# Architecture

Layout, runtime data flow, effect stack, and phase status. For behaviour see
[features.md](features.md); for tests and debugging see
[development.md](development.md).

## Layout

```
flake.nix          devenv shell as a flake module (GHC 9.12, Postgres 17 + pgvector)
devenv.nix         service definitions + .env sourcing on shell entry
docker-compose.yml NapCat container; shared ./var/outbox volume
sandbox-image/     nix-enabled sandbox base image  → max-sandbox:latest
browser-image/     camoufox-mcp + supergateway + camoufox → max-browser:latest
nix/module.nix     NixOS module for production deployment
.github/workflows/ CI: build + max-test through the flake dev shell
max.cabal          library + max-bot executable
migrations/*.sql   schema migrations, applied on boot

src/OneBot/        OneBot 11 wire protocol: types (incl. private-chat pseudo-groups),
                   segments, events, actions, server
src/Max/Effects/   effectful 2.5 effects: Http, Blob, NapCat, LLM (OpenAI + Anthropic),
                   Tools, Agent  (DB effect from upstream effectful-postgresql)
src/Max/DB/        postgresql-simple queries: Connection, Migrations, Message, Forward,
                   History, Session, Files, Memory
src/Max/Command/   !cmd DSL: Types, Parser (megaparsec), Dispatcher
src/Max/Session/   Per-conversation session: in-memory TVar + DB persistence
src/Max/Sandbox/   Per-group Docker workspace lifecycle + registry
src/Max/Browser/   Per-group camoufox-MCP container lifecycle + registry
src/Max/MCP/       Minimal MCP client (Streamable HTTP)
src/Max/Tools/     Tool implementations (Files, Sandbox, Search, Browser, Memory)
src/Max/           Config (opt-env-conf), Env (BotEnv Reader), Prompt, Handler,
                   MemoryExtract, Embedding + Embedder (vector worker), Forward/Image/File
                   workers, Shutdown (graceful drain), Tasks, Tools, Util
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
       │   1. insertGroupMessage   (Postgres, idempotent on message_id)  │
       │   2. enqueueImages / enqueueForwards / enqueueFiles             │
       │   3. classify (@bot / reply-to-bot / private / !cmd) →          │
       │        none / ping / !cmd / agent-turn                          │
       └──────┬──────────┬──────────┬──────────────┬─────────────────────┘
              │          │          │              │
        ┌─────▼────┐ ┌───▼────┐ ┌───▼─────┐ ┌──────▼──────────────────┐
        │img/fwd/  │ │embedWkr│ │!cmd     │ │ agentTurn (async task)  │
        │file wkrs │ │pgvector│ │dispatch │ │  buildContext (+memory) │
        │          │ │backfill│ │(session,│ │  → LLM (tools)          │
        │          │ │+ tail  │ │ memory, │ │    └─ tool loop ◀──┐    │
        └──────────┘ └────────┘ │ tasks)  │ │  (sandbox/browser/ │    │
                                └─────────┘ │   search/files/mem)┘    │
                                            │  → send chunks + persist│
                                            │  → memory extraction    │
                                            └─────────────────────────┘
```

## Durability

What a restart keeps and what it drops. Postgres is authoritative throughout;
the in-memory handles are read caches and wakeup bells, never the record.

| Survives a restart | How |
|---|---|
| Messages, sessions, memories, stickers, permissions | written through on every mutation |
| Reminders | `reminders` table; the scheduler handle is only a wakeup bell |
| Embeddings, captions | workers poll for `NULL` columns, so any gap backfills itself |

| Lost on restart | Why |
|---|---|
| In-flight agent turns | ephemeral by design (`Max.Tasks`). SIGTERM drains them first — `shutdown_drain_seconds`, default 120 — but a crash, or a drain that times out, abandons them |
| Queued image / video / forward / file fetches | in-memory `TQueue`s, and nothing ever goes back for them |
| Triggers arriving mid-drain | persisted to `messages` and logged, but not dispatched |
| Anything NapCat sends while we're down | it dials in over reverse-WS and doesn't buffer; closing this needs history backfill on reconnect |
| `!use` admin targets | deliberate — just `!use` again |
| Sandbox / browser containers | destroyed on exit, reaped on boot |

Effect stack at the top of `runApp`:
`IOE → Concurrent → Log → Http → Blob → WithConnection → NapCat → Wreq → LLM → Reader PersistMode → Reader BotEnv → Agent`.

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
| 10 | NixOS module + production deployment | module ready; deployment pending |
