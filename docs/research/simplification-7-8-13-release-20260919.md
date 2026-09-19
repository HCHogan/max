# Persistence and readability cutover: h610, 2026-09-19

Max `1cd113262c7ee478e7350c17218711806e64fa15` is running on h610, pinned by
nix-config `fd72a51499903136b0f09c8ca24982713f8d9031`. The package and NixOS
system were built on h610 with remote builders disabled. This completes
sections 7–8 and 13; it does not complete every acceptance or size goal in the
original plan.

The deployed package is
`/nix/store/98y0c26f6lk7j6j7pavd6pz99cwzhnvr-max-0.18.0`; the active system is
`/nix/store/9a9h5qi5sfsam337l7vjizk56ja51dx2-nixos-system-h610-26.05.20260911.21a67dc`.
The initial cutover used Max `ff6b079` and nix-config `ea6ed4b`. Acceptance
exposed the two pre-existing bugs described below; the final version includes
both corrections.

## Changes

Sections 7–8 remove monitor worker leases, persisted publication retries,
restart replay and the remaining operational-debt views. Definitions, frozen
trigger payloads/authority, deduplication, capacity limits, current-role checks
and publication outcomes remain. A canned reminder consumes its calendar edge
before publication; an uncertain result is not automatically sent again.
Startup ends unfinished work without reconstructing it.

Old successful reminder history did not consistently carry a finish time or
receipt. The new startup predicate preserves those records. New canned sends
write a start time, and retained pending triggers use their frozen text even
after the monitor definition changes. Both cases have database regressions.

Section 13 separates dispatch resource ownership from preparation, Agent
execution and publication. `LoopState` names the changing loop values;
`AgentOutcome` distinguishes complete, interrupted and failed results. Named
capabilities and SQL decoding replace long positional constructions. Tool
assembly has one production interpreter. Obsolete retry-classifier tests and
stale comments are removed; [architecture.md](../architecture.md) gives the
current entry points and ownership map.

## Validation and preservation

- All [release CI jobs](https://github.com/HCHogan/max/actions/runs/35437482226)
  pass. All Cabal components build. There are 1,043 passing unit examples and 267
  passing PostgreSQL examples; HLint, architecture capability checks, populated
  upgrade checks and generated prompt-flow checks pass.
- All 17 NixOS host configurations evaluate after retaining the concurrent
  nixvim changes. Only h610's system was deployed; Home Manager activation
  is separate.
- h610 built the package and ran `nixos-rebuild build` and `switch` itself,
  with one build job/core and remote builders disabled. No locally built closure
  or production database was transferred across borders.
- A verified 1,161,488,561-byte production dump was restored to the isolated
  `max_monitor124_rehearsal` database on h610. Migration 124 passed exact
  preservation checks for all monitor definitions, trigger history (excluding
  removed protocol columns) and messages. Obsolete lease helpers were absent.
- Candidate verification on the migrated snapshot passed structural and
  message-projection checks, then exited nonzero on the historical health
  counts below. It did not report a fully green operational gate.
- After stopping Max and its browser/sandbox resources, a second verified
  1,161,144,199-byte snapshot was written before activation. Both backups remain
  on h610. Shutdown does not remove users' sandbox volumes or browser profiles.
- The first switch completed at 10:02:45 UTC. Production reached migration 124
  with 61 ledger entries; the five monitor protocol columns, two debt views
  and lease functions are absent. All 29 pre-existing unfinished-shaped trigger
  records matched their preserved JSON exactly.
- Authenticated local overview passed. Both localhost and external HTTPS probes
  passed unauthorized overview (401), nonexistent-hook POST (401), unsupported
  GET (404) and the 64 KiB request limit (413). The external endpoint uses port
  8443.
- The new broker ran a disposable sandbox as uid 1000 in `/work`; host Max
  configuration and the Nix daemon socket were absent, and the Nix store was
  not writable. The disposable instance and volume were removed.
- The final version reports `1cd1132` through authenticated admin overview.
  Max, its runtime broker and NapCat are active with zero automatic restarts;
  three monitor definitions remain armed. HTTP and sandbox checks passed again
  against this version. Structural verification passes, while the historical
  health gate retains the stopped-writer counts below.

The first final-version switch activated the system and Max but returned exit
4: root's short-lived SSH session ended while NixOS was reloading its user
manager, closing the D-Bus connection. The journal confirms the user manager
was stopping at that instant. Repeating `nixos-rebuild switch` on h610 while
keeping the SSH session open completed with exit 0, including all user-manager
reloads. No persistent login or system configuration change was needed.

## Startup role-query correction

The 10:00 UTC occurrence of existing monitor 15 became due during maintenance.
At 10:02:53, its platform member query returned `no client connected`. The
pre-existing permission helper collapsed unknown authority into `TierMember`,
so the monitor was incorrectly expired as if its creator had lost permission.
This was a failed acceptance observation, not ordinary TTL expiration.

The correction distinguishes unknown roster state from a confirmed insufficient
role. A monitor leaves the trigger pending and waits five seconds before its
next read-only check; ordinary command authorization still fails closed.
There is no persisted retry state or restart continuation.

The affected definition was restored with unchanged creator, grants and goal;
its next calendar edge was moved to 10:30 UTC. Cancelled trigger 530 was retained
and was not replayed. A guarded comparison verified all 20 definitions against
the stopped snapshot, allowing only that recorded next-edge/update-time repair.
New regressions distinguish lookup failure, absent/ordinary members, the actual
administrator and an unrelated member's administrator role.

At 10:30:00 UTC the restored definition passed the real platform role check,
admitted ordinary Job 636 and advanced to its 11:00 edge. This was its natural
scheduled trigger, not a synthetic user message or a replay of cancelled fire
530. Job 636 completed successfully at 10:33:00 UTC. This observation used the
first deployed cutover binary.

## Ingest lock-order correction

CI exposed a PostgreSQL deadlock between concurrent ingestion and endpoint
registration: ingestion wrote a timeline revision before monitor admission
locked the conversation, while registration took those locks in reverse order.
A deterministic regression reproduced the deadlock on the old implementation.

Ingestion now locks the conversation before identity/message/timeline writes;
configured mirror registration follows the same order. The redundant late
monitor lock is removed. The regression completes without a deadlock after the
fix, and all 267 PostgreSQL examples pass locally, including concurrent
deduplication and mirror rebinding. No database migration or retry protocol was
added for this correction.

## Operational limits

Before activation, both the migrated snapshot and the running old service
reported 4 permanently failed deliveries and 3,058 unknown delivery outcomes.
The initial snapshot retained 3 unknown sandbox outcomes; while the old version
continued serving, that count reached 4. The stopped-writer baseline is 4,
3,058 and 4 respectively. No historical failure or uncertain effect was
relabelled or replayed to pass a health check.

The initial cutover CI's first sandbox-network attempt passed seven browser
scenarios, then failed to start a foreground browser workspace. The unchanged
test passed on rerun. The intermediate role-check correction also encountered
a browser startup failure; the final `1cd1132` CI passed on its first attempt.
Failure-only journal output was added to the test without weakening its checks.
A separate h610 probe also passed all nine real-browser scenarios,
including default-display startup, interruption and transport cleanup; it used
only an isolated fixture workspace, which was removed afterward. This is
evidence of a transient failure, not a diagnosed root cause or a test fix.

No production monitor, Alertmanager integration or user-facing test message was
created by this release. Reminder/Job behavior is covered by the database and
Agent suites, with the existing monitor's ordinary scheduled Job observed as
described above. This acceptance does not claim a new real-chat reminder or
model-quality comparison.

## Size and evidence

The core is **31,978 effective Haskell lines + 1,747 active SQL lines = 33,725**.
`src + app` is 44,806 lines; all owned production source plus active SQL is
53,914. Against `15316a9`, core size fell by 117 lines and `src + app` by 102.
Named records and readable decoding add lines while deleting execution
protocols removes them. Major features were preserved; the 10,000-line goal
remains unmet. See [code-size.md](../code-size.md).

Private backups and probe evidence remain on h610 under
`/var/lib/max/backups/simplification-7-8-13-20260919`. This report contains no
production message bodies or credentials.
