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
forwarder" in docs/design/vm.md) outlives max as the VM does, and is as old as
its VM's boot. It reads the configuration the newest max names it, and
of that only `[llm]`, `[api]` and `[log]`
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
- Pure logic is tested with a fake provider and a fake platform; timeouts
  and graces with tokio's `start_paused` (the actor's tests use real time;
  see [Testing](docs/design/actor.md#testing)).
- Cancellation: the actor's tests insert `/kill` between every two events,
  and each I/O task is dropped once at every poll point (see
  [Cancellation safety](docs/design/lifetimes.md#cancellation-safety));
  normal-path tests assert that nothing was killed because its connection
  dropped, which catches a missed `close`.
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
- **`docs/decisions/` says why**, one decision a file, named
  `YYYY-MM-DD-what.md`: its context, the decision, why, and its cost. Write
  one for a genuine trade-off, or when a design is replaced, and link it
  from the design. A decision that a later one replaces stays, with a line
  pointing to the new one; don't edit history to match the present.
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
