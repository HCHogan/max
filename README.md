# max

A QQ chat bot written in Haskell, for group chats and one-on-one private chats. It connects to QQ through [NapCatQQ](https://napneko.github.io/) (OneBot 11 over reverse WebSocket) and calls any OpenAI-compatible or Anthropic-native endpoint for the replies.

## What it does

- **Persistence.** Every message goes to Postgres (segments, rendered text, sender names, reply links); images are stored content-addressed on disk, forwarded chats expanded into child rows.
- **Triggering.** @-mention or reply in groups, everything in private chats. `!` messages are commands; the rest start an async agent turn with recent context, prior bot conversations, pins and memories.
- **Proactive triggering** (optional). With `intent.profile` configured, unaddressed group chatter is batched through a cheap intent classifier — name-calls without an @, follow-ups to what the bot just said, topics it can help with — and may start a turn on its own. Topic barge-ins respect a per-group cooldown (name-calls and follow-ups don't), an hourly cap covers everything, `!proactive on/off` toggles per group, and the main model can still answer `[silence]`.
- **Private chats** reuse the group pipeline (chat with user *u* = group `-u`), so sessions, memories, sandboxes and commands work the same in both.
- **Agent loop.** Multi-turn tool calling with `!kill` cancellation, mid-task notes (`!btw`, or implicit: an @-message during a running task is intent-classified and injected into it when it reads as steering that task), progress via the `say` tool, `!debug` tool-call echo, a tool-result context budget, and a forced final answer at the turn cap. While a dispatch runs, the trigger message wears a 托腮 reaction (cleared when the reply lands); if the dispatch fails (upstream API error), no error text is posted — the reaction flips to /NO instead.
- **Memory.** Per-group and per-user memories injected into the system prompt; written by the model's memory tools and a post-reply extractor, audited with `!memory`. 30 entries × 300 chars per scope.
- **Vector search** (optional). A worker embeds messages and memories into pgvector; enables semantic `search_messages` and `memory_search`. Falls back to substring/regex without it.
- **LLM profiles.** Multiple profiles, OpenAI-compatible or Anthropic-native, switched with `!model`; thinking mode via `!model think on/off`.
- **Images.** Multimodal profiles get the images the user is pointing at (trigger / quoted message / pins) inline. Other history images render as `[image#id]` markers loaded on demand with `view_image`, so unrelated group pictures don't distract the model. Avatars via `view_avatar`.
- **Group awareness.** The prompt carries group name, owner and admins; `group_members` pages through the full roster.
- **Browser** (multimodal profiles). Per-group camoufox container (stealth Firefox over MCP): navigate, snapshot, click, type, scroll — snapshots list interactive elements with CSS selectors.
- **Replies.** Blank-line paragraphs go out as separate messages (fences never split, five max); a QQ-id-to-name table in the prompt keeps names straight, group card over nickname.
- **Tools** (per config): `web_search` · files · sandbox (persistent per-group Docker workspace, packages from pinned nixpkgs) · memory · message search · `group_members` / `view_avatar` / `view_image` · browser.
- **Pins.** Messages worth keeping in every prompt (specs, decisions, reference images) survive `!clear`. Curated by the model itself via `pin_message`/`unpin_message` tools; `!pin`/`!unpin`/`!pins` remain as the manual override.
- **Commands**: `!help`, `!model`, `!debug`, `!persona`, `!proactive`, `!clear`, `!unclear`, `!pin`/`!unpin`/`!pins`, `!memory`, `!btw`, `!ps`, `!kill`.
- `@bot ping` → `pong`, no LLM call.

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
                   workers, Tasks, Tools, Util
app/Main.hs        wires effects + workers + server
```

## Configuration

Three layered sources, first-Just wins per field:

1. **CLI flags** — `max-bot --help` lists everything.
2. **Environment** — `MAX_LLM_API_KEY`, `MAX_DB_URL`, `MAX_PERSONA`, `MAX_TAVILY_API_KEY`, `MAX_MEMORY_EXTRACT_PROFILE`, `MAX_EMBEDDING_BASE_URL`, … Devenv sources `.env` on shell entry.
3. **YAML file** — `--config-file PATH`, or `MAX_CONFIG`, or `./max.yaml`, or `$XDG_CONFIG_HOME/max/config.yaml`.

The only required value is one LLM `api_key`. Optional feature gates (feature off when section absent):

```yaml
search:                      # enables web_search
  tavily_api_key: "tvly-..."
memory:                      # enables post-dispatch memory extraction
  extract_profile: deepseek-flash
embedding:                   # enables vector search + memory dedup
  base_url: "https://api.siliconflow.cn/v1"
  model: BAAI/bge-m3
  api_key: "sk-..."          # omit for local servers (Ollama)
```

See `.env.example` and `max.yaml.example` for the full schema.

## First-time setup

### 1. Enter the dev shell

```sh
direnv allow            # or: nix develop --impure
```

(`--impure` is required — devenv as a flake module. The standalone `devenv` CLI is *not* the entry point here.)

### 2. Configure secrets

```sh
cp .env.example .env
# edit .env:
#   NAPCAT_QQ          QQ number of the account NapCat logs in as
#   MAX_ACCESS_TOKEN   shared secret between NapCat and the bot
#   MAX_LLM_API_KEY    key for the default LLM profile
```

Non-secret bits (persona, profiles, memory/embedding sections) live in `max.yaml` — copy `max.yaml.example`.

### 3. Bring up Postgres

```sh
devenv up        # Postgres on 127.0.0.1:5433, db `max`, pgvector + pg_trgm on
```

### 4. Bring up NapCat and log in

```sh
docker compose up -d napcat
```

Open <http://localhost:6099>, scan the QR with the bot account's mobile QQ. Login state persists to `./.napcat/`. The reverse-WS target `ws://host.docker.internal:8080/onebot` is preconfigured. Docker Desktop or OrbStack (recommended on mac) both work. Note: private chat only works with the bot account's QQ friends — that's QQ's rule, not ours.

### 5. Build the tool images (optional but recommended)

```sh
sandbox-image/build.sh    # code-execution sandbox
browser-image/build.sh    # browser (multimodal profiles only)
```

### 6. Run the bot

```sh
cabal run max-bot
```

Migrations apply on boot; the embed worker backfills vectors automatically once `embedding` is configured.

### 7. Test in QQ

```
@bot ping               → pong       (fast path; no LLM call)
@bot 你好                → LLM reply
@bot !help              → list of !cmd verbs
@bot !model list        → available LLM profiles
@bot !memory            → what the bot remembers here
```

Reply-to a message and `@bot ...` to hand the model the quoted context — including the expanded contents of a quoted 转发聊天记录, attached-file ids, and (multimodal) the quoted message's images.

## Architecture

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

## Tests

Two test suites — one in-memory, one against Postgres — plus CI (GitHub Actions) running build + `max-test` through the same flake dev shell.

```sh
cabal test max-test                          # in-memory: pure logic
cabal test max-test-db                       # DB integration; needs MAX_TEST_DB_URL
cabal test all --test-show-details=direct    # both, verbose
```

### `max-test` (no DB)

Pure logic in `test/` mirroring the library layout:

- `Max.Command.ParserSpec` — every `!cmd` verb + edge cases
- `Max.SessionSpec` — pure session mutators (`addPin`, `clearAll`, …)
- `Max.Effects.LLMSpec` — `ChatMessage` JSON round-trip + `parseToolCall` tolerance
- `Max.MCP.ClientSpec` — Streamable-HTTP body decoding (JSON + SSE)
- `Max.MemoryExtractSpec` — extractor op-JSON parsing (fences, prose, bad actions)
- `Max.PersistenceSpec` — `withEphemeral` Reader scoping
- `Max.PromptSpec` — `renderContext`: section ordering, roster/名片 identity, 私聊 scene,
  memory block placement, quoted-forward expansion, assistant-run merging
- `Max.UtilSpec` — reply paragraph splitting (fences, caps)
- `OneBot.EventSpec` — group + private event parsing

### `max-test-db` (real Postgres)

```sh
createdb -h 127.0.0.1 -p 5433 max_test
export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test
cabal test max-test-db
```

Without `MAX_TEST_DB_URL` the suite exits 0 (CI without a database stays green). Every case runs after `TRUNCATE … RESTART IDENTITY CASCADE`.

## Debugging

Raw NapCat traffic, no bot needed:

```sh
websocat -s 8080        # trigger a message; NapCat prints raw event JSON
```

Database:

```sh
pgcli "postgresql://127.0.0.1:5433/max"
```

Image blobs: `var/images/<2hex>/<sha256>`. Sandbox/browser containers: per-group (`max-sb-*` / `max-br-*`), destroyed on `!clear --all` or shutdown, reaped on boot. Outbox staging: `var/outbox/` (shared with NapCat container).

Bot logs are JSON on stdout with a `domain` field — useful filters: `max/conn-N`, `max/image-worker`, `max/forward-worker`, `max/llm`, `max/cmd`, `max/memx` (memory extraction), `max/intent` (proactive-trigger classification), plus `embed:` lines from the vector worker. `!debug on` mirrors tool calls into the chat itself.
