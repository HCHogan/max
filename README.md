# max

A chat bot written in Haskell, for QQ group chats and one-on-one private chats.
It connects to QQ through [NapCatQQ](https://napneko.github.io/) (OneBot 11 over
reverse WebSocket) and calls any OpenAI-compatible or Anthropic-native endpoint
for the replies.

## Features

- **Agent loop** — multi-turn tool calling with cancellation (`!kill`), mid-task notes, progress messages, and reaction-based status on the trigger message.
- **Persistence** — every message in Postgres; images and videos content-addressed on disk; forwarded chats expanded.
- **Memory** — per-group and per-user memories injected into the prompt, curated by the model and a post-reply extractor.
- **Multimodal** — inline images, video, and avatars for capable profiles; unrelated history images loaded on demand.
- **Tools** — web search, code sandbox (per-group Docker workspace), files, message search, browser (camoufox over MCP), bilibili, pins, poke.
- **Proactive triggering** (optional) — a cheap intent classifier can start a turn on unaddressed group chatter.
- **Vector search** (optional) — pgvector-backed semantic search over messages and memories.
- **Multiple LLM profiles**, OpenAI-compatible or Anthropic-native, switched at runtime with `!model`.
- **Commands** — `!help`, `!model`, `!persona`, `!proactive`, `!memory`, `!clear`, `!pin`, `!btw`, `!kill`, `!version`, …
- `@bot ping` → `pong`, no LLM call.

Full behaviour reference in [docs/features.md](docs/features.md).

## Configuration

Three layered sources, first-Just wins per field:

1. **CLI flags** — `max-bot --help` lists everything.
2. **Environment** — `MAX_LLM_API_KEY`, `MAX_DB_URL`, `MAX_PERSONA`, … Devenv sources `.env` on shell entry.
3. **YAML file** — `--config-file PATH`, or `MAX_CONFIG`, or `./max.yaml`, or `$XDG_CONFIG_HOME/max/config.yaml`.

The only required value is one LLM `api_key`. Feature sections (`search`,
`memory`, `embedding`, `intent`, …) are off when absent. See `.env.example` and
`max.yaml.example` for the full schema.

## First-time setup

```sh
# 1. Enter the dev shell (--impure: devenv as a flake module)
direnv allow            # or: nix develop --impure

# 2. Configure secrets
cp .env.example .env    # NAPCAT_QQ, MAX_ACCESS_TOKEN, MAX_LLM_API_KEY
cp max.yaml.example max.yaml   # persona, profiles, memory/embedding sections

# 3. Bring up Postgres (127.0.0.1:5433, db `max`, pgvector + pg_trgm)
devenv up

# 4. Bring up NapCat and log in
docker compose up -d napcat
```

For NapCat, open <http://localhost:6099> and scan the QR with the bot account's
mobile QQ. Login state persists to `./.napcat/`; the reverse-WS target
`ws://host.docker.internal:8080/onebot` is preconfigured. Private chat only works
with the bot account's QQ friends — that's QQ's rule.

```sh
# 5. Build the tool images (optional but recommended)
sandbox-image/build.sh    # code-execution sandbox
browser-image/build.sh    # browser (multimodal profiles only)

# 6. Run the bot — migrations apply on boot, embed worker backfills automatically
cabal run max-bot
```

Test in QQ:

```
@bot ping               → pong       (fast path; no LLM call)
@bot 你好                → LLM reply
@bot !help              → list of !cmd verbs
@bot !model list        → available LLM profiles
@bot !memory            → what the bot remembers here
```

Reply-to a message and `@bot ...` to hand the model the quoted context —
including an expanded 转发聊天记录, attached-file ids, and (multimodal) the quoted
message's images.

## Docs

- [docs/features.md](docs/features.md) — full behaviour reference
- [docs/architecture.md](docs/architecture.md) — layout, data flow, effect stack, phase status
- [docs/development.md](docs/development.md) — tests, versioning, debugging
- [docs/prompt-flow.md](docs/prompt-flow.md) — the complete JSON of a real dispatch

## Tests

```sh
cabal test max-test        # in-memory: pure logic
cabal test max-test-db     # DB integration; needs MAX_TEST_DB_URL
```

Details in [docs/development.md](docs/development.md).
