# Max has a Postgres cluster of its own

The NixOS module runs max's database in a Postgres cluster of its own,
19, on a socket and nothing else. The dev shell and CI run the same
build, made with the same initdb arguments. The design is in
[NixOS](../design/config.md#nixos).

## Context

A host usually has one Postgres cluster for everything on it. On tank
that cluster holds Matrix's database and a game server's among others,
and lets every local user in as any role. In a shared cluster:

- What one database asks of the cluster, everyone in it gets: an
  extension added or dropped restarts Postgres and the services on it,
  and a major version upgrade for one is one for all.
- The version and the locale are the host's: the dev shell and CI then
  run another Postgres than production, and libc's C and en_US.UTF-8
  differ in what `lower()` and pg_trgm make of anything but ASCII.
- A physical backup, of the files and the WAL, is a whole cluster's: with
  others in it, theirs too.

## Decision

- **A cluster of max's own**, `<name>-postgres.service`: its own system
  user and data directory, a socket in `/run/<name>-postgres`, no TCP,
  peer authentication. max's role owns its database and is no superuser.
- **The flake's Postgres everywhere**: `packages.postgresql`, 19, is the
  module's default, the dev shell's and CI's. It comes from a nixpkgs
  input of its own while nixpkgs's release has no 19.
- **One initdb**: `nix/initdb.nix`, the builtin provider's C.UTF-8.
- **Major versions by hand**: no version in the data directory's name,
  and Postgres refuses another major version's data, so a new one stops
  rather than start an empty cluster beside the old.

## Why

- **What changes for max touches max alone**, and what the host changes
  for others leaves max alone.
- **What is tested is what runs**: the same build and locale in the dev
  shell, CI and production.
- **The builtin locale is Postgres's own**: the same results on macOS and
  Linux, with any glibc; `lower()` maps letters by Unicode, as
  `keywords::fold` does, and pg_trgm takes Chinese characters as a
  word's.
- **Only max's user reaches max's database**, and root.

## Cost

- **A unit to keep**: initdb, the configuration and the hardening, which
  NixOS's module would do.
- **A second nixpkgs input**, until the release has 19, and a second
  Postgres on the host, with its memory.
- **A major version is a dump and a restore**, with max stopped.

## Alternatives

- **The host's cluster**: nothing to keep, and everything above shared.
- **SQLite**: one file and no server, but 72 queries and 29 migrations to
  port, a full-text table beside each searched one, and nothing gained in
  what max can do.
- **Postgres 18**: in nixpkgs's release already, but a major version
  upgrade to come within the year.
- **The whole flake on a nixpkgs with 19**: one input, but the guest's
  image and everything else would move with it, away from the release the
  host deploys with.
