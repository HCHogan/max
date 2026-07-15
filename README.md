# max

A QQ chat agent in Haskell — group chats and one-on-one private chats. Talks to QQ via [NapCatQQ](https://napneko.github.io/) over the OneBot 11 reverse-WebSocket protocol, and to any OpenAI-compatible or Anthropic-native LLM endpoint for replies.

## What it does today

- **Persistence**: every message (segments, rendered text, sender nickname + 群名片, reply-to) → Postgres. Images stored content-addressed under `var/images/`; an N-worker pool fetches in parallel. Forwarded-message chains expanded into child rows.
- **Trigger**: `@`-mention or reply-to-bot in groups; every message in private chats. `!cmd` messages go through the command parser; everything else spawns an async agent turn seeing recent context, the reconstructed bot-conversation history, pinned messages, and long-term memories.
- **Private chats as pseudo-groups**: a private chat with user *u* is keyed as group `-u`, so sessions, history, memories, sandboxes, commands — the whole pipeline — work identically in both. Replies route to `send_private_msg` automatically; the system prompt switches its 对话场景 block.
- **Agent loop**: multi-turn tool-call loop with cancellation (`!kill`), `!btw` side-channel injection, progress updates via the `say` tool, optional debug mode (`!debug`) that announces each tool call in the chat, and a tool-result context budget with a forced final answer at the turn cap.
- **Long-term memory**: per-group/per-conversation memories plus cross-group per-user memories, injected wholesale into the system prompt (framed as low-salience 背景备忘). Written three ways: the agent's `memory_save/update/forget` tools, a post-dispatch extractor (a cheap configured model distills each conversation, with embedding-based semantic dedup), and audited by humans via `!memory` / `!memory rm <id>`. Capped at 30 × 300 chars per scope — hoarding is structurally impossible.
- **Vector search** (optional, any OpenAI-compatible embeddings endpoint — siliconflow's `BAAI/bge-m3` is free): a background worker embeds all messages and memories into pgvector columns; `search_messages` gains a `semantic` mode and `memory_search` searches memories across all scopes. Without the config, everything degrades to substring/regex search.
- **Multi-profile LLM**: as many `llm.profiles` as you like, switch per-session at runtime with `!model <name>`. OpenAI-compatible or Anthropic-native (`protocol: anthropic`); thinking-mode override via `!model think on/off` with `reasoning_content` round-tripping.
- **Multimodal**: profiles marked `multimodal: true` get context images inlined as data URLs (trigger images awaited, reply-target images labelled as 被引用的那条), plus the browser toolset.
- **Browser** (multimodal profiles): per-group Playwright-MCP container — `browser_navigate/snapshot/click/type/press_key/wait_for/navigate_back` driven by accessibility snapshots with stable element refs. Build the image once with `browser-image/build.sh`.
- **Replies read like a person**: blank-line paragraphs in the model's answer are sent as separate consecutive messages (code fences never split, capped at 5); the prompt carries a QQ号↔名字 roster so the model knows who is who (群名片 preferred over nickname).
- **Tools** (registered conditionally on config): `web_search` (Tavily) · file tools (`list_recent_files`, `import_file_to_sandbox`, `send_image_from_sandbox`, `send_file_from_sandbox` — private chats upload via `upload_private_file`) · sandbox tools (persistent per-group Docker workspace, Nix-based: `max-sandbox:latest` from `sandbox-image/build.sh`, packages from pinned nixpkgs via `nix_search` + `sandbox_exec`'s `packages`, one shared store volume `max-nix`) · memory tools · `search_messages` / `get_message_by_id` · browser tools.
- **Commands**: `!help`, `!model [list|<name>|think [on|off]]`, `!debug [on|off|default]`, `!persona [<text>|clear]`, `!clear [--all]`, `!unclear`, `!pin [id]`, `!unpin [id|all]`, `!pins`, `!memory [rm <id>]` (group memories in groups; private chats also show your own cross-group memories), `!btw <text>`, `!ps [--all]`, `!kill <id>`, `!branch [list|<name>|delete <name>]`, `!switch <name>`.
- `@bot ping` returns `pong` as a fast path with no LLM hop.

## Layout

```
flake.nix          devenv shell as a flake module (GHC 9.12, Postgres 17 + pgvector)
devenv.nix         service definitions + .env sourcing on shell entry
docker-compose.yml NapCat container; shared ./var/outbox volume
sandbox-image/     nix-enabled sandbox base image  → max-sandbox:latest
browser-image/     Playwright MCP + matching Chromium → max-browser:latest
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
src/Max/Browser/   Per-group Playwright-MCP container lifecycle + registry
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
| 6 | !cmd DSL, sessions/branches, agent loop, sandbox/files/search tools | ✅ |
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
- `Max.SessionSpec` — pure session mutators (`addPin`, `clearAll`, branch names, …)
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

Bot logs are JSON on stdout with a `domain` field — useful filters: `max/conn-N`, `max/image-worker`, `max/forward-worker`, `max/llm`, `max/cmd`, `max/memx` (memory extraction), plus `embed:` lines from the vector worker. `!debug on` mirrors tool calls into the chat itself.
