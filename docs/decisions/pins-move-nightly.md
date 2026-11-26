# The pins move by themselves each night

A nightly workflow moves `Cargo.lock` and the flake's inputs, checks them
as CI checks a push, and pushes what passes to main. nix-config's updater
on tank then moves its `maxx` input to max's main, behind tank's build and
the nested VM test. Nobody opens or reads a pull request for either.

## Context

A pin moved only when someone moved it. Four weeks after the last time,
`cargo update` had 84 entries of `Cargo.lock` to change, every one within
`Cargo.toml`'s ranges, and crane, microvm and the advisory database were
as old. The `audit` check reads the advisory database from its pin, since
a build has no network: against that day's database the lock had two
advisories the check did not report, and nothing else was there to report
them.

What tank runs was already tested each night in part. nix-config's `maxx`
input follows nix-config's nixpkgs, which its updater moves, so a new
nixpkgs rebuilds max and the guest's image and runs max's nested VM test
before it is pushed. max's own pins were outside that.

## Decision

`scripts/update-pins.sh`, the flake's `update-pins`, moves on top of main,
a commit each:

- `Cargo.lock`, as `cargo update` does, but only to releases that have
  been out for seven days;
- the flake's `crane`, `rust-overlay`, `microvm`, `llm-agents` and
  `advisory-db`.

Then it runs the gate, `nix flake check --impure`. When that fails with
them all, each is moved alone on the ones kept, and one the gate fails
with is dropped. `.github/workflows/pins.yml` runs it at 13:17 UTC, pushes
what was kept as GitHub Actions' bot, and keeps one issue, "Pins that
stayed", of what was dropped and the gate's last lines; the first night
nothing is dropped closes it.

By hand still: the two nixpkgs revisions, which are the one nix-config
deploys with and the one that has Postgres 19; `rust-toolchain.toml`,
whose new lints want code changed; devenv's tag; and a range in
`Cargo.toml`, a new major version above all.

nix-config's updater has `maxx` among the inputs it moves. What it pushes
has built tank's system, which checks tank's own configuration with
`max check-config`, and passed `maxvm-tank`. A deploy is still someone's
switch.

## Why

- **No pull requests.** Work here goes to main once the checks pass, and
  the gate is those checks. A pull request a night, each with CI's whole
  run, would be read by nobody.
- **Seven days.** The gate stops a release that breaks max. It doesn't
  stop one made to do harm, and max's process holds the providers' keys,
  the database and the bot's credentials. Such releases are mostly found
  and yanked within days, and a yanked one is never taken. crates.io's
  index says when each version came out; cargo's own `min-publish-age` is
  unstable, so the script steps a release that is too new back to the
  newest one old enough.
- **A database the gate fails with is reported.** When the newer
  `advisory-db` fails `audit`, the pin stays, so a push's CI stays as
  reproducible as before, and the issue says which advisory: that is the
  news, and by hand is how a fix younger than seven days is taken.
- **The guest's pins move too.** `microvm` and `llm-agents` change the
  guest's image. The gate has `fx` for what `nix/fx.sh` rests on, `jobs`
  for what surrounds it, and `guest-evaluates`, which says only that the
  image still evaluates. That it builds and boots is checked on tank, by
  its system's build and the nested test, before `maxx` moves. A deploy
  after one stops the VMs that run, which boot the new image when next
  needed; with the few conversations there are, that is a price worth not
  carrying month-old pins.
- **On GitHub, and tank after it.** CI's checks already run on GitHub's
  runners, and the workflow's own token can push, so nothing is installed
  and no secret is kept. The nested test needs KVM inside a VM, which only
  tank gives: it runs where `maxx` moves, so nothing reaches tank's
  configuration without it.

## Cost

- A fix for an advisory waits out its seven days unless someone takes it
  by hand.
- A release that passes the gate and misbehaves where no test looks is on
  main unread. What stands between it and the chats is the seven days and
  whoever switches tank.
- The night's commits get no CI run of their own: a push with the
  workflow's token starts no workflow. The workflow ran the same checks
  on them before pushing.
- fx can move a version in a night, and its releases break things. The
  `fx` check covers what the wrapper rests on, not everything an agent
  does with fx.
- More deploys change the guest's image, and so restart the VMs.
- A pin the guest's image no longer builds or boots with gets to max's
  main: the gate doesn't build the image. tank's updater then leaves
  `maxx` where it is and says so in nix-config's issue, and nothing of
  max moves there until the pin is put back or the guest fixed.

## Alternatives

- **Dependabot or Renovate.** They open pull requests, which this
  repository doesn't work by, and Dependabot's alerts alone would report
  advisories but move nothing.
- **A timer on tank for max's pins as well.** It could run the nested test
  before a pin reaches max's main rather than before it reaches tank. It
  needs a GitHub App installed on this repository, its key on tank and a
  module in nix-config, for a test that runs on tank the same night anyway.
- **nix-config's inputs in place of max's**, with `follows`. `Cargo.lock`
  has no such thing, and max's CI would test pins other than the ones
  deployed.
- **No waiting.** Simpler by sixty lines, and the newest release of any of
  four hundred crates would be on main the night it came out.
