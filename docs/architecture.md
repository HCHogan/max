# The Rust rewrite of Max

> Status: draft, begun 2026-10-26 and extended as decisions are made. Items marked **TBD** are not yet resolved.
>
> The code is on the main branch of this repository (since 2026-10-31; before that on the `maxx` branch, which was renamed from `rust` on 2026-10-28). The starting point of the rewrite is tagged `haskell-base` (`a5de2e1`); the Haskell version's code and documentation remain there, and links to the old documentation in this document are pinned to that commit.

## Goals

1. Rewrite Max in Rust. At go-live, the Rust version must be a drop-in replacement for the Haskell version: its features, data and deployment must carry over, except for features removed on purpose.
2. Every line of code must be possible for a person to review in full. A slower pace and a smaller feature set are preferable to adding large amounts of code at once.
3. Delegate the general-purpose parts to mature libraries and external agents, including configuration parsing, the database, LLM access and the background coding agent. Max itself implements only the group-chat runtime and the domain logic.

Non-goals:

- The Haskell code is not ported line by line; the design is redone according to the current understanding.
- No compatibility layer is written for the Haskell version. Its data is imported once into the new schema (see [Go-live: conditions for a drop-in replacement](archive/go-live.md#go-live-conditions-for-a-drop-in-replacement)).

## Technology choices

Used in v1:

| Purpose | Choice | Version | Notes |
| --- | --- | --- | --- |
| Async runtime | tokio, tokio-util, futures | 1.54 / 0.7.20 / 0.3 | `CancellationToken` and `FramedRead` / `LinesCodec` come from tokio-util. |
| Serialisation | serde, serde_json | 1 |  |
| Error handling | color-eyre; thiserror for errors that callers need to match on | 0.6.5 / 2.0 | Colour is turned off when output goes to journald. |
| Logging | tracing, tracing-subscriber | 0.1 / 0.3 | Output goes to stdout and is collected by journald. |
| Command line, configuration | clap (derive), toml | 4.6 / 1.1 | There is a single source: the TOML file; see [Configuration](design/config.md#configuration-1). |
| Database | sqlx (postgres, runtime-tokio, macros, migrate, chrono, json) | 0.9.0 | SQL is checked at compile time; the `.sqlx` offline metadata is committed to the repository; migrations use sqlx's own mechanism. TLS is not enabled, because the database is on the local machine. |
| Time | chrono | 0.4 | sqlx 0.9 does not support jiff. |
| LLM | In-house, reqwest plus sse-stream | — / 0.13 / 0.2.6 | Used only in `max-llm`. For the wire format, small structs are written only for the dozen or so fields that are read; everything else is kept as raw JSON and passed through. sse-stream only splits the byte stream into events. Switched from async-openai 0.42.2 on 2026-10-29: in byot mode the request and response types had to be written by hand anyway, which left it doing nothing but sending requests and parsing SSE; each of its streams starts, via `tokio::spawn`, a task that we do not control; when a connection drops midway, the stream simply ends without reporting an error; and it released a breaking minor version roughly once a month. |
| HTTP server | axum | 0.8.9 | max's service to the VMs; the admin interface will later be mounted here as well. |
| Official QQ bot | In-house: tokio-tungstenite (rustls) for the gateway, reqwest for REST | — / 0.30 / 0.13 | Official SDKs exist only for Go, Python and Node; see [The official QQ bot](design/qq.md#the-official-qq-bot-1). |
| agent loop | In-house, sans-I/O | — | The research findings are in [The core](design/core.md#the-core-1). |
| The guest's calls | In-house, axum | — / 0.8 | Max's service to a VM, through which programs there call the host's tools: plain HTTP; see [The guest's calls](design/tools.md#the-guests-calls). It spoke MCP until 2026-11-14, with rmcp 3.8 until 2026-11-03. |
| Tool parameter schemas | schemars | 1.2 | The JSON Schema of each tool contract is generated from the types of its parameters and return value. |
| codemode runtime | Node | — | Built into the guest image of the group VMs; the versions follow the pinned nixpkgs. The runner and the SDK are written in-house. |
| VM | microvm.nix, cloud-hypervisor, a NixOS guest, commands over SSH on vsock | — | The Haskell version's guest is reused. There is no broker: a VM is a unit of the host's systemd that max starts and stops (a child process of max until 2026-11-12), and no root privileges are needed at runtime; see [VM processes](design/vm.md#vm-processes). |
| SSH | russh | 0.65.0 | Used to call into the VMs: one connection per VM and one channel per command, connected directly to the hybrid vsock socket. |
| Token estimation | tiktoken-rs | 0.12 | Used only in `max`; the computed counts are passed into the core as data; see [The core](design/core.md#the-core-1). |
| Testing | cargo-nextest, insta, tokio test-util, `#[sqlx::test]` | 0.9.149 / 1.49 |  |
| Build | crane | — | Dependencies are cached separately. |
| Toolchain | stable, edition 2024 | The exact version is pinned in `rust-toolchain.toml` | No nightly; see [Toolchain](../AGENTS.md#toolchain). |

`max-llm` and `qqbot` both use reqwest 0.13, so reqwest is not compiled twice.

Added after v1:

| Purpose | Choice | Notes |
| --- | --- | --- |
| Browser | Chromium from nixpkgs (currently 155), playwright-core 1.59.0 | A resident service in the group VM, to which programs connect over CDP; see [The browser](design/tools.md#the-browser). |
| Vectors | pgvector 0.4.2 | Supports sqlx < 0.10. |
| Automations | croner 4 |  |
| Background agents | pi (`@earendil-works/pi-coding-agent`), `--print` plus the plugin `max-agent.ts` | Runs in the group VM as a unit of the guest's; its version is pinned in Nix. |
| Matrix | matrix-sdk 0.18.0 | Not done for now; 0.19 and sqlx 0.9.0 cannot be resolved together; see [Matrix](decisions/2026-10-29-matrix-deferred.md#matrix). |

## Runtime structure

The task tree, the mailboxes between the actors and the order of events in a run are shown in [this diagram](https://claude.ai/artifact/KrciskAXJfMF2qTHF6hDbW).

Tasks are related in only two ways: parent and child (who owns a task and who is responsible for shutting it down), and mailboxes (who sends what to whom).

- The root scope has two child scopes:
  - services: the resident tasks. These are the platform connection (QQ's gateway connection), the platform sender, the VM service, max's service to each VM, the derived-data workers, and later the automation scheduler. See [The three roles](#the-three-roles).
  - conversations: the conversation table, plus one actor per conversation. The conversation table finds a conversation's actor by endpoint; if there is none, it creates the conversation and starts the actor. Groups that are not bound are dropped outright; see step 1 of [Processing flow](design/actor.md#processing-flow). Once started, an actor stays up and does not exit when idle; if it exits because of an error, the next message starts it again; see [Restarts](design/actor.md#restarts).
- The conversation actor is the conversation's only thread of control; see [The conversation actor](design/actor.md#the-conversation-actor-1). Its mailbox is the single entry point for all of the conversation's events, and the actor itself awaits only the database. Three scopes hang beneath it:
  - `io`: the model calls and tool calls (`run_code`, `shell`) that the current core has in flight. There is one per core, and it is closed as a whole when the core ends (`/kill`, a failure, or the expiry of the restart grace period).
  - `side`: calls that do not belong to the core, such as intent classification.
  - `jobs`: background agents, which can outlive the core that started them. Each job has a scope of its own, and dropping that scope stops the job (2026-10-30).
- A `Scope` consists of a `JoinSet` and a `CancellationToken` (the reaper, defer and Background were removed on 2026-10-27):
  - `spawn` gives the child task a child token, and the same token is returned to the caller so that this one task can be cancelled on its own.
  - `close(grace)` first cancels, then waits within the grace period for the child tasks to finish on their own; when the grace period expires, it calls `JoinSet::shutdown`, which aborts them all, and then waits for them to actually stop.
  - When a `Scope` is dropped, the `JoinSet`'s own Drop aborts all child tasks. This is initiated synchronously, without waiting.
  - On expiry, `close` uses `shutdown` rather than simply dropping, to guarantee that by the time it returns the futures of all child tasks have actually been dropped. Otherwise a service might already be shut down while a leftover turn is still sending things to it.

Rules:

1. Bare `tokio::spawn` is forbidden and is blocked with clippy's `disallowed-methods`. Tasks can only be created through a `Scope`.
2. Detaching must be explicit: background agents hang under the conversation's `jobs`, not under the core's `io`.
3. Side effects are handed to a longer-lived owner. Sending is handed to the platform sender after the conversation actor has entered the message in the ledger. For external resources that can only be stopped through an API, the stop command is handed to the resident service that holds that connection. See [How resources end](design/lifetimes.md#how-resources-end).

Shutdown order:

1. Stop intake, so that no new messages are produced. At this point QQ's gateway connection saves the session id and sequence number; see "Resume across restarts" in [The official QQ bot](design/qq.md#the-official-qq-bot-1).
2. Each conversation actor receives a stop. If the core is idle, the actor ends; otherwise the core is allowed to finish what it is doing within the grace period, and if it is still not idle when the period expires, `io` is closed and the turn is interrupted (see [Restarts](design/actor.md#restarts)). Then `side` and `jobs` are closed, and the actor exits. Inner grace periods must be shorter than outer ones.
3. Drain: the platform sender finishes sending the messages already entered in the ledger and records the receipts, subject to a deadline.
4. The root scope ends. The runtime is shut down with `shutdown_timeout` rather than dropped directly, because a drop would wait indefinitely for `spawn_blocking` threads. At the outermost level, systemd's `TimeoutStopSec` is the backstop: when it expires, the whole cgroup of the service is killed.

systemd must be set to `KillMode=mixed`: SIGTERM goes only to the main process, which stops what it started in the order above, and only whatever remains at the end is sent SIGKILL by systemd all at once. The VMs are not in the service's cgroup since 2026-11-12: each is a unit of its own, and a stop of max leaves them and what runs in them (see [VM processes](design/vm.md#vm-processes)). Until then they were max's children, and the default `control-group` would have sent SIGTERM to cloud-hypervisor and virtiofsd at once, and the grace period that step 2 gives to tool batches would have come to nothing.

### The three roles

Decided 2026-10-27. The tasks in the runtime fall into three kinds, classified by what they produce:

1. **The main body**: the conversation actor and the I/O tasks it spawns. They consume requests and produce replies.
2. **Derived-data workers**: lingo, embedding, caption, recall vectors, media download and the expansion of forwarded messages. Each takes as input the ledger or another derived table and writes its output to a table of its own, of which it is the only writer. It never touches the ledger or the turn records, and its results are read only during projection. The cursor for reading the ledger is kept per conversation; see [The timeline](design/ledger.md#the-timeline). There are three kinds of trigger: ledger-entry notifications, a timer or watermark, and gap scans at startup and at regular intervals. Each unit of work is one transaction, so nothing is left half-done; no queue is persisted across restarts, and scans fill the gaps instead. The Haskell version's simplification in September also ended up converging these on "a bounded local queue plus a scan for missing data".

   Only conventions are shared, and no framework is written (decided by the owner on 2026-10-29: a generic driver was written first, which ordered units by `Throttle`/`Debounce`/`Urgent`; as a result, all the scheduling policies piled up in the driver, and whether a unit was done was recorded twice, once in the driver's queue and once in the database. It was taken apart and moved back into the individual workers the same day):
   - The output table is exclusive, with the worker as its only writer. The worker never touches the ledger or the turn records, and its results are read only during projection.
   - Units are reentrant: the worker first checks the output table and skips the unit if the result already exists. Whether a unit is done is determined only by the database; no completion state is kept in memory.
   - The input is a ledger-entry notification or keys handed over by an upstream worker (caption receives the images that the download has stored; embedding receives the stickers that caption has written). Anything missed is filled in by a scan that looks for gaps in the output table: at startup, and additionally once an hour for embedding and recall vectors.
   - Concurrency, retries, timeouts and when to run are each worker's own constants and its own loop: one `Scope` for the resident task, one task per unit, a `Semaphore` to limit concurrency, retries done with `sleep` inside the unit's own task, and nothing but a log entry once the retries are exhausted. caption and embedding additionally keep a set of sha256 hashes that are "in progress": if the same file arrives again while it is being processed, no second unit is started. This set only prevents duplicate model calls; if it is lost, the only cost is doing the work once more.
   - At shutdown, units in progress are simply dropped, their transactions roll back, and the scan at the next startup fills the gaps.
   - Ledger-entry notifications are sent synchronously after the conversation actor commits, through a set of unbounded mpsc channels in `Shared`, one per worker (`worker::Rows`). broadcast is not used, because it drops notifications when a receiver falls behind. The mailbox type is defined by the worker and converted from the ledger row.

   The current policy of each worker: download runs 4 at a time and waits 1 second and then 4 seconds before retrying; see [Media](design/media.md#media-1). caption runs 2 at a time, retries once, a minute after a failure, and writes an empty caption if it fails again. embedding runs 2 at a time and waits 10 seconds and then 60 seconds before retrying; see [Sending images](design/media.md#sending-images). Recall vectors work the same way; see [Recall](design/context.md#recall). Unlike in the Haskell version, the flags in `message_projections` are not used as a queue. The following are not wanted: persistent queues, failure tables and retry-count columns, leases, `LISTEN/NOTIFY`, and policy knobs in the configuration. When lingo arrives, it writes its own loop following these points.
3. **Trigger sources**: what they produce is not a table but input, all of which goes into the same entry point of the conversation actor (step 2 of [Processing flow](design/actor.md#processing-flow)). If a core is running, the input is fed to it; if not, a core is started. The only difference lies in the source:
   - Everything that arrives with messages is judged by the intent logic inside the conversation actor (see [Intent](design/intent.md#intent-1)). @ mentions and replies are its synchronous rules, and messages that look unfinished are first debounced for a few seconds. Other messages are classified asynchronously by the small model in `side`; wakes by verdict are subject to an hourly cap, and verdicts come back to the mailbox without blocking other messages. Every `Wake` that wakes the core is filtered by `seen`. The ledger_match of automations is a rule.
   - Everything that comes from outside: cron, HTTP webhooks, external polling, and proactive idle triggers. A scheduler under services, with its definitions in the `automations` table, sends requests to the corresponding conversation actor when they fall due. The scheduler has the same shape as a derived-data worker (resident, timer-driven, the exclusive writer of `automation_fires`, one scan at startup), except that the result of `run` is a request being sent. The details are to be completed when automations are built.

## Data and execution model

Settled in discussion from 2026-10-26 to 2026-10-28. In overview: the ledger records what was said in the group; turn records note what Max did behind the scenes; the core is the set of rules that decides what a turn does next; the conversation actor enters messages in the ledger and drives the core, and all I/O takes place in tasks that it spawns.

### Principles

1. **The database stores facts, append-only.** Neither the ledger nor the turn records are ever subject to an UPDATE, and neither has a mutable status column.
2. **State is derived from the records, not stored separately.** Which phase a turn is in can be told from which kinds of records it has.
3. **The core stores what it shows the model.** What a run leaves behind is the base context and the transcript: the request of each model call is the base context plus the transcript up to that call's output. The inputs fed to the core are not stored, and the core is not rebuilt from its inputs (changed 2026-10-29 at the owner's suggestion: originally an input log was stored and the core was restored by replaying it; once recovery on restart was dropped, replay was used only by tests, while model output was stored twice, once in the log and once in the transcript, and reasoning blobs were stored twice along with it). The outcome is written down separately; see [Turn records](design/ledger.md#turn-records).
4. **A phase is written as an enum that carries data.** The calls to be made, the calls in flight and the reason for a failure each live in their own phase, so illegal combinations cannot be written (changed 2026-10-29; previously five fields represented the phase together, and the legal combinations were maintained by hand).
5. **The core does not touch the database while it runs.** A run writes only twice: a marker when it starts, and a snapshot when it ends, which is the record described above. A turn that is running when a crash happens is recorded as `Lost`; see [Restarts](design/actor.md#restarts).
6. **Context changes only inside the core.** The base context is passed in when the core is created and does not change afterwards; the transcript is append-only; trimming applies only to each individual request; when the protocol adapter layer downgrades, it only removes and never adds.
7. **What already exists elsewhere is stored by reference; what exists only in the turn is stored in full.** Ledger messages and media files are stored by reference; reasoning blobs, tool output and the base context are stored in full.
8. **A neutral format, raw data passed through, and downgrading only at the edge.** Platform messages and model entries follow the same approach: in the middle is a neutral typed structure, the platform's or provider's raw data is carried along unchanged, and lossy conversion happens only at the step where an adapter sends outward. See [Message format](design/ledger.md#message-format) and [Entries](design/ledger.md#entries).
9. **One timeline per conversation, with one writer.** The conversation actor enters messages one at a time, and everything else reads at some position on the timeline; see [The timeline](design/ledger.md#the-timeline).

## Crate layout

Decided 2026-10-27. Only three reasons justify splitting out a crate: enforcing the direction of dependencies (the compiler blocks forbidden imports for you), isolating the compile time of heavy dependencies, and reuse or publication on its own. "This is a feature" does not count: lingo, the embedder and recall vectors all need the database, the LLM client and message rendering, and giving each of them its own crate would only add a pile of Cargo.toml files and a web of mutual dependencies while blocking nothing.

| crate | Contents | Reason for splitting |
| --- | --- | --- |
| `qqbot` | The official QQ bot API: tokens, the gateway (heartbeat, Resume, reconnection), event and REST types, sending and retracting, plus uploads once images are sent. It knows nothing of Max: no Node, no conversations. Since 2026-11-03 it lives in its own repository, [HCHogan/qqbot](https://github.com/HCHogan/qqbot) | Dependency direction: the protocol layer must not grow into Max's shape. It is also the only part worth reusing |
| `max-core` | All pure logic: the Node/Message/Draft/Item types, the two state machines (the core and intent), request construction, the segmenter, and rendering for the model. It depends only on serde, serde_json, thiserror, and chrono without the `clock` feature (needed to render `HH:MM`, day changes and gap markers) | Dependency direction: sans-I/O is guaranteed by the compiler |
| `max-db` | The schema, migrations, all sqlx queries and row types | Compile time; the `.sqlx` offline metadata is kept in one place |
| `max-llm` | The Responses and Chat adapters, stream parsing, reasoning pass-through, multimodal downgrading | All protocol details are contained here and tested on their own with recorded responses |
| `max` | The binary: configuration, CLI, services, the conversation actor and I/O tasks, platform senders, the QQ adapter, projection, lingo, the worker framework, VMs, max's service to them, tools, commands | Everything else is business logic and belongs together |
| ~~`max-import`~~ | Binary: import of the old database | The old schema's code lived only here; removed 2026-11-05, see [Import](design/ledger.md#import) |

- Dependencies point only downwards: `qqbot` and `max-core` are at the bottom and do not depend on each other; `max-db` and `max-llm` depend on `max-core`; `max` depends on all of them. The mapping from QQ events to Node lives in `max`, not in `qqbot`.
- `max-core`'s dependency allowlist is written into CI: only those four libraries may appear in `cargo tree -p max-core -e normal`. CI also runs `cargo check -p max-core` separately: when only this package is built, chrono's features are not merged with those requested by `max`, so a call to `Utc::now` in the core fails to compile.
- intent's state machine, together with building the classification prompt and parsing its output, is in `max-core`; the classification task (reading the database, calling the small model) is an I/O task in `max`. Each derived-data worker is a module of its own, for example `max/src/recall.rs`; their pure logic (prompts, validation) goes in `max-core`, where it can be tested without starting a database.
- Platform adapters are not split into a crate for now; `max` will be split once it grows uncomfortably large.
- `qqbot` originally did not have its own repository (the shape of the protocol layer was still expected to change during v1). On 2026-11-03 the owner asked for it to be split out: `git subtree split` created [HCHogan/qqbot](https://github.com/HCHogan/qqbot) with its 17 commits. It is public and MIT-licensed, with its own Cargo.toml (the workspace's dependencies, lints and package fields written out), toolchain, clippy.toml, and CI that runs fmt, clippy and the tests. max depends on it by commit: `git` plus `rev` in `Cargo.toml`, and changing versions means changing `rev`; cargo-deny's `allow-git` lists only this one repository; crane fetches it according to `Cargo.lock`, so no separate hash is needed. Git submodules are not used. md-5, sha1 and tokio-tungstenite, which only qqbot used, were removed from the workspace's dependencies.
- Lints are centralised in the workspace's `[workspace.lints]`; bare `tokio::spawn` is blocked through `disallowed-methods` in `clippy.toml`. On 2026-11-05 a few pedantic lints were added: `as` casts that may truncate, change sign or overflow (use `try_from` instead; where truncation is really intended, write `#[expect]` with a reason); `_` arms that cover a single variant (so that a newly added variant does not silently fall into them); every `#[allow]` replaced with an `#[expect]` that gives a reason; redundant clones; large futures. `cast_precision_loss` is not enabled (every conversion to f64 here is of small numbers), nor is `expect_used` (`unwrap_used` already forces an `expect` with a reason, so blocking that as well would mean writing the same sentence twice).
- **Limits are centralised in `max_core::limits`** (2026-11-05). They used to be scattered over a dozen or so files, some with the same number written two or three times (64 MiB once each in the error messages of downloads, send_file and chat_file; the 600-second video limit once each in show and in projection; the 256 KiB memory file limit once each in the actor and the dreamer), and the numbers in prompts and tool descriptions were written by hand. Now every limit that the model is told about, or that is used in more than one place, lives in this one module; the system prompt's rules, the descriptions of run_code and shell, the background agent description and the memory-tidying prompt are all generated from it with `format!`, so changing a number changes what the model reads. How long a VM may stay idle before it is shut down comes from the configuration key `vm.idle_minutes` and is passed to `prompt::system` through `Vms::idle`. The default character count of `webread` in the guest is written in Python, and a test checks it against the constant. What stays where it is: the ranges of tool arguments (they follow their own schemas), QQ's own limits (two minutes to retract, 30 days of muting), algorithm tuning (intent's batch size and waits), and timeouts and retries that exist only to keep pipelines from hanging.
