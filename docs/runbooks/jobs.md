# Background Jobs

`task_start` takes an objective, capability profile and explicit inputs. It
returns a `task#` handle immediately. There is no idempotency key or finish tool:
a normal final answer completes the job. `agent()` may specify an output contract;
only then must the final answer be matching JSON.

Use `task_list`/`task_status` or `!task list`/`!task status task#N` to inspect work.
`task_steer` and `!feedback task#N <text>` append attributed feedback. The owner
can cancel or replace a job: `!task cancel task#N`,
`!task replace task#N <new objective>`. Replacement keeps its public handle,
budget and deadline, revokes the old generation and cancels its children.
Background jobs may steer and await their own children with `task_wait`.

The initiating foreground reply does not own a detached job's lifetime. A job
owns its children and cancels them on exit. State, waits and browser sessions are
bounded and process-local. Restart interrupts work; it does not resume it or
retry uncertain actions. Job IDs are never reused. Historical task rows remain
available as evidence but are not used by scheduling.

Reminders retain definitions, frozen occurrence policy, provenance and minimal
trigger deduplication in PostgreSQL. One occurrence is admitted once. The Jobs
scheduler runs at most one occurrence of the same reminder at a time. Stable
observations control change-only notifications; generated wording does not.

Browser profiles are explicit retained data. `!browser save task#N <name>
<https-origin>` exports allowed cookies/local storage; `!browser use task#N
<name>` selects an owner-scoped saved profile. An uncertain action is never
replayed. Explicit `!browser reset task#N` closes its old session before a new
session can start. `!clear --all` revokes browser access even for unopened jobs.
