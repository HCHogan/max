# ADR-009: Task browser workspaces, execution leases and explicit identities

Status: Implemented; real Docker/browser integration validation is a deployment gate.

## Decision

The browser host container is conversation-scoped. Each durable task owns a
separate workspace, including child tasks and every admitted monitor occurrence.
A foreground, non-task browse remains turn-scoped. A workspace is not a task
tree, account, conversation, or Playwright tab identifier.

`browser_workspaces` stores task/revision, physical generation, current execution
epoch, owner turn, runtime instance, state, last use and encrypted checkpoint.
The current attempt controls operations; it does not own the workspace lifetime.
The turn finalizer releases that control instead of destroying the task browser.

### Fencing and concurrency

1. A reference-counted, task-local lock covers admission, operation and checkpoint.
   Generations share the ownership lock, never a conversation-wide execution lock.
2. PostgreSQL checks current turn, task revision/attempt, lease, ancestors,
   cancellation and deadline before acquiring and beginning an operation.
3. The backend binds an increasing epoch and lease expiry. It checks at request
   admission and again when queued session work actually starts. Unbinding rejects
   old requests without closing a healthy page.
   The task heartbeat refreshes this lease during long calls; a stale refresh
   cannot resurrect an unbound epoch.
4. A durable `busy` marker precedes external work. Completion/checkpoint is CASed
   against the owner and epoch. A crash or interrupted mutating action leaves an
   uncertain workspace; acquiring a new attempt cannot silently erase that fact.
5. Transport reinitialization never retries the original MCP operation.
   Physical retirement requires backend closure acknowledgement. Failed closure
   remains fenced and is retried; it does not license another controller.

This is a single-Max-process runtime with restart recovery, not multi-host HA.
DB fencing cannot retract effects already sent to a website. Context isolation
also does not make two logins to the same server account independent.

### Lifetime

| Situation | Policy |
|---|---|
| Running, short retry, child wait | Keep the workspace, release execution control between attempts |
| Waiting/queued/retrying and idle | Default 30-minute idle retention |
| Succeeded/partial/failed | Default 5-minute grace period |
| Cancelled, budget exhausted, deadline | Revoke operations, close and erase checkpoint |
| Explicit replacement | Fence and close old generation; new revision starts without old identity/state |
| Steer | Preserve the workspace when still retained |
| Process restart | Reap old containers; cold-restore only safe durable state |
| `!clear --all` | Revoke existing task workspaces, including tasks not yet using a browser |

An independent worker runs every 15 seconds, skips busy workspace locks, rechecks
GC eligibility under the ownership lock and refreshes retained backend sessions.
The upstream 15-minute session timeout is a leak watchdog, not the Max idle TTL.
Cancellation/deadline fencing is immediate at the next operation boundary;
physical cleanup is asynchronous and cannot undo an in-flight external effect.

### Hot and cold recovery

Hot recovery preserves the live page only after a clean operation boundary and
while the same runtime still owns the browser. Cold recovery uses a new physical
generation and a new observation. It restores supported cookies/localStorage,
not DOM, JS stack, selectors, sessionStorage, IndexedDB, downloads or unsaved form
state. The tool reports cold recovery and requires navigation before actions.
There is no automatic click, submit, or navigation replay from an execution log.

Checkpoints are internal MCP results, never tool outputs or execution-journal
payloads. They use AES-256-GCM with a random nonce and task/profile-specific
authenticated identity. The 32-byte master key is an owner-only regular file,
created without overwriting an existing key. A wrong/missing replacement key does
not turn an unreadable checkpoint into an empty authenticated session.

### Explicit profiles

Only the task initiator can export or attach a saved identity. Being in the same
group, being a group administrator, a model suggestion, or a child task does not
grant access. Profiles are keyed by conversation, principal and explicit name.

Export takes a safe checkpoint and one HTTPS origin. It discards other origins
and unrelated cookies, narrowing parent-domain cookies to the selected host.
SSO involving multiple origins may therefore require a fresh login. Storage
remains encrypted and is never returned by the profile commands.

Attaching a profile copies a frozen identity into an isolated workspace; it does
not share pages or write changed cookies back to the profile. Explicitly attached
tasks may run concurrently, including monitor occurrences. Server-side account
state is still shared: application-specific conflicting writes need their own
resource coordination, not a browser-wide or conversation-wide lock. Revocation
or replacement of a profile fences all dependent workspaces.

Monitor profile bindings are explicit, owner-checked, and frozen into each new
occurrence snapshot. Updating a binding affects future occurrences only; revoked
versions fail closed, rather than adopting a newer login implicitly.

## User interface

```
!browser profiles
!browser save task#12 work-account https://example.com
!browser use task#13 work-account
!browser monitor m#4 work-account
!browser unmonitor m#4
!browser delete work-account
!browser reset task#13
```

`reset` confirms that the user has reconciled any uncertain external effects. It
closes the previous generation and discards its saved state/profile binding; it
does not replay the previous action or automatically resume the task. Use
`!task steer task#13 ...` to supply the reconciled result and continue. `use` is
also an explicit cold reset, followed by attachment of the selected profile.
Successful commands record operation, actor and target, without credentials.
Canonical command receipts deduplicate delivery retries. An interrupted command
is reported as unresolved instead of being silently executed again.
`!task status task#N` includes workspace state, generation, epoch and checkpoint
time, never checkpoint contents or saved credentials.

## Configuration and operations

`browser.state_key_file` defaults to `var/browser-state.key` under the service
working directory. Back up this key securely with the database; never commit it.
`browser.idle_seconds` defaults to 1800; `browser.grace_seconds` to 300. These three
settings require restart, preventing a reload from silently mixing policies or
keys. `browser.proxy` retains its existing worker-handoff behavior.

Migration 089 is additive to the already shipped 087/088 schema. Rebuild the
browser image together with Max: the workspace MCP protocol is required and a
stale image fails closed. Old task attempts have no workspace row until first
use; no legacy turn browser is adopted as an authenticated task workspace.

Validation covers DB ownership, epochs, interruption, cancellation, replacement,
retention, profile permissions/revocation and frozen monitor profiles; unit tests
cover lock ownership, encryption/restart, origin filtering and reload policy.
The pinned upstream TypeScript build and queued-operation fencing tests are
separate from a real Docker/Camoufox login-and-restart acceptance test.
