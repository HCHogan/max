# Repository instructions

This is the Rust rewrite of Max, on `main` since 2026-10-31. The design lives in
`docs/rust-rewrite.md` and is updated as decisions are made. The Haskell
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

After moving pi's pin, or changing `nix/max-pi.sh`, `nix/max-agent.ts` or
`nix/agent-system.md`, run `scripts/check-pi-job` in the dev shell as
well. It runs the pinned pi against a fake `/llm`, without real model
calls. `nix/max-agent.sh`, which starts an agent as a unit, is covered
with the guest's jobs, below.

## The guest's jobs

After changing `nix/max-jobs.sh`, `nix/max-agent.sh`, `nix/max-units.sh`,
`nix/maxx.nix`, `nix/local.json` or `nix/jobs.nix`, build
`.#checks.<system>.jobs` for a Linux system (`aarch64-linux` on a Mac
with a Linux builder): a NixOS test of what Max runs in a VM as units,
with no VM inside it. What the host makes of a call's line is in
`crates/max/src/tools.rs`; the two meet only in `max vm-check` and the
nested test, `.#nestedChecks.x86_64-linux.vm`, which needs nested KVM
and runs on tank.

## The contract with a guest

A VM outlives max, so a new max meets guests an older one booted. Raise
the number in `nix/contract.nix` with any change to what the two say to
each other: the arguments of what max runs with `maxx`, or the line a
call prints, the layout of `/run/max/jobs`, the runner's input, the
routes a guest calls. A VM
whose guest keeps another number is restarted when max attaches to it;
one with the same number runs on. A change an older guest goes on
working with, such as a field more in what a route answers, needs no new
number.

A VM's forwarder (`max forward`, a unit beside the VM's, see "A VM's
forwarder" in the design) outlives max as the VM does, and is as old as
its VM's boot. It reads the configuration the newest max names it, and
of that only `[database]`, `[llm]`, `[api]` and `[log]`
(`config::Forwarded`): a key added to those is one an older forwarder
can't read, and it goes on with the configuration it had until its VM
boots again. Raise the number too when the forwarders must be new at
once: with a change to what a forwarder and max say to each other
(`max.sock`, the link `forward.config`, the routes passed on), or to
those parts of the configuration that the ones that run mustn't go on
without. Its tests are `crates/max/src/forwarder/tests.rs` and the
nested test.

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

## Toolchain

Stable, edition 2024 (decided 2026-10-27). `rust-toolchain.toml` pins a specific version number rather than a floating `stable`; crane and devenv in Nix use the same version. Upgrades are committed separately.

Nightly is not used. Every nightly feature that this design might want has a stable alternative:

- async drop: decided against; see [How resources end](docs/design/lifetimes.md#how-resources-end).
- `async fn` in traits: stable since 1.75. Where `dyn` is needed (the tool registry), the method returns `Pin<Box<dyn Future + Send>>`; `impl_trait_in_assoc_type` is not used.
- `gen` blocks and `try` blocks: not needed.
- rustfmt's import grouping options: the default stable formatting is used.
- Tools that require nightly (cargo-udeps) are kept out of CI; cargo-machete is used instead.

# Reviewability constraints

- Direct dependencies are declared centrally in `[workspace.dependencies]` in the workspace root's `Cargo.toml`. A new dependency is added in a commit of its own, and the commit gives the reason.
- cargo-deny checks licences, duplicate versions and sources; security advisories are checked with cargo-audit against the advisory-db pinned in the flake, since the Nix build sandbox has no network.
- Every commit must be reviewable on its own (decided 2026-10-27): about 400 lines of hand-written changes is the guide, not counting `Cargo.lock`, `.sqlx`, snapshots and fixtures; changes are split sensibly by content, and going slightly over is acceptable (relaxed 2026-10-28). A commit does one thing, and it compiles and passes the tests when taken on its own.
- The number of crates is kept small, and crates are split further only when needed. The initial layout is described in [Crate layout](docs/architecture.md#crate-layout).
- No legacy or compatibility code is written: when something is removed, it is removed completely.
- ADRs record only genuine trade-offs.
- `timeout(` and `sleep(` appear only in the places listed in [Timeouts](docs/design/lifetimes.md#timeouts); `select!` loops contain only cancel-safe branches, see [Cancellation safety](docs/design/lifetimes.md#cancellation-safety).

# Testing

- All tests are run with cargo-nextest.
- Pure logic is tested with a fake provider and a fake platform; timeouts and grace periods use tokio's `start_paused`.
- Cancellation: the conversation actor has a `/kill` inserted between any two events, and each I/O task is dropped once at every poll point, see [Cancellation safety](docs/design/lifetimes.md#cancellation-safety); tests of the normal path assert that no resource was killed because its connection was dropped, which catches missed calls to `close`.
- Database tests use `#[sqlx::test]`, with a temporary database per test. Locally they use the Postgres started by `devenv up` in the dev shell (port 5434, with both the role and the database named `max`); the flake's nextest check starts its own temporary Postgres, listening only on TCP.
- Prompt rendering uses insta snapshots. Whether they replace the documentation generated by `max-prompt-flow` is **TBD**.
- The codemode runner runs node locally against max's service and needs no VM.
- The platform layer uses recorded QQ gateway events as fixtures. Fixtures use only fake openids and AppIDs.
