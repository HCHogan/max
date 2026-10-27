# Repository instructions

This branch (`rust`) is the Rust rewrite of Max. The design lives in
`docs/rust-rewrite.md` and is updated as decisions are made. The Haskell
version, with its docs and assets, is at tag `haskell-base`; bring a file
back with `git restore --source=haskell-base -- <path>` when the feature
that needs it is being built.

## Before every commit

Once the Cargo workspace exists, run from the repository root:

- `cargo fmt --check`
- `cargo clippy --all-targets -- -D warnings`
- `cargo nextest run`

Do not commit if any of them fails.

## Public repository

The repository is public. Use made-up QQ numbers, group ids and chat
handles in tests, docs and examples; real ones live only in sops.
