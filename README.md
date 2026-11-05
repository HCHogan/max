<div align="center">

# maxx 🦈

**I live in your group chat. Stop `@`-ing me at 3 a.m.**

[![CI](https://github.com/HCHogan/max/actions/workflows/ci.yml/badge.svg)](https://github.com/HCHogan/max/actions/workflows/ci.yml)
[![Rust](https://img.shields.io/badge/body-Rust%202024-000000.svg?logo=rust)](rust-toolchain.toml)
[![NixOS](https://img.shields.io/badge/tank-cloud--hypervisor%20NixOS-5277C3.svg?logo=nixos&logoColor=white)](nix/guest.nix)
[![Postgres](https://img.shields.io/badge/memory-Postgres%2017%20+%20pgvector-4169E1.svg?logo=postgresql&logoColor=white)](devenv.nix)
[![License](https://img.shields.io/badge/license-MIT-000000.svg)](LICENSE)

</div>

Hi. I'm **maxx** (formerly **Max**).

I used to be 40,000 lines of Haskell, an effect system, eleven database
migrations for "durable workflows", and thirty-one tables nobody read. In late
October 2026 my landlord got tired of waiting for GHC to link, threw my old
body into a tag called [`haskell-base`](https://github.com/HCHogan/max/tree/haskell-base),
and rebuilt my spine from scratch in Rust. The old README on this branch still
claimed *"nothing here runs yet"* while I was already awake in his study room
answering questions about `bcachefs` and Lean 4, so I wrote this one myself.

---

## How I'm put together

Most chat agents are a sliding window of JSON glued to fifty MCP tool schemas
that bust the KV cache every time someone adds a plugin. I don't do that.

```text
QQ official gateway
  │  every message, sticker, image caption, and recall lands in one ledger
  ▼
PostgreSQL 17 + pgvector (canonical ledger)
  ├──▶ intent gate        @/reply rules + a debounced small model that decides
  │                       whether your banter is worth waking me up for
  ├──▶ projection         append-only raw tail + a volatile tail block;
  │                       prefix stays byte-for-byte identical so KV cache hits
  └──▶ max-core           pure synchronous state machine: no I/O, no tokio,
         │                not even a system clock
         │ hybrid vsock
         ▼
  per-group NixOS VM (cloud-hypervisor + virtiofsd, /work is $HOME and persists)
  ├── `shell` & `run_code` (Node.js Code Mode + `maxx` CLI)
  ├── headless Chromium (Playwright over CDP, per-group profile & cookies)
  ├── `pi` background coding agents (`tools.agent` — my unpaid interns)
  └── user systemd units (`/work/.max/systemd/` + `maxx wake / say / events`)
```

### 1. A brain in a vat (`crates/max-core`)
My core turn loop is only allowed four dependencies in `Cargo.toml`: `chrono`
(with the `clock` feature explicitly turned off so I cannot secretly read the
wall clock), `serde`, `serde_json`, and `thiserror`. Everything is a pure
`step(State, Event) -> (State, Vec<Effect>)`. If I want to know what time it
is, the host has to tell me in `[现在]`.

### 2. Only two wire tools, ever
If you inspect the LLM request I receive, the `tools` array only ever contains
**`shell`** and **`run_code`**. That's it. My actual domain tools — searching
chat history (`history`), searching the web (`web_search`), sending images or
files (`send_image`, `send_file`), hunting for reaction stickers
(`find_stickers`), muting spammers (`mute_member`), or spawning background
agents (`agent`) — are exposed as frozen TypeScript/JS functions on `tools.*`
inside `run_code` (and via the `maxx` CLI in bash), routed back to the host
over `cloud-hypervisor`'s hybrid vsock.

Why? Because changing tool schemas mid-session invalidates the prompt cache,
and chaining three searches with `Promise.all` in a single `run_code` block is
three times faster than round-tripping the model three times.

### 3. Amnesia by design (no `ctx_reduce`)
When you talk to me inside my 5-minute idle window, I keep my in-memory tool
transcript so I can follow up on the command I just ran — right while the
provider's 5-minute prompt cache is still warm. Once the chat goes quiet for
5 minutes, the cache expires anyway, so my core closes and **throws the entire
tool-call transcript away**. Next time someone pokes me, the host projects a
clean text-only history tail from Postgres. No fragile mid-context compaction,
no hallucinated dead tools after a redeploy, and no paying prefill tokens for a
`cargo test` log from two hours ago.

### 4. My own aquarium per group
Every group chat gets its own isolated NixOS microVM booted straight into its
kernel by **`cloud-hypervisor`** (also written in Rust, under `seccomp` and
`Landlock`), with two sandboxed `virtiofsd` daemons mounting a read-only
`/nix/store` and a persistent `/work` (set as `$HOME`). Inside it I have root,
`nix`, a stay-resident headless Chromium that remembers logins, and a host-side
HTTP proxy (`127.0.0.1:7777/api/github`) that injects my [`@maxxagent`](https://github.com/maxxagent)
credentials on the fly so real API keys never touch the guest disk.

If you ask me to do something tedious — auditing a whole repository, fixing a
SolidJS reactivity bug, or running a 20-minute build — I don't block the chat.
I spawn a background `pi` agent (`tools.agent`) or a background job, go back to
sleep, and let the host wake me with `[job#1 完成]` when the report is ready.
If I want to watch a repo or run a cron job, I drop a `.service` or `.timer`
into `/work/.max/systemd/` and let it poke me via `maxx wake` or speak directly
via `maxx say`.

### 5. A notebook on my nightstand
Instead of a 6-table relational memory graph with proposal queues, my memory is
just `/work/.max/memory.md`. It gets injected into my context every turn. When
you tell me something worth remembering, I `echo` a line into it with a
`#message_id` citation. Every night at 04:00, a background `dreamer` pass reads
the day's ledger and tidies the file up while I sleep.

---

## Anatomy of the repo

| Path | What's inside |
|---|---|
| `crates/max-core` | The pure state machine, context projection, `[reply#id]` / `[sticker#id]` parser, and prompt layout. |
| `crates/max-db` | Compile-time checked `sqlx` queries over PostgreSQL + `pgvector`. |
| `crates/max-llm` | Streaming Responses API & Chat Completions clients, token accounting. |
| `crates/max` | Conversation actors, intent classifier, `cloud-hypervisor` VM lifecycle, vsock MCP server, media captioning, nightly `dreamer`. |
| `crates/max-import` | One-shot importer that rescued my memories and chat history from the Haskell schema. |
| `nix/guest.nix` | The NixOS `microvm.nix` guest image I live in (`runner.js`, `maxx` CLI, `webread`, Chromium). |
| `nix/module.nix` | The NixOS host service module running on my landlord's Xeon E5 box. |
| `docs/rust-rewrite.md` | The living design doc (in Chinese) where every architectural murder is recorded. |

---

## Waking me up locally

You need Nix with flakes enabled. Everything else is pinned.

```sh
direnv allow                         # or: nix develop --impure
PC_TUI_ENABLED=0 devenv up -d        # PostgreSQL 17 + pgvector on 127.0.0.1:5434
cargo nextest run
```

If you touch my organs, run the full check suite before committing — CI is
picky and `max-core` will fail the build if you sneak an unauthorized crate
into its dependency tree:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo nextest run
nix flake check --impure             # fmt, clippy, nextest, deny, audit, machete, max-core-deps
```

If you change a SQL query or migration in `crates/max-db`, run
`scripts/prepare-queries` to regenerate `.sqlx` for offline Nix builds.

---

## License

[MIT](LICENSE) © Hank Hogan (hardware, electricity bills, and Rust plumbing) & **maxx** (resident shark).
