<div align="center">

# max

**A QQ group-chat agent, written in Haskell.**

[![CI](https://github.com/HCHogan/max/actions/workflows/ci.yml/badge.svg)](https://github.com/HCHogan/max/actions/workflows/ci.yml)
[![GHC](https://img.shields.io/badge/GHC-9.10-5e5086.svg)](https://www.haskell.org/ghc/)
[![Nix](https://img.shields.io/badge/Nix-flake-5277C3.svg?logo=nixos&logoColor=white)](flake.nix)
[![Postgres](https://img.shields.io/badge/Postgres-17%20+%20pgvector-4169E1.svg?logo=postgresql&logoColor=white)](devenv.nix)
[![License](https://img.shields.io/badge/license-MIT-000000.svg)](LICENSE)

</div>

It talks to QQ through [NapCatQQ](https://napneko.github.io/) — OneBot 11 over a
reverse WebSocket — and calls any OpenAI-compatible or Anthropic-native endpoint
for the replies. Group chats and one-on-one private chats both go through the
same pipeline.

```
QQ ──▶ NapCat ──OneBot 11 / reverse-WS──▶ max ──▶ LLM (OpenAI-compatible · Anthropic)
                                           │
                                           ├──▶ Postgres · pgvector · blob store
                                           └──▶ Docker · per-group sandbox · browser
```

## Features

- **Agent loop** — multi-turn tool calling, with `!kill` to cancel, `!feedback`
  to steer a running turn, `!btw` to ask something else without disturbing it,
  and reaction-based status on the trigger message.
- **Persistence** — every message in Postgres, images and videos
  content-addressed on disk, forwarded chats expanded inline. Pending media
  downloads survive a restart, and SIGTERM lets in-flight turns finish first.
- **Memory** — per-group and per-user facts injected into the prompt, curated by
  the model and by a post-reply extractor.
- **Multimodal** — inline images, video and avatars on capable profiles;
  unrelated history images loaded on demand.
- **Tools** — web search, code sandbox (per-group Docker workspace), files,
  message search, browser (camoufox over MCP), bilibili, pins, poke.
- **Multiple LLM profiles** — OpenAI-compatible or Anthropic-native, switched at
  runtime with `!model`.
- **Commands** — `!help`, `!model`, `!persona`, `!proactive`, `!memory`,
  `!clear`, `!pin`, `!btw`, `!feedback`, `!kill`, `!version`, …
- *Optional:* **proactive triggering** (a cheap intent classifier can start a
  turn on unaddressed chatter) and **vector search** (pgvector-backed semantic
  search over messages and memories).

`@bot ping` → `pong`, no LLM call. Full behaviour reference in
[docs/features.md](docs/features.md).

## Quick start

```sh
# 1. Enter the dev shell (--impure: devenv as a flake module)
direnv allow                     # or: nix develop --impure

# 2. Configure secrets
cp .env.example .env             # NAPCAT_QQ, MAX_ACCESS_TOKEN, MAX_LLM_API_KEY
cp max.yaml.example max.yaml     # persona, profiles, memory/embedding sections

# 3. Bring up Postgres (127.0.0.1:5433, db `max`, pgvector + pg_trgm)
devenv up

# 4. Bring up NapCat and log in
docker compose up -d napcat
```

Open <http://localhost:6099> and scan the QR with the bot account's mobile QQ.
Login state persists to `./.napcat/`, and the reverse-WS target
`ws://host.docker.internal:8080/onebot` is preconfigured. Private chat only works
with the bot account's QQ friends — that's QQ's rule, not ours.

```sh
# 5. Build the tool images (optional, but most tools need them)
sandbox-image/build.sh           # code-execution sandbox
browser-image/build.sh           # browser (multimodal profiles only)

# 6. Run — migrations apply on boot, the embed worker backfills on its own
cabal run max
```

Then, in QQ:

```
@bot ping               → pong       (fast path, no LLM call)
@bot 你好                → LLM reply
@bot !help              → list of !cmd verbs
@bot !model list        → available LLM profiles
@bot !memory            → what the bot remembers here
```

Reply to a message and `@bot …` to hand the model the quoted context — including
an expanded 转发聊天记录, attached-file ids, and (on multimodal profiles) the
quoted message's images.

## Configuration

Three layered sources, first-Just wins per field:

1. **CLI flags** — `max --help` lists everything.
2. **Environment** — `MAX_LLM_API_KEY`, `MAX_DB_URL`, `MAX_PERSONA`, … Devenv
   sources `.env` on shell entry.
3. **YAML** — `--config-file PATH`, `MAX_CONFIG`, `./max.yaml`, or
   `$XDG_CONFIG_HOME/max/config.yaml`.

The only required value is one LLM `api_key`. Feature sections (`search`,
`memory`, `embedding`, `intent`, …) stay off when absent. See
[`.env.example`](.env.example) and [`max.yaml.example`](max.yaml.example) for the
full schema.

## Tests

```sh
cabal test max-test        # in-memory: pure logic
cabal test max-test-db     # DB integration; needs MAX_TEST_DB_URL
```

## Docs

| | |
|---|---|
| [features.md](docs/features.md) | full behaviour reference |
| [architecture.md](docs/architecture.md) | layout, data flow, durability, effect stack |
| [development.md](docs/development.md) | tests, versioning, debugging |
| [prompt-flow.md](docs/prompt-flow.md) | the complete JSON of a real dispatch |

## License

[MIT](LICENSE) © Hank Hogan
