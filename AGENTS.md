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

## Background jobs

`tools.agent` is an MCP tool in `crates/max/src/mcp/agent.rs`, not one of
max-core's two model tools. Its checked `workdir` goes through
`job::Request::Start`, the conversation actor, and `job::Start` to
systemd-run's working directory. The harness's stdin contract stays at 1;
`nix/max-pi.sh` does not choose the directory. pi loads the project's
`AGENTS.md` or `CLAUDE.md` and its parents even with `--no-approve`, but
project `.pi/` configuration and extensions stay untrusted. Sessions and
reports stay in `/work/.max/jobs`. Keep project experience here; Max's
foreground memory only needs the project name, path and one-line summary.

After changing the wrapper or pi integration, run `scripts/check-pi-job`
in the dev shell as well. It uses the pinned pi and a fake host, without
real model calls, and covers steering, stopping, questions, cwd, context
files and project trust.

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
