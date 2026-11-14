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
