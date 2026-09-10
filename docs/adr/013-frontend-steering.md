# ADR 013: Frontend steering at model boundaries

Status: Accepted

## Decision

The first user message remains an initial context snapshot. Inputs received
while a frontend is working are appended as new user messages, after the
complete assistant/tool-result batch and before the next model request.
Native tools and `run_code` use this same boundary. A code submission runs to
completion; this change adds no guest checkpoints, interruption or replay.

An eligible conversational message from the current frontend's initiator can
enter its durable inbox. Explicit feedback and replies to that frontend's
trigger/output carry steering provenance; other eligible messages carry only
new-input provenance. The frontend decides their meaning. Another principal's
request keeps its own admission and authority context. `!btw`, task commands,
background attempts and notification reviews retain their separate routing.
An intent classification cannot merge obligations or grant authority.

## Ownership and settlement

Canonical messages remain the source of body, author, timestamp and reply
relation. Inbox rows store assignment, provenance, observation and tentative
disposition only. Reads preserve ingress order and do not settle requests.
The existing execution-inbox interpreter assembles their model view; Agent
does not acquire SQL access or route conversations itself.

`request_finish` still settles the original request. Its optional `inputs`
array explicitly assigns answered/waiting/declined to additional message IDs
the frontend has seen. Unlisted inputs remain pending and are dispatched
again after the frontend exits. Publication failure also retains those inputs.
Output receipts remain necessary for successful settlement.

The original trigger is not an inbox entry. For model compatibility, a
redundant original-trigger entry is normalized away only when its disposition
matches the top-level disposition. Conflicting or duplicate declarations and
unowned message IDs are rejected; normalization neither marks an input seen
nor expands the caller's scope. Equivalent retries with or without that
redundant entry share one immutable outcome.

Request validation, unseen-input and ownership rejections are returned before
any report write. The tool advertises this audited boundary so these returned
errors are classified as failed-before-effect, with distinct corrective
messages. Exceptions and timeouts remain outcome-unknown. A frontend that
exits without an explicit request outcome is failed, even if ordinary prose
was published; `waiting` is reserved for an explicit disposition. Debug
messages do not count as reply receipts. Historical rows are not rewritten.

`task_start` continues to delegate the original request. A separate question
that needs its own background task is left pending for the next frontend;
steering does not silently change a task's source message or owner.

Inbox admission, terminal intent and settlement share the conversation lock.
`request_finish` rejects an unseen input and lets the next model round read it.
Once a finish/delegation is committed, that frontend accepts no more input;
subsequent requests wait for the next frontend. A cancelled frontend cancels
its assigned inputs; an interrupted/recovered frontend re-observes them.

Plain prose that races a new input can be reconsidered only before visible
publication. Otherwise the pending input is handed to a later frontend. No
already-published text or completed tool effect is rewound.

## Validation

Cover ordered/provenance-preserving prompt assembly, complete tool-result
pairing in all protocol adapters, delayed input after `run_code`, scoped and
idempotent inbox admission, unseen-input/finish races, explicit per-input
settlement, recovery, cancellation and durable redispatch after failure.
