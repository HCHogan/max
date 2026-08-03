<div align="center">

# max 🦈

**A group-chat agent, done right.**

[![CI](https://github.com/HCHogan/max/actions/workflows/ci.yml/badge.svg)](https://github.com/HCHogan/max/actions/workflows/ci.yml)
[![GHC](https://img.shields.io/badge/GHC-9.10-5e5086.svg)](https://www.haskell.org/ghc/)
[![Nix](https://img.shields.io/badge/Nix-flake-5277C3.svg?logo=nixos&logoColor=white)](flake.nix)
[![Postgres](https://img.shields.io/badge/Postgres-17%20+%20pgvector-4169E1.svg?logo=postgresql&logoColor=white)](devenv.nix)
[![License](https://img.shields.io/badge/license-MIT-000000.svg)](LICENSE)

</div>

Max connects to QQ through [NapCatQQ](https://napneko.github.io/) and supports
OpenAI-compatible, OpenAI Responses, and Anthropic-native model endpoints.

```text
QQ ──▶ NapCat ──OneBot 11──▶ Max ──▶ LLM
                              ├──▶ PostgreSQL + pgvector
                              └──▶ sandbox, browser, files and media
```

## Highlights

- Token-planned long-term context with rebuildable episode summaries and a
  protected recent transcript.
- Conversation-scoped memory and unified recall across memories, episodes, raw
  messages, pins, and media captions.
- Concurrent agent turns, tool calling, streaming replies, cancellation, and
  mid-turn feedback.
- Multimodal input, persistent per-group sandboxes, browser automation, files,
  skills, reminders, and proactive participation.
- Durable messages, media jobs, context projections, and maintenance work.
- Exact self-inspection against an allowlisted source snapshot embedded in the
  running binary.
- Multiple model profiles plus an authenticated local admin panel.

See [features.md](docs/features.md) for the full behaviour reference.

## Quick start

```sh
direnv allow                         # or: nix develop --impure
cp .env.example .env
cp max.yaml.example max.yaml
devenv up                            # PostgreSQL on 127.0.0.1:5433
docker compose up -d napcat
cabal run max
```

Open <http://localhost:6099> to log the bot account into QQ. Database migrations
and derived-data backfills run automatically. Build `sandbox-image/` and
`browser-image/` only when those tools are needed.

Configuration is layered as CLI flags, environment variables, then YAML. One
LLM API key is the only required value; optional feature sections stay disabled
when absent. See [`.env.example`](.env.example) and
[`max.yaml.example`](max.yaml.example).

## Development

```sh
cabal test max-test
MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test cabal test max-test-db
cabal build all
```

| Document | Contents |
|---|---|
| [features.md](docs/features.md) | behaviour and configuration semantics |
| [architecture.md](docs/architecture.md) | runtime, context/memory design, and durability |
| [ADR 001](docs/adr/001-context-memory-foundations.md) | context/memory invariants and privacy boundaries |
| [development.md](docs/development.md) | tests, evaluation, versioning, and debugging |
| [prompt-flow.md](docs/prompt-flow.md) | generated prompt and tool-round wire examples |

## License

[MIT](LICENSE) © Hank Hogan
