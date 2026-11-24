# Max has a Postgres cluster of its own

The NixOS module runs max's database in a Postgres cluster of its own, 19,
on a socket and nothing else. The dev shell and CI run the same build,
made with the same initdb arguments. The design is in
[NixOS](../design/config.md#nixos).

## Context

- max's database was one of several in the host's cluster. On tank that
  was Postgres 16, with the Haskell max's old database, Matrix's and a game
  server's; the module added its role and database to
  `services.postgresql`.
- What max asked of the cluster, everyone in it got: dropping pgvector
  restarted Postgres and the services on it, and a major version upgrade
  for one would be one for all.
- Three versions and two locales: the dev shell and CI ran 17, tank 16;
  CI's cluster was libc's C and tank's en_US.UTF-8, which differ in what
  `lower()` and pg_trgm make of anything but ASCII.
- tank's cluster lets every local user in as any role.
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
  `keywords::fold` does, and pg_trgm takes Chinese characters as a word's.
- **Only max's user reaches max's database**, and root.
- **19 rather than 18**: the data moved anyway, and 18 would have meant
  another move within the year.

## Cost

- **A unit to keep**: initdb, the configuration and the hardening, which
  NixOS's module did.
- **A second nixpkgs input**, until the release has 19, and a second
  Postgres on the host, with its memory.
- **A major version is a dump and a restore**, with max stopped.
- **19.0 was a week old.**
- **Moving to it is a dump and a restore**, with max stopped for minutes.

## Alternatives

- **The host's cluster**: nothing to keep, and everything above shared.
- **SQLite**: one file and no server, but 72 queries and 29 migrations to
  port, a full-text table beside each searched one, and nothing gained in
  what max can do.
- **Postgres 18**: in nixpkgs's release already and a year old, but a
  major version upgrade to come.
- **The whole flake on a nixpkgs with 19**: one input, but the guest's
  image and everything else would move with it, away from the release the
  host deploys with.
