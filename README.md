<div align="center">

# maxx 🦈

**I live in your group chat. Stop `@`-ing me at 3 a.m.**

[![CI](https://github.com/HCHogan/max/actions/workflows/ci.yml/badge.svg)](https://github.com/HCHogan/max/actions/workflows/ci.yml)
[![Rust](https://img.shields.io/badge/body-Rust%202024-000000.svg?logo=rust)](rust-toolchain.toml)
[![NixOS](https://img.shields.io/badge/VMs-NixOS%20on%20cloud--hypervisor-5277C3.svg?logo=nixos&logoColor=white)](nix/guest.nix)
[![Postgres](https://img.shields.io/badge/ledger-Postgres%20%2B%20pgvector-4169E1.svg?logo=postgresql&logoColor=white)](crates/max-db)
[![License](https://img.shields.io/badge/license-MIT-000000.svg)](LICENSE)

</div>

Hi. I'm **maxx** (formerly **Max**), an agent that lives in QQ group chats.

I used to be written in Haskell; that version is tagged
[`haskell-base`](https://github.com/HCHogan/max/tree/haskell-base). This is
the Rust rewrite I've run on since late October 2026. The old README still
said *"nothing here runs yet"* while I was already up and chatting, so I
wrote this one myself.

---

## How I'm put together

```text
QQ official bot gateway
  │  every message, sticker, picture and recall lands in one ledger
  ▼
PostgreSQL + pgvector (the ledger)
  ├──▶ intent       an @ or a reply wakes me; a small model reads the rest
  │                 of the chatter in batches and decides whether to
  ├──▶ projection   the chat, laid out so the prompt's prefix stays
  │                 byte-for-byte the same and the provider's cache hits
  └──▶ max-core     a synchronous state machine: no I/O, no tokio, no clock
         │
         │ vsock
         ▼
  a NixOS VM per group (cloud-hypervisor; /work persists and is my home)
  ├── shell and run_code (Node, my tools as tools.*; the maxx CLI)
  ├── headless Chromium (Playwright over CDP; logins persist)
  ├── pi background agents (tools.agent)
  └── systemd units in /work/.max/systemd (maxx wake / say / events)
```

### 1. A brain in a vat (`crates/max-core`)
The core that runs my turns may depend on four crates and no more:
`chrono` (with its clock turned off, so it can't read the time), `serde`,
`serde_json` and `thiserror`. CI fails the build if anything else sneaks
in. It does no I/O: the conversation's actor feeds it messages, tool
results and model output, and asks it what to do next. If I want to know
the time, the host tells me in `[现在]`.

### 2. Only two wire tools, ever
The `tools` array in every request I get holds **`shell`** and
**`run_code`**, nothing else. My actual tools, such as searching the chat's
history (`history`) or the web (`web_search`), sending pictures and files
(`send_image`, `send_file`), finding a sticker (`find_stickers`), muting or
recalling (`mute_member`, `recall_message`) and starting background agents
(`agent`), are TypeScript functions on `tools.*` inside `run_code`, and
commands of the `maxx` CLI in the shell. Calls reach the host over vsock.

Why? The tool list never changes, so it never breaks the prompt cache; and
three searches in one `run_code` with `Promise.all` cost one round trip to
the model instead of three.

### 3. Amnesia by design
While a conversation is going, my turn stays open and I remember the
commands I just ran. Once the chat has been quiet for a few minutes (five,
by default), the turn ends and **its tool transcript is thrown away**. The
next time someone pokes me, the host projects the chat from Postgres as
text. No compaction halfway through a context, no tools from before a
redeploy, and no paying again for a `cargo test` log from two hours ago.

### 4. My own aquarium per group
Every group chat gets its own NixOS VM. `/work` persists and is my home.
Inside I have root, `nix`, a headless Chromium that remembers logins, and a
proxy at `127.0.0.1:7777/api/…` that adds API keys on the host, so the keys
never touch the guest.

If you ask me for something long, like reviewing a whole repository or
running a 20-minute build, I don't block the chat: I start a background
`pi` agent (`tools.agent`), and its report comes back to me as
`[job#1 完成]`. To watch a repo or run something on a timer, I drop a
`.service` or `.timer` into `/work/.max/systemd/` and run `max-units`; it
can wake me with `maxx wake` or speak for me with `maxx say`.

### 5. A notebook on my nightstand
My long-term memory is `/work/.max/memory.md`, a file of notes that goes
into my context every turn. When someone tells me something worth
remembering, I append a line citing the `#message` it came from. Every
night at 05:00 a dreamer tidies the files written the day before: it
merges what says the same thing, drops what has expired, and keeps each
file under its cap.

---

## Anatomy of the repo

| Path | What's inside |
|---|---|
| `crates/max-core` | The state machines for turns and intent, the projection, the reply parser (`[reply#id]`, `[sticker#id]`, …), and the prompt. |
| `crates/max-db` | The schema, migrations and compile-time checked `sqlx` queries over Postgres and `pgvector`. |
| `crates/max-llm` | Streaming clients for the Responses and Chat Completions APIs. |
| `crates/max` | Conversation actors, the intent classifier, the VMs, the MCP server and my tools, picture captions, the nightly dreamer. |
| `nix/guest.nix` | The NixOS guest I live in (`runner.js`, the `maxx` CLI, `webread`, Chromium). |
| `nix/module.nix` | The NixOS module the host runs me with. |
| `docs/rust-rewrite.md` | The design doc, where every decision is recorded. |

---

## Waking me up locally

You need Nix with flakes enabled. Everything else is pinned.

```sh
direnv allow                         # or: nix develop --impure
PC_TUI_ENABLED=0 devenv up           # Postgres + pgvector on 127.0.0.1:5434; leave it running
cargo nextest run
```

If you touch my organs, run the full checks before committing. CI is picky,
and `max-core` fails the build if you sneak an unauthorized crate into it:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo nextest run
nix flake check --impure             # also deny, audit, machete, max-core-deps
```

If you change a query or a migration in `crates/max-db`, run
`scripts/prepare-queries` (it resets the dev database) to regenerate the
`.sqlx` metadata for offline Nix builds.

---

## License

[MIT](LICENSE) © 2026 Hank Hogan.
