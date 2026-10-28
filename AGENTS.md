# Repository instructions

This branch (`maxx`) is the Rust rewrite of Max. The design lives in
`docs/rust-rewrite.md` and is updated as decisions are made. The Haskell
version, with its docs and assets, is at tag `haskell-base`; bring a file
back with `git restore --source=haskell-base -- <path>` when the feature
that needs it is being built.

## Before every commit

In the dev shell (`nix develop --impure`, or direnv), from the repository
root:

- `cargo fmt --check`
- `cargo clippy --all-targets -- -D warnings`
- `cargo nextest run --no-tests=warn`

Do not commit if any of them fails. `nix flake check --impure` runs these
and the rest of CI's checks: cargo-deny, cargo-audit, cargo-machete,
max-core's dependency allow list, max-core built alone, and the package.

The dev shell's Postgres (port 5434, database `max`) runs under `devenv up`;
without a terminal, start it with `PC_TUI_ENABLED=0 devenv up`.

## Public repository

The repository is public. Use made-up QQ numbers, group ids and chat
handles in tests, docs and examples; real ones live only in sops.
