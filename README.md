# max

A QQ group-chat agent in Haskell. Talks to QQ via [NapCatQQ](https://napneko.github.io/) over the OneBot 11 reverse-WebSocket protocol, and to any OpenAI-compatible LLM (DeepSeek by default) for replies.

## What it does today

- Persists every group message (segments, rendered text, sender, reply-to) to Postgres.
- Stores images content-addressed by sha256 under `var/images/`; an N-worker pool fetches in parallel.
- Expands forwarded-message chains in-process from NapCat's inline `data.content`.
- When `@`-mentioned with anything other than `ping`, spawns an async LLM call that sees the last N group messages plus the quoted reply chain, then posts the response with `@user` + a 引用 of the triggering message.
- `@bot ping` still returns `pong` as a fast path with no LLM hop.

## Layout

```
flake.nix          devenv 2.0 shell (GHC 9.12, Postgres 17 + pgvector, tooling)
devenv.nix         service definitions + .env sourcing on shell entry
docker-compose.yml NapCat container (separate from devenv on purpose)
max.cabal          library + max-bot executable
migrations/*.sql   schema migrations, applied on boot

src/OneBot/        OneBot 11 wire protocol: types, segments, events, actions, server
src/Max/Effects/   domain effects over effectful 2.5: Http, Blob, NapCat, LLM
                   (the DB effect comes from upstream effectful-postgresql)
src/Max/DB/        postgresql-simple queries: Connection, Migrations, Message,
                   Forward, History
src/Max/           Config (CLI/env/TOML), Forward worker, Image worker pool,
                   Handler, Prompt
app/Main.hs        wires effects + workers + server
```

## Configuration

Three layered sources, first-Just wins per field:

1. **CLI flags** — `max-bot --llm-model deepseek-reasoner --persona "..."`. `--help` lists everything.
2. **Environment** — `MAX_LLM_API_KEY`, `MAX_DB_URL`, `MAX_PERSONA`, … Devenv sources `.env` on shell entry.
3. **TOML file** — `--config PATH`, or `MAX_CONFIG`, or `./max.toml`, or `$XDG_CONFIG_HOME/max/config.toml`.

The only required value is `llm.api_key`; everything else has a default. See `.env.example` and `max.toml.example` for the full schema.

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
```

Non-secret bits (persona, history window, model) are easier to keep in `max.toml` — copy `max.toml.example` and uncomment.

### 3. Bring up Postgres

```sh
devenv up        # foreground; Postgres on 127.0.0.1:5433, db `max`, vector extension on
```

### 4. Bring up NapCat and log in

`docker-compose.yml` works as-is with either Docker Desktop or **OrbStack** (recommended on mac — faster, lighter, multi-arch image works natively on Apple Silicon).

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
@bot ping        → pong       (fast path; no LLM call)
@bot 你好         → LLM reply  (DeepSeek; watch `max/llm` domain in logs)
```

Reply-to a previous message and `@bot ...` to give the model the quoted context as well.

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
       │   4. classify @bot                                              │
       │        TriggerNone → drop                                       │
       │        TriggerPong → send pong                                  │
       │        TriggerLLM  → async dispatchLLM                          │
       └──────────────┬─────────────┬──────────────┬─────────────────────┘
                      │             │              │
              ┌───────▼────┐  ┌─────▼─────┐  ┌─────▼────────────────┐
              │imageWorker │  │forwardWkr │  │ LLM dispatch         │
              │N parallel  │  │ in-proc   │  │ buildContext (system │
              │HTTP fetch  │  │ recursion │  │ + persona + history  │
              │+ blob/db   │  │ on inline │  │ + reply chain)       │
              │            │  │ children  │  │ → chat → send reply  │
              └────────────┘  └───────────┘  └──────────────────────┘
```

Effect stack at the top of `runApp`:
`IOE → Concurrent → Log → Http → Blob → WithConnection → NapCat → LLM`.

## Phase status

| Phase | What | Status |
|---|---|---|
| 1 | ping/pong over OneBot 11 | ✅ |
| 2 | Reverse-WS reconnect + supervision | ✅ |
| 3 | Postgres schema, message/image/forward persistence | ✅ |
| 4 | RAG via pgvector | deferred (revisit after Phase 6) |
| 5a | `effectful` effect layering | ✅ |
| 5b | LLM client, `@bot` trigger, async dispatch, persona config | ✅ |
| 6 | Tool calling + agent loop | **next** |
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

Image blobs: `var/images/<2hex>/<sha256>` (gitignored).

Bot logs are JSON on stdout with a `domain` field — useful filters: `max/conn-N`, `max/image-worker`, `max/forward-worker`, `max/llm`.
