# Background Jobs

The model-facing name is agent ([ADR-016](../adr/016-agent-tool-and-native-await.md)).
The `agent` tool takes an objective, capability profile and explicit inputs, and
optionally an output contract; only then must the final answer be matching JSON.
It returns an `agent#` handle immediately (old `task#N` handles still parse).
With `wait: true` it returns the finished agent instead, from the foreground or
a background agent; independent waits in one round run concurrently. Codemode's
`agent()` is the same call with `wait`. There is no idempotency key or finish
tool: a normal final answer completes the job.

Use `agent_list`/`agent_status` or `!agent list`/`!agent status agent#N` to
inspect work (`!task` remains an alias). `agent_steer` and
`!feedback agent#N <text>` append attributed feedback. The owner can cancel or
replace a job: `!agent cancel agent#N`, `!agent replace agent#N <new objective>`.
Replacement keeps its public handle, budget and deadline, revokes the old
generation and cancels its children. Background jobs may steer and await their
own children with `agent_wait`.

The initiating foreground reply does not own a detached job's lifetime. When a
root job finishes, its report goes back to the frontend. A later frontend turn
relays it to the requester; if that turn fails or stays silent, the report is
published as-is. Shutdown notices skip the frontend and are published directly,
as a reply to the request. A job owns its children and cancels them on exit. State, waits and browser sessions are
bounded and process-local. Graceful restart closes admission, cancels live Jobs,
and publishes an interruption notice for each root Job within the shared drain
deadline. Unpublished terminal results are also included. A hard crash or an
exhausted drain deadline can lose these notices; there is no post-crash Job
recovery or replay of uncertain actions. After restart, process-local Job handles
are no longer queryable. Job IDs are never reused. Historical task rows remain
available as evidence but are not used by scheduling.

Reminders retain definitions, frozen occurrence policy, provenance and minimal
trigger deduplication in PostgreSQL. One occurrence is admitted once. The Jobs
scheduler runs at most one occurrence of the same reminder at a time. Stable
observations control change-only notifications; generated wording does not.

Browser profiles are explicit retained data. `!browser save agent#N <name>
<https-origin>` exports allowed cookies/local storage; `!browser use agent#N
<name>` selects an owner-scoped saved profile. An uncertain action is never
replayed. Explicit `!browser reset agent#N` closes its old session before a new
session can start. `!clear --all` revokes browser access even for unopened jobs.
