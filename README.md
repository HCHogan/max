# max

A QQ group-chat agent in Haskell. Talks to QQ via [NapCatQQ](https://napneko.github.io/) over the OneBot 11 reverse-WebSocket protocol, and to any OpenAI-compatible or Anthropic-native LLM endpoint (DeepSeek by default) for replies.

## What it does today

- **Persistence**: every group message (segments, rendered text, sender, reply-to) → Postgres. Images stored content-addressed under `var/images/`; an N-worker pool fetches in parallel. Forwarded-message chains expanded in-process.
- **Trigger**: when `@`-mentioned, runs the message through a `!cmd` parser first; otherwise spawns an async agent turn that sees recent group context + the @-mention history + any pinned messages.
- **Agent loop**: multi-turn tool-call loop with cancellation, `!btw` side-channel injection, and per-task sandbox lifecycle.
- **Multi-profile LLM**: as many `[[llm.profiles]]` as you like, switch per-group at runtime with `!model <name>`. Profiles can be OpenAI-compatible or Anthropic-native (`protocol = "anthropic"`).
- **DeepSeek thinking mode**: per-session override via `!model think on/off`; `reasoning_content` round-trips through the agent loop so multi-turn tool use stays valid.
- **Tools** (registered conditionally on config):
  - `web_search` — Tavily (requires `tavily_api_key`)
  - File tools — `list_recent_files`, `import_file_to_sandbox`, `send_image_from_sandbox`, `send_file_from_sandbox`
  - Sandbox tools — persistent per-group Docker workspace for code execution
- **Commands**: `!help`, `!model [list|<name>|think [on|off]]`, `!persona`, `!clear [--all]`, `!unclear`, `!pin [id]`, `!unpin [id|all]`, `!pins`, `!btw <text>`, `!ps [--all]`, `!kill <id>`. Branch commands are stubs (Phase 6c).
- `@bot ping` returns `pong` as a fast path with no LLM hop.

## Layout

```
flake.nix          devenv 2.0 shell (GHC 9.12, Postgres 17 + pgvector, tooling)
devenv.nix         service definitions + .env sourcing on shell entry
docker-compose.yml NapCat container + sandbox-exec image; shared ./var/outbox volume
max.cabal          library + max-bot executable
migrations/*.sql   schema migrations, applied on boot

src/OneBot/        OneBot 11 wire protocol: types, segments, events, actions, server
src/Max/Effects/   effectful 2.5 effects: Http (lenient TLS), Blob, NapCat,
                   LLM (OpenAI + Anthropic), Tools, Agent
                   (DB effect comes from upstream effectful-postgresql)
src/Max/DB/        postgresql-simple queries: Connection, Migrations, Message,
                   Forward, History, Session, Files
src/Max/Command/   !cmd DSL: Types, Parser (megaparsec), Dispatcher
src/Max/Session/   Per-group session: in-memory TVar + DB persistence
src/Max/Sandbox/   Per-group Docker workspace lifecycle + registry
src/Max/Tools/     Tool implementations (Files, Sandbox, Search)
src/Max/           Config (CLI/env/TOML), Forward worker, Image worker pool,
                   Handler, Prompt, Tasks (registry + btw queue), Tools (registry)
app/Main.hs        wires effects + workers + server
```

## Configuration

Three layered sources, first-Just wins per field:

1. **CLI flags** — `max-bot --llm-model deepseek-v4-flash --persona "..."`. `--help` lists everything.
2. **Environment** — `MAX_LLM_API_KEY`, `MAX_DB_URL`, `MAX_PERSONA`, `MAX_TAVILY_API_KEY`, … Devenv sources `.env` on shell entry.
3. **TOML file** — `--config PATH`, or `MAX_CONFIG`, or `./max.toml`, or `$XDG_CONFIG_HOME/max/config.toml`.

The only required value is one LLM `api_key`; everything else has a default. See `.env.example` and `max.toml.example` for the full schema, including the `[[llm.profiles]]` array-of-tables format used for multi-model setups.

## First-time setup

### 1. Enter the dev shell

```sh
direnv allow            # or: nix develop --impure
```

First entry downloads GHC 9.12, HLS, Postgres 17 + pgvector, and a few CLIs (`websocat`, `jq`, `pgcli`).

### 2. Configure secrets

```sh
cp .env.example .env
# edit .env:
#   NAPCAT_QQ          QQ number of the small account NapCat logs in as
#   MAX_ACCESS_TOKEN   shared secret between NapCat and the bot (long random string)
#   MAX_LLM_API_KEY    e.g. a DeepSeek key from https://platform.deepseek.com
#   MAX_TAVILY_API_KEY (optional) enables the web_search tool
```

Non-secret bits (persona, history window, profile list) are easier to keep in `max.toml` — copy `max.toml.example` and uncomment.

### 3. Bring up Postgres

```sh
devenv up        # foreground; Postgres on 127.0.0.1:5433, db `max`, pgvector + pg_trgm on
```

### 4. Bring up NapCat and log in

`docker-compose.yml` works as-is with either Docker Desktop or **OrbStack** (recommended on mac — faster, lighter, multi-arch image works natively on Apple Silicon). It also mounts `./var/outbox` so the bot can hand off files for `send_file_from_sandbox` without re-uploading.

```sh
docker compose up -d napcat
```

Open <http://localhost:6099>, scan the QR from the small account's QQ mobile app. Login state persists to `./.napcat/` (gitignored). The reverse-WS target `ws://host.docker.internal:8080/onebot` is preconfigured via env vars.

### 5. Run the bot

```sh
cabal run max-bot
```

Migrations apply on boot. You should see `max-bot starting`, the worker pool start lines, and `websocket connected` once NapCat hooks up.

### 6. Test in QQ

```
@bot ping               → pong       (fast path; no LLM call)
@bot 你好                → LLM reply  (DeepSeek; watch `max/llm` domain in logs)
@bot !help              → list of !cmd verbs
@bot !model list        → available LLM profiles
@bot !model think on    → flip this session into thinking mode (DeepSeek)
```

Reply-to a previous message and `@bot ...` to give the model the quoted context as well. `!pin` / `!unpin` operate on the replied-to message when used without an id.

## Architecture

```
                                                ┌──────────────────┐
                  NapCat ────reverse-WS────────▶│ OneBot.Server    │
                         ◀──send_group_msg─────│ event queue       │
                                                └────────┬─────────┘
                                                         │
                                                         ▼
       ┌──────────────────────── handleEvents ──────────────────────────┐
       │ EvGroupMessage gm  →                                            │
       │   1. insertGroupMessage   (Postgres, idempotent on message_id)  │
       │   2. enqueueImages        → ImageQueue                          │
       │   3. enqueueForwards      → ForwardQueue                        │
       │   4. classify @bot →                                            │
       │        none / ping / !cmd / agent-turn                          │
       └──────┬──────────┬──────────┬──────────────┬─────────────────────┘
              │          │          │              │
        ┌─────▼────┐ ┌───▼────┐ ┌───▼─────┐ ┌──────▼─────────────────┐
        │imageWkr  │ │fwdWkr  │ │!cmd     │ │ agentTurn (async task) │
        │N parallel│ │in-proc │ │dispatch │ │  buildContext           │
        │HTTP fetch│ │recurse │ │(session,│ │  → LLM (tools)          │
        │+ blob/db │ │on data │ │ tasks,  │ │    └─ tool loop ◀──┐    │
        │          │ │.content│ │ sandbox)│ │       (sandbox /   │    │
        └──────────┘ └────────┘ └─────────┘ │        files /     │    │
                                            │        search)─────┘    │
                                            │  → send + persist reply │
                                            └─────────────────────────┘
```

Effect stack at the top of `runApp`:
`IOE → Concurrent → Log → Http → Blob → WithConnection → NapCat → Tools → LLM → Agent`.

## Phase status

| Phase | What | Status |
|---|---|---|
| 1 | ping/pong over OneBot 11 | ✅ |
| 2 | Reverse-WS reconnect + supervision | ✅ |
| 3 | Postgres schema, message/image/forward persistence | ✅ |
| 4 | RAG via pgvector | deferred (revisit after Phase 6) |
| 5a | `effectful` effect layering | ✅ |
| 5b | LLM client, `@bot` trigger, async dispatch, persona config | ✅ |
| 6a | `!cmd` DSL, per-group session, multi-profile LLM, watermark/pin | ✅ |
| 6b | Tool calling + agent loop + sandbox + files + search | ✅ |
| 6c | Branch / switch over the messages table | next |
| 7 | Multimodal (VL on stored images) | later |
| 8 | NixOS module + production deployment | later |

## Debugging

Raw NapCat traffic, no bot needed:

```sh
websocat -s 8080
# trigger a message; NapCat prints raw event JSON.  Pipe through `jq .`.
```

Database:

```sh
pgcli "postgresql://127.0.0.1:5433/max"
```

Image blobs: `var/images/<2hex>/<sha256>` (gitignored). Sandbox workspaces: per-group Docker containers, destroyed on `!clear --all` or bot shutdown. Outbox staging for `send_file_from_sandbox`: `var/outbox/` (shared with NapCat container).

Bot logs are JSON on stdout with a `domain` field — useful filters: `max/conn-N`, `max/image-worker`, `max/forward-worker`, `max/llm`, `max/agent`, `max/tools`, `max/sandbox`, `max/session`.
