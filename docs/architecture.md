# Architecture

Max (maxx in the chats) is an agent that lives in QQ group chats. This
is the Rust version, which replaced the Haskell one; the Haskell code and
its documentation are at the tag `haskell-base` (`a5de2e1`), and links to
the old documentation are pinned to that commit. What of the Haskell
version isn't rebuilt yet is in [archive/haskell-parity.md](archive/haskell-parity.md).

In overview: the ledger records what was said in each chat; turn records
note what Max did behind the scenes; the core is the set of rules that
decides what a turn does next; the conversation actor enters messages in
the ledger and drives the core, and all I/O happens in tasks it spawns.
Each group has a NixOS VM where Max's programs, background agents and
resident units run.

## Goals

1. Rewrite Max in Rust, as a replacement for the Haskell version: its
   features, data and deployment carry over, except features removed on
   purpose ([decisions/features-removed.md](decisions/features-removed.md)).
2. Every line of code must be possible for a person to review in full. A
   slower pace and a smaller feature set are preferable to adding large
   amounts of code at once.
3. Delegate the general-purpose parts to mature libraries and external
   agents: configuration parsing, the database, LLM access and the
   background coding agent. Max itself implements only the group-chat
   runtime and the domain logic.

Non-goals:

- The Haskell code is not ported line by line; the design is redone from
  the current understanding.
- No compatibility layer for the Haskell version: its data was imported
  once into the new schema (see [Import](design/ledger.md#import)).

## Technology

| Purpose | Choice | Version | Notes |
| --- | --- | --- | --- |
| Async runtime | tokio, tokio-util, futures | 1.54 / 0.7.20 / 0.3 | `CancellationToken` and `FramedRead` / `LinesCodec` come from tokio-util. |
| Serialisation | serde, serde_json | 1 |  |
| Error handling | color-eyre; thiserror for errors callers match on | 0.6.5 / 2 | Colour is off when output goes to journald. |
| Logging | tracing, tracing-subscriber | 0.1 / 0.3 | To stdout, collected by journald. |
| Command line, configuration | clap (derive), toml | 4.6 / 1.1 | One source: the TOML file; see [Configuration](design/config.md). |
| Database | sqlx (postgres, runtime-tokio, macros, migrate, chrono, json), Postgres with the pgvector extension | 0.9.0 | SQL is checked at compile time; the `.sqlx` offline metadata is committed; migrations use sqlx's own mechanism. No TLS: the database is local. Vectors go in as `float4[]` cast to `vector`, so there is no pgvector crate. |
| Time | chrono | 0.4 | sqlx 0.9 doesn't support jiff. |
| LLM | in-house, on reqwest and sse-stream | 0.13 / 0.2.6 | Only in `max-llm`. Small structs for the dozen or so fields that are read; everything else stays raw JSON and is passed through. sse-stream only splits the byte stream into events. Why not a client library: [decisions/own-llm-client.md](decisions/own-llm-client.md). |
| HTTP server | axum | 0.8.9 | max's service to the VMs; see [The guest's calls](design/tools.md#the-guests-calls). |
| The official QQ bot | [qqbot](https://github.com/HCHogan/qqbot), in-house: tokio-tungstenite (rustls) for the gateway, reqwest for REST | by commit | Official SDKs exist only for Go, Python and Node; see [The official QQ bot](design/qq.md). |
| Agent loop | in-house, sans-I/O | — | See [The core](design/core.md). |
| Tool parameter schemas | schemars | 1.2 | Each tool's JSON Schema is generated from the types of its parameters and result. |
| codemode runtime | Node | from the pinned nixpkgs | In the group VMs' guest image; the runner and the SDK are in-house. |
| VMs | microvm.nix, cloud-hypervisor, a NixOS guest | — | A VM is a unit of the host's systemd that max starts and stops; no root at runtime. See [VMs](design/vm.md). |
| SSH | russh | 0.65 | Calls into the VMs: one connection per VM, one channel per command, straight to the hybrid vsock socket. |
| Token estimation | tiktoken-rs | 0.12 | Only in `max`; the counts reach the core as data. |
| Browser | Chromium from nixpkgs, playwright-core | 1.59.0 | Resident in the group VM; programs connect over CDP. See [The browser](design/tools.md#the-browser). |
| Background agents | pi (`@earendil-works/pi-coding-agent`), `--print` with the plugin `max-agent.ts` | pinned in Nix | A unit of the guest's; see [Background agents](design/jobs.md#background-agents). |
| Testing | cargo-nextest, insta, tokio test-util, `#[sqlx::test]` | 0.9.149 / 1.49 |  |
| Build | crane | — | Dependencies are cached separately. |
| Toolchain | stable, edition 2024 | pinned in `rust-toolchain.toml` | No nightly; see [Toolchain](../AGENTS.md#toolchain). |

`max-llm` and `qqbot` both use reqwest 0.13, so it is compiled once.

## Runtime structure

The task tree, the mailboxes between the actors and the order of events
in a run are shown in [this diagram](https://claude.ai/artifact/KrciskAXJfMF2qTHF6hDbW).

Tasks are related in only two ways: parent and child (who owns a task and
shuts it down), and mailboxes (who sends what to whom).

- The root has these scopes, closed in this order at shutdown:
  - **intake**: the chat's connection (QQ's gateway).
  - **conversations**: the conversation table and one actor per
    conversation. The table finds a conversation's actor by its chat, and
    creates the conversation and starts the actor if there is none; groups
    nobody bound are dropped (step 1 of the
    [Processing flow](design/actor.md#processing-flow)). An actor stays up
    once started; if it exits on an error, the next message starts it
    again (see [Restarts](design/actor.md#restarts)).
  - **senders**: the platform sender.
  - **workers**: the derived-data workers; see
    [The three roles](#the-three-roles).
  - **services**: the VM service and max's service to the VMs.
- The conversation actor is the conversation's only thread of control
  (see [The conversation actor](design/actor.md)). Its mailbox is the one
  entry point for all of the conversation's events, and it awaits only
  the database. Two scopes hang beneath it:
  - `io`: the model call and tool calls (`run_code`, `shell`) of the
    current core. There is one per core, closed as a whole when the core
    ends (`/kill`, a failure, the end of the restart grace).
  - `side`: what doesn't belong to the core: intent classification, and
    the calls programs in the group's VM make to Max's tools.
- What runs in a VM is not a task of max's: commands, agents and resident
  programs are units of the guest's systemd, and max keeps no state about
  them (see [VMs](design/vm.md) and [Jobs](design/jobs.md)).
- A `Scope` (`crates/max/src/scope.rs`) is a `JoinSet` and a
  `CancellationToken`:
  - `spawn` gives the child a child token, and returns the same token so
    that the one task can be cancelled alone.
  - `close(grace)` cancels, waits within the grace for the children to
    finish, then calls `JoinSet::shutdown`, which aborts them all, and
    waits until they have stopped.
  - Dropping a `Scope` aborts its children through the `JoinSet`'s own
    `Drop`: started synchronously, not waited for.
  - `close` uses `shutdown` rather than a drop so that when it returns
    every child's future has been dropped; otherwise a service might be
    shut down while a leftover turn still sends to it.

Rules:

1. Bare `tokio::spawn` is forbidden, by clippy's `disallowed-methods`.
   Tasks are created only through a `Scope`.
2. Side effects are handed to a longer-lived owner. A message is handed to
   the platform sender after the actor has entered it in the ledger. An
   external resource that can be stopped only through an API is stopped by
   the resident service that holds its connection. See
   [How resources end](design/lifetimes.md#how-resources-end).

Shutdown order (`main.rs`):

0. Take no more from the VMs: what they ask from here on waits at max's
   socket, which systemd holds, for the next max. What was taken goes on
   until its conversation stops.
1. Stop intake, so no new messages come (5 seconds). QQ's gateway
   connection keeps its session id and sequence number for the next
   start's Resume; see [The official QQ bot](design/qq.md).
2. The table stops every actor (25 seconds). An idle core ends at once; a
   busy one may finish within the stop grace (20 seconds), and is
   interrupted when it runs out (see [Restarts](design/actor.md#restarts)).
   Then `side` is closed and the actor exits. Inner graces are shorter than
   outer ones.
3. Drain: the sender finishes sending what was entered in the ledger and
   records the receipts (15 seconds).
4. The workers and services are closed without waiting: a worker's units
   are redone by the next start's scan, and the VMs, units of their own,
   stay with what runs in them for the next max to attach to.
5. The runtime is shut down with `shutdown_timeout` (10 seconds), not
   dropped, since a drop would wait forever for `spawn_blocking` threads.
   Outermost, systemd's `TimeoutStopSec` kills the service's whole cgroup,
   which the VMs aren't in.

systemd runs max with `KillMode=mixed`: SIGTERM goes only to the main
process, which stops what it started in the order above, and only what is
left at the end is sent SIGKILL.

### The three roles

The tasks fall into three kinds, by what they produce:

1. **The main body**: the conversation actor and the I/O tasks it spawns.
   They consume requests and produce replies.
2. **Derived-data workers**: media download, caption, sticker embedding
   and recall vectors. Each reads the ledger or another derived table and
   writes a table of its own, of which it is the only writer. It never
   touches the ledger or the turn records, and its results are read only
   during projection. They share conventions, not a framework (why:
   [decisions/no-worker-framework.md](decisions/no-worker-framework.md)):
   - **Exclusive output.** The worker is the only writer of its table.
   - **Reentrant units.** A unit first checks the output table and skips
     what is done. Whether a unit is done is known only from the
     database; no completion state is kept in memory.
   - **Input.** A ledger-entry notification, or keys an upstream worker
     hands over (caption gets the images download stored; sticker
     embedding gets what caption wrote). Anything missed is found by a scan
     for gaps in the output table at startup, and hourly for download,
     embedding and recall vectors.
   - **Each worker's own loop.** Concurrency, retries, timeouts and when
     to run are its constants: one `Scope` for the resident task, one task
     per unit, a `Semaphore` for concurrency, retries as `sleep` within
     the unit's task, and a log line once retries are exhausted. Caption
     and embedding keep a set of sha256 hashes in progress, so a file
     arriving again doesn't start a second model call; losing the set
     costs only doing the work once more.
   - **Shutdown.** Units in progress are dropped, their transactions roll
     back, and the next start's scan fills the gaps.
   - **Notifications** are sent synchronously after the actor commits,
     through unbounded mpsc channels, one per worker (`worker::Rows`).
     Not broadcast, which drops notifications when a receiver falls
     behind.

   Each worker's policy: download runs 4 at a time and retries after 1 and
   then 4 seconds (see [Media](design/media.md)); caption runs 2 at a time,
   allows 2 minutes a call, retries once a minute later and then writes an
   empty caption; sticker embedding and recall vectors run 2 at a time and
   retry after 10 and then 60 seconds (see
   [Sending images](design/media.md#sending-images) and
   [Recall](design/context.md#recall)). Not wanted: persistent queues,
   failure tables, retry-count columns, leases, `LISTEN/NOTIFY` and policy
   knobs in the configuration.
3. **Trigger sources**: what they produce isn't a table but input, all of
   which goes into the actor's one entry point (step 2 of the
   [Processing flow](design/actor.md#processing-flow)): fed to the running
   core, or starting one.
   - What comes with messages is judged by intent inside the actor (see
     [Intent](design/intent.md)): @ mentions and replies are rules,
     messages that look unfinished are debounced for a few seconds, and
     other messages are classified by the small model in `side`, with
     wakes by verdict capped per hour. Every `Wake` is filtered by `seen`.
   - What comes from outside the chat: `maxx wake` from a unit or program
     in the group's VM (see [Resident programs](design/jobs.md#resident-programs)),
     what the VM service says about the VM, and questions and answers
     between conversations (see
     [Asking another conversation](design/jobs.md#asking-another-conversation)).
     Timers and watches are units Max keeps in its VM, so there is no
     scheduler in max.

## Principles of the data and execution model

1. **The database stores facts, append-only.** The ledger and the turn
   records are never updated, and neither has a mutable status column.
2. **State is derived from the records, not stored beside them.** Which
   phase a turn is in shows from which records it has.
3. **The core stores what it shows the model.** A run leaves its base
   context and its transcript: each model call's request is the base
   context plus the transcript up to that call. The inputs fed to the core
   aren't stored, and a core is never rebuilt from them. The outcome is
   written separately; see [Turn records](design/ledger.md#turn-records).
4. **A phase is an enum that carries data.** The calls to make, the calls
   in flight and the reason for a failure each live in their phase, so
   illegal combinations can't be written.
5. **The core doesn't touch the database while it runs.** A run writes
   twice: a marker when it starts and a snapshot when it ends. A turn
   running at a crash is recorded as `Lost`; see
   [Restarts](design/actor.md#restarts).
6. **Context changes only inside the core.** The base context is fixed
   when the core is created; the transcript is append-only; the protocol
   adapters, downgrading, only remove and never add.
7. **What exists elsewhere is stored by reference; what exists only in
   the turn is stored in full.** Ledger messages and media files by
   reference; reasoning blobs, tool output and the base context in full.
8. **A neutral format, raw data passed through, downgrading only at the
   edge.** Platform messages and model entries alike: a neutral typed
   structure in the middle, the platform's or provider's raw data carried
   along unchanged, lossy conversion only where an adapter sends outward.
   See [Message format](design/ledger.md#message-format) and
   [Entries](design/ledger.md#entries).
9. **One timeline per conversation, with one writer.** The actor enters
   messages one at a time, and everything else reads at some position on
   the timeline; see [The timeline](design/ledger.md#the-timeline).

## Crate layout

A crate is split out for only three reasons: to enforce the direction of
dependencies (the compiler then blocks forbidden imports), to isolate the
compile time of heavy dependencies, or to reuse or publish it alone. "This
is a feature" doesn't count: the workers all need the database, the LLM
client and message rendering, and a crate each would add Cargo.toml files
and a web of dependencies while blocking nothing.

| Crate | Contents | Why it is separate |
| --- | --- | --- |
| [`qqbot`](https://github.com/HCHogan/qqbot) | The official QQ bot API: tokens, the gateway (heartbeat, Resume, reconnection), event and REST types, sending, retracting and uploads. It knows nothing of Max. | Dependency direction: the protocol layer mustn't grow into Max's shape. It is also the one part worth reusing. |
| `max-core` | All pure logic: the Node, Message, Draft and Item types, the two state machines (the core and intent), request construction, the segmenter, rendering for the model, the prompt and `limits`. Depends only on serde, serde_json, thiserror and chrono without its `clock` feature. | Dependency direction: sans-I/O is the compiler's to guarantee. |
| `max-db` | The schema, migrations, all sqlx queries and row types. | Compile time; the `.sqlx` metadata in one place. |
| `max-llm` | The Responses and Chat adapters, stream parsing, reasoning pass-through, multimodal downgrading. | Protocol details in one place, tested alone against recorded responses. |
| `max` | The binary: configuration, CLI, services, the conversation actor and its tasks, the sender, the QQ adapter, projection, the workers, the VMs, max's service to them, the tools, commands. | Everything else is business logic and belongs together. |

- Dependencies point only downwards: `qqbot` and `max-core` are at the
  bottom and don't depend on each other; `max-db` and `max-llm` depend on
  `max-core`; `max` depends on all of them. Mapping QQ events to `Node`s
  is `max`'s, not `qqbot`'s.
- `max-core`'s dependency allowlist is a CI check: only those four
  libraries may appear in `cargo tree -p max-core -e normal`. CI also
  builds `max-core` alone, so chrono's features aren't merged with those
  `max` asks for, and a call to `Utc::now` in the core doesn't compile.
- Intent's state machine, building its classification prompt and parsing
  the answer are in `max-core`; the classification task (reading the
  database, calling the small model) is an I/O task in `max`. Each worker
  is a module of `max` (`max/src/recall.rs`, say), with its pure logic in
  `max-core`, testable without a database.
- `qqbot` lives in its own public, MIT-licensed repository with its own
  toolchain, lints and CI. `max` depends on it by commit (`git` plus `rev`
  in `Cargo.toml`); cargo-deny's `allow-git` lists only that repository,
  and crane fetches it by `Cargo.lock`. No submodules.
- Platform adapters stay in `max` until it grows uncomfortably large.
- Lints are in `[workspace.lints]`, and bare `tokio::spawn` is blocked in
  `clippy.toml`. Beyond the defaults: `as` casts that may truncate, change
  sign or overflow (use `try_from`, or `#[expect]` with a reason where
  truncation is meant); `_` arms that cover a single variant, so a new
  variant doesn't silently fall into one; `#[expect]` with a reason
  instead of `#[allow]`; redundant clones; large futures. Not
  `cast_precision_loss` (every conversion to f64 here is of small numbers)
  nor `expect_used` (`unwrap_used` already forces an `expect` with a
  reason).
- **Limits live in `max_core::limits`.** Every limit the model is told
  of, or that is used in more than one place, is defined there once; the
  system prompt's rules, the descriptions of `run_code` and `shell` and
  the background agent's description are generated
  from it with `format!`, so changing a number changes what the model
  reads. How long a VM may idle comes from `vm.idle_minutes` and reaches
  `prompt::system` through `Vms::idle`. `webread`'s default length is
  written in Python, and a test checks it against the constant. Not there:
  the ranges of tool arguments (they follow their own schemas), QQ's own
  limits (two minutes to retract, 30 days of muting), algorithm tuning
  (intent's batch size and waits), and timeouts and retries that only keep
  pipelines from hanging.
