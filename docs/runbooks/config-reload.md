# Configuration reload

Max can apply configuration changes without replacing its process or the
accepted NapCat reverse-WebSocket connection:

```console
sudo systemctl reload max
```

The command is synchronous. `systemd` runs `maxctl reload`, which sends a
versioned request over `/run/max/control.sock` and exits successfully only after
the running Max process has parsed, validated, prepared, and published the new
generation. A rejected candidate leaves the previous generation active and
makes the command fail.

## What stays connected

The OneBot listener, accepted WebSocket, client slot, database pool, durable
registries, and process PID are outside the reloadable worker supervisor. A
configuration reload therefore does not create `EvConnectionReady`, increment
the OneBot connection generation, schedule QQ history backfill, or introduce a
NapCat offline interval. The event consumer is process-owned too: frames
arriving while a candidate is prepared remain admitted to its queue, and a
worker-generation handoff cannot cancel a frame between dequeue and durable
canonical ingest.

Every dispatch atomically acquires both a shutdown slot and one immutable
configuration lease. A generation-N turn retains its persona, model catalog,
tool gates, endpoint resources, browser proxy, and silence policy until its
outer finalizer. Dispatches admitted after publication receive generation
N+1. Superseded snapshots and credentials are collected after their last lease.

## Reloadable fields

The following classes use the transactional worker/resource handoff:

- prompt, persona, authorization, debug/sticker defaults, timezone, turn
  silence, LLM profiles, search, CLIProxy, browser proxy, and log level;
- image worker count and shutdown drain timeout;
- embedding, caption, historian, intent, and retention workers;
- Matrix, iMessage, WeChatHook, delivery routing, and the admin listener.

Preparation creates generation-owned clients and a start-gated worker set.
Changed admin and WeChat listener addresses are also resolved and test-bound
before publication; an occupied address rejects the candidate while the old
generation remains active. An unchanged address is proven by the active
listener itself.
Publication makes the value snapshot, resource routing, and new-worker gate
visible in one STM transaction. Old DB-claimed workers can overlap briefly and
remain protected by their existing ownership/attempt fencing. Cursor-backed
ingress resumes from its durable cursor. Listener changes may have a short
close/bind gap; only the QQ connection is claimed to be uninterrupted.

These changes still require a restart, and any one of them rejects the whole
candidate:

- OneBot host, port, path, or access token;
- database URL/pool size, migration directory, or image directory;
- log colour (the renderer is process-owned).

Binary/package, unit sandbox, and environment changes also remain restarts.
`systemctl reload` reuses the process environment; changing an
`EnvironmentFile` requires a restart.

## NixOS behavior

The NixOS module starts Max with `/etc/max/config.yaml`. For
`services.max.settings`, activation updates that stable symlink and
`reloadTriggers` invokes the synchronous control command. A package change
alters `ExecStart`/`ExecReload` and systemd restarts the service instead.

A hand-managed mutable `services.max.configFile` has no Nix content hash that
can announce an out-of-band edit. After updating it, run `systemctl reload max`
explicitly. Secret rotation through `EnvironmentFile` is restart-only.

## Diagnostics

Successful output names the old/new generation and changed fields. Rejections
name only field paths and a stable error category; configuration values,
personas, tokens, and credential-bearing URLs are never returned or logged.

Useful checks:

```console
systemctl reload max
systemctl show max -p MainPID
journalctl -u max -o cat --since -5m | grep 'configuration reload'
```

If the candidate is invalid or contains a restart-only change, fix it or use
`systemctl restart max`. The healthy old process does not need recovery.
