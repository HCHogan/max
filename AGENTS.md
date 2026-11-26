# Repository instructions

This is the Rust rewrite of Max, on `main` since 2026-10-31. The design lives in
`docs/` ([docs/README.md](docs/README.md) is the index); keep it true as you
change the code, as "Documentation" below says. The Haskell
version, with its docs and assets, is at tag `haskell-base`; bring a file
back with `git restore --source=haskell-base -- <path>` when the feature
that needs it is being built.

## Before every commit

In the dev shell (`nix develop --impure`, or direnv), from the repository
root:

- `cargo fmt --check`
- `cargo clippy --all-targets -- -D warnings`
- `cargo nextest run`

Do not commit if any of them fails. `nix flake check --impure` runs these
and the rest of CI's checks: cargo-deny, cargo-audit, cargo-machete,
max-core's dependency allow list, max-core built alone, and the package.

The dev shell's Postgres (port 5434, database `max`, role `max`) runs under
`devenv up`, the dev shell's own: a `devenv` installed elsewhere reads some
other project. Without a terminal, start it with `PC_TUI_ENABLED=0 devenv up`.

## Background agents' harness

The flake's `fx` check runs the guest's fx, `nix/fx.sh`, with the pinned
fx against a fake `/llm`, without real model calls: it is what says
whether a move of fx's pin, or a change to `nix/fx.sh` or
`nix/fx-system.md`, keeps what Max rests on. `scripts/check-fx` runs the
same in the dev shell. An agent in a background command is covered with
the guest's jobs, below.

## The guest's jobs

After changing `nix/max-jobs.sh`, `nix/max-units.sh`, `nix/fx.nix`,
`nix/maxx.nix`, `nix/local.json` or `nix/jobs.nix`, build
`.#checks.<system>.jobs` for a Linux system (`aarch64-linux` on a Mac
with a Linux builder): a NixOS test of what Max runs in a VM as units,
with no VM inside it. What the host makes of a call's line is in
`crates/max/src/tools.rs`; the two meet only in `max vm-check` and the
nested test, `.#nestedChecks.x86_64-linux.vm`, which needs nested KVM
and runs on tank.

## A guest and its image

A VM outlives max, and max attaches only to a VM that booted the image
max boots itself: a deploy that changes the guest's image stops the VMs
that run, with the background commands and agents in them, and each boots
the new image when it is next needed (see "A VM outlives max" in
docs/design/vm.md). So both ends of what a guest and max say to each
other change together: the arguments of what max runs with `maxx`, the
line a call prints, the runner's input, the routes a guest calls. Any
change to a guest file is such a deploy, a comment's too.

What the host gives a VM at its boot isn't the image's: the link its
calls come by (see "A guest's calls reach max" in docs/design/vm.md), the
unit's launcher in `nix/module.nix`, the command line. A change to those
reaches a VM at its next boot; when it can't wait, the deploy stops the
VMs, `systemctl stop 'maxx-vm@*'`. The tests of how max tells whose VM a
call is from are in `crates/max/src/service/http.rs` and the nested test.

## Queries

max-db's queries are checked at compile time: against the dev database in
the dev shell, and against `crates/max-db/.sqlx` in the Nix build, which has
no database. After changing a query or a migration, run
`scripts/prepare-queries` (it resets the dev database) and commit
`crates/max-db/.sqlx`. To build without the database running, set
`SQLX_OFFLINE=true`.

## The chunker's proofs

`crates/max-core/src/segment/chunk.rs` is written in the part of Rust that
Aeneas translates, and `verify/` proves things of the translation. After
changing it, run `verify/extract` and commit `verify/MaxCore/`, then
`lake build` in `verify/`; see `verify/README.md`. CI checks both.

## Public repository

The repository is public. Use made-up QQ numbers, openids, group ids and
chat handles in tests, docs and examples; real ones live only in sops.
The QQ bot's AppID and secret are in the gitignored `.env` for local
runs; never print or commit them.

## Pins

`Cargo.lock` and the flake's `crane`, `rust-overlay`, `microvm`,
`llm-agents` and `advisory-db` move by themselves. Each night
`.github/workflows/pins.yml` runs `nix run .#update-pins`
(`scripts/update-pins.sh`): a commit each, crates only to releases out for
seven days, and what `nix flake check --impure` passes is pushed to main.
What it drops is in the issue "Pins that stayed". So main may have moved
overnight: pull before pushing. A fix that can't wait its seven days is
taken by hand, `cargo update --package <name> --precise <version>`. The
nixpkgs revisions, `rust-toolchain.toml` and `Cargo.toml`'s ranges move by
hand. Why is in
[docs/decisions/pins-move-nightly.md](docs/decisions/pins-move-nightly.md).

## Toolchain

Stable Rust, edition 2024. `rust-toolchain.toml` pins an exact version
rather than a floating `stable`, and crane and the dev shell build with the
same one; bump it in a commit of its own. No nightly: every nightly feature
the design might want has a stable alternative.

- Async drop: not wanted; see [How resources end](docs/design/lifetimes.md#how-resources-end).
- `async fn` in traits: stable. Where `dyn` is needed (the tool registry),
  the method returns `Pin<Box<dyn Future + Send>>`; no
  `impl_trait_in_assoc_type`.
- `gen` and `try` blocks: not needed.
- rustfmt: the default stable formatting, no import grouping options.
- Tools that need nightly (cargo-udeps) stay out of CI; cargo-machete
  instead.

## Reviewability

- Direct dependencies are declared in `[workspace.dependencies]` in the
  root `Cargo.toml`. A new dependency comes in a commit of its own, which
  gives the reason.
- cargo-deny checks licences, duplicate versions and sources; cargo-audit
  checks advisories against the advisory-db pinned in the flake, since the
  Nix sandbox has no network.
- Every commit is reviewable on its own: about 400 lines of hand-written
  change is the guide, not counting `Cargo.lock`, `.sqlx`, snapshots and
  fixtures; split by content, and a little over is fine. A commit does one
  thing, and compiles and passes the tests by itself.
- Few crates, split further only when needed; see
  [Crate layout](docs/architecture.md#crate-layout).
- No legacy or compatibility code: what is removed is removed completely.
- `timeout(` and `sleep(` appear only in the places listed in
  [Timeouts](docs/design/lifetimes.md#timeouts); `select!` loops hold only
  cancel-safe branches, see
  [Cancellation safety](docs/design/lifetimes.md#cancellation-safety).

## Testing

- All tests run with cargo-nextest.
- Tests keep to the critical path: what a mistake in wouldn't show by
  itself and would cost the most. That is the core's and intent's state
  machines, what the segmenter sends to the chat, what a request shows the
  model, the two protocols against recorded responses, the ledger's rows
  read back as written, one pass through the actor for each way a turn
  starts and ends, a program's call through the runner, and the checks that
  keep a guest in its `/work`, an API call under its base and a call with
  its own VM. The rest has none: a tool's own rules, the commands' wording,
  the workers, the VM service, the configuration's parsing. A change brings
  a test when it is of the first kind, not as a matter of course; why is in
  [docs/decisions/tests-on-the-critical-path.md](docs/decisions/tests-on-the-critical-path.md).
- The core and intent are tested without tokio or a fake provider. The
  actor is tested with a real database, a scripted model and a sender that
  only records, in real time; timeouts and graces elsewhere with tokio's
  `start_paused` (see [Testing](docs/design/actor.md#testing)).
- Database tests use `#[sqlx::test]`, a temporary database each. Locally
  they use the dev shell's Postgres (`devenv up`, port 5434, role and
  database `max`); the flake's nextest check starts its own, on TCP only.
- Prompt rendering uses insta snapshots.
- The codemode runner runs with Node locally against max's service, no VM
  needed.
- The platform layer uses recorded QQ gateway events as fixtures, with fake
  openids and AppIDs only.

## Documentation

`docs/` is laid out by kind (see [docs/README.md](docs/README.md)); keep
each kind in its place:

- **`docs/design/` says what is true now**, in the present tense, with no
  dates and no "until", "previously" or "changed on". When you change how
  something works, change its description in the same commit. A short "why"
  belongs there; the story of how it got so doesn't.
- **`docs/decisions/` says why**, one decision a file, named for what it
  decides (`own-llm-client.md`) and listed by subject in
  [docs/decisions/README.md](docs/decisions/README.md). It reads as any
  project's design note does: a line or two on what was decided, then
  Context, Decision, Why and Cost, with the alternatives that were looked
  at. It gives the reasons, not who decided or on which day, and what
  happened on the way only where that is a reason. Write one for a genuine
  trade-off, or when a design is replaced; link it from the design and add
  it to the index. A decision that a later one replaces stays, with a line
  pointing to the new one.
- **Open questions** go in an "Open" section at the end of their design
  file, not scattered through it.
- **`docs/research/`** is what was looked at; **`docs/archive/`** finished
  history (v1, go-live, the import). Neither is kept up to date.
- **`docs/rust-rewrite.md` is gone.** It was the single design document
  until 2026-11-15, and many comments in code, Nix files and migrations still
  name its sections (`See "Memory" in docs/rust-rewrite.md`). Where each
  section went is the table in `git show cee72765:docs/rust-rewrite.md`.
  When you touch such a comment, make it name the design file
  (`See "Memory" in docs/design/context.md`). Never edit a migration to
  update one: sqlx checks an applied migration's checksum.
  Changing a comment in a guest file (`nix/guest.nix`, the scripts and JS
  under `nix/`) changes the guest image, so leave those for a commit that
  changes the guest anyway.
