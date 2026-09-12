# ADR-015: Delegated agents inside workflows

Status: Mechanism implemented in the isolated `feat/issue-22-delegated-workflows`
worktree, 2026-09-12. Behavioral gates passed; performance acceptance remains open.
Not deployed. The historical inspection below explains the motivation;
local correctness and live-model measurements are reported separately under
Acceptance. Historical counts alone do not establish a fan-out performance gain.

Builds on [ADR-008](008-durable-tasks-conversation-coordination.md), which retired
the model-authored Plan DSL and kept durable addressable tasks, and
[ADR-014](014-versioned-skill-workflows.md), which added versioned JavaScript
workflows over tools. It does not reopen ADR-002 or ADR-007.

## Context

The delegation surface is complete and almost unused. Ten days of production tool
calls:

| Tool | Calls |
|---|---|
| `use_skill` | 163 |
| `run_code` | 39 |
| `task_status` | 26 |
| `task_start` | 13 |
| `task_list` | 8 |
| `task_steer` | 1 |
| `task_replace`, `task_cancel` | 0 |

The model delegates about 1.3 times a day and queries status twice as often as it
delegates. The task table shows where the work actually comes from:

| Profile | Tasks | Nested children | From monitors | Model-initiated |
|---|---|---|---|---|
| operations | 114 | 51 | 47 | about 16 |
| research | 54 | 0 | 52 | 2 |
| sandbox | 4 | 0 | 0 | 4 |

Every one of the 51 nested tasks is a host-created maxops job observer, not model
fan-out. Research tasks have never spawned a child. ADR-008's "multiple bounded
tasks may work concurrently behind it" has not occurred in production.

The failure mode of research tasks is the one that fan-out addresses:

| Status | Count | Mean tool calls | Mean elapsed | Deadline |
|---|---|---|---|---|
| budget_exhausted | 32 | 19.8 | 81.3 min | 50 min |
| succeeded | 17 | 18.1 | 11.6 min | |

The original sample suggested wall-clock pressure despite low tool/round usage.
A follow-up inspection changes how strongly that can be interpreted: all seventeen
successful research-profile tasks and thirty of the thirty-two exhausted tasks
were monitor-created. The profile name does not mean these were independent
open-ended research objectives. Elapsed time includes queue/recovery delay, and
there is no direct turn foreign key on historical `llm_calls`. The counts do not
isolate model latency as the cause of the deadline failures.

The current task-tree deadline is six hours (`Max.Task.Policy`), not the historical
fifty-minute cap. Raising it has already changed that deployment condition.
Consequently a controlled source-research comparison must state its own deadline,
model, load assumptions and completion criteria; it must not be presented as a
reproduction of the historical incident.

### The missing primitive

The two halves of the system do not compose. A workflow composes tools:
`tools.<name>()` calls one, `max.batch` submits one to thirty-two and lets the host
choose concurrency. A task composes nothing. There is no primitive that starts a
model-driven subtask and awaits its result. `task_start` is reachable from a
workflow, but it returns on admission, and ADR-014 states there is no nested
workflow execution and no background resumption, and that `Finish`/`Yield` stops
the whole program. A workflow can fire a task; it cannot join one.

### What ADR-008 actually retired

ADR-008 listed four costs of the model-authored planning programme: learn a
dialect, choose schemas and detailed budgets up front, write the combining
expression before seeing any result, and rewrite the whole plan to change work.
Those are properties of a bespoke DSL, not of deterministic orchestration.
ADR-014 already re-adopted orchestration in a language the model knows. What is
missing is that the orchestrated unit is a tool rather than an agent.

Comparable systems make the orchestrated unit an agent, give it an optional output
contract, run the script in the background, and cache settled steps so that editing
the script re-runs only what changed. That last property is what removes the fourth
cost: a changed program is not a discarded run.

## Decision

Add a delegated-agent primitive to the existing workflow SDK. Do not add a planning
language, a second scheduler, or a second authority.

### `agent()` in the codemode SDK

A workflow may start a bounded child task under the current authority ceiling and
await its report. The call takes an objective, bounded inputs, a host-defined
capability profile, and an optional output contract drawn from ADR-014's closed
schema vocabulary. It returns the child's normalized report: status, findings,
evidence references, unresolved issues, and the validated payload when a contract
was given.

Declaring a profile requests capability; it never grants it. The child ceiling is
the intersection of the parent task's ceiling, current policy, and the requested
profile, exactly as ADR-008 already specifies for descendants. A child report is
data, never an instruction to the parent or the frontend.

Concurrency follows the existing `max.batch` rule: the guest expresses independence,
the host decides whether to run calls concurrently. ADR-008's reservation accounting
already prevents siblings from each spending the same remaining allowance; that
accounting must cover awaited children, not only settled usage.

### Per-step resume

Each `agent()` call records two identities. The journal step key includes the
whole workflow-source fingerprint and normalized arguments, preserving exactly
which program submitted it. The durable reuse key includes the normalized agent
request, loaded skill receipts, JavaScript runtime identity, and effective child
grants, scoped to the parent task revision.

This distinction resolves a conflict in the original proposal: including the whole
source in the sole reuse key would invalidate *every* call when one step changed.
With separate identities, an unchanged semantic call reuses its settled child
report even when another step is edited; changed arguments, receipts, runtime or
grants admit a different child. Publishing an edited saved skill changes its
receipt and invalidates its calls; editing raw code under unchanged parent skill
receipts allows partial reuse. Every reuse is journaled with `reused: true` and
`original_execution`; the original child is not executed again.

This is a resume mechanism for a single task's own program, not whole-program retry
of committed effects. A cached step is a previously settled child report. A step
whose key changed is a new child, admitted and journaled as one. Cancellation,
fencing and revision checks are unchanged, and a cached result from an invalidated
generation is never reused.

### Progress and steering

Phase labels in the program map to the existing `task_progress` boundary so a long
run reports which stage it is in rather than going silent. Steering keeps ADR-013
semantics; the addition is that a steer arriving between two `agent()` calls is
observed at that boundary rather than only after the whole program completes.

### Boundaries

- No new authority. A workflow that can call `agent()` gains nothing it could not
  already reach through the task surface.
- The output contract validates shape, never success. ADR-008's distinction between
  candidate output and verified completion is unchanged.
- No recursive workflow execution. A child task runs the ordinary agent loop; it
  does not host another guest program in this batch.
- Budget names stay distinct. Awaited children consume the parent's descendant
  allowance; awaiting is not free and is not modelled as zero.

## Alternatives considered

**Raise the research deadline.** Does not address a six-round serial task at
roughly eight minutes a round; it converts timeouts into longer timeouts.

**Revive the Plan DSL.** Rejected by ADR-008 and nothing in this evidence disputes
that decision. This proposal keeps ordinary tool calling as the default and adds one
primitive to a language the model already writes.

**Adopt an external workflow engine.** Would duplicate admission, authority
intersection, fencing and the journal, which are the parts of the current design
that work.

**Do nothing.** Defensible if delegation stays rare by preference rather than by
friction. The 13 `task_start` calls against 26 `task_status` calls and 1 `task_steer`
call suggest friction, but that is an inference, not a measurement of intent.

## Acceptance

The behavioral gates below are required. The original performance hypothesis is
measured separately rather than inferred from those gates:

- A research objective that currently exceeds its deadline completes within it when
  expressed as independent children, measured on the same model and load.
- A child is admitted with the intersected ceiling, and a profile requesting more
  than the parent holds is rejected before any child effect.
- Reservation accounting prevents two awaited siblings from both spending the last
  of a descendant allowance.
- Editing one step of a program re-runs that step and reuses the rest, with reuse
  visible in the journal and no replay of committed child effects.
- A cancelled or superseded generation never serves a cached step.
- A steer submitted mid-run is observed at the next `agent()` boundary.

Fan-out that merely multiplies model calls without improving completion is a
regression. Measure completion rate and wall-clock first, tokens second.

The [2026-09-12 evaluation](../research/adr015-delegation-evaluation.md) records all
final measurements: parallel completion 1/2, serial 0/2 and ordinary single-agent
0/1 under a predeclared 300-second deadline. Eleven workflow DB tests pass the
behavioral gates, including recursive descendant containment. One parallel success
does not satisfy the same-load performance criterion: load was uncontrolled and
missing model checkpoints caused failures in every mode. Ordinary tool calling
therefore remains the default; this ADR does not claim a proven performance gain.

## Implementation boundaries

- Awaiting starts only inside a live root durable task with `task_start` authority.
  Frontend workflows retain their existing yield behavior. Awaited children run
  the ordinary agent loop; `run_code` is rejected throughout their descendant
  subtree, including after attempt recovery. Existing ordinary task APIs retain their own semantics.
- Migration 111 stores child identities/reports and currently waiting parent
  attempts. These are joins over ordinary tasks, not a new queue or scheduler.
  The task scheduler excludes an awaiting parent from its active capacity counts;
  deleting the wait restores normal counting. Attempt/lease fencing makes stale
  waits inert. No DB transaction is held while a child executes.
- `max.batch([{agent: ...}, ...])` expresses independence; the host overlaps only
  agent waits in an agent-only batch. Mixed native/agent batches retain sequential
  execution and native tools retain their existing catalog parallelism rules.
  Every submitted agent consumes a tool-call reservation, including cached reuse;
  child calls and model rounds charge the shared root allowance. Phase checkpoints
  follow the existing zero-work-call progress accounting.
- `agent()` returns `status`, `findings`, `evidence`, `unresolved`, `payload`, and
  `payload_valid`, plus task/reuse provenance. A succeeded task with a requested
  output contract must supply a valid payload at `task_finish`. Other statuses may
  omit it; if present it is still validated. Shape never promotes partial/failed
  work to success.
- A waiting child report is returned as waiting data and is not cached. Cancelled
  child reports are not cached. A changed child revision or invalid parent
  authority rejects reuse. Pending steering stops the guest at the next agent
  boundary (and interrupts an outstanding wait); the parent loop then reads the
  unchanged durable inbox. JavaScript cannot catch that host stop and continue.
- Authoring fixtures may declare `agent` and `phase` calls when the workflow
  declares `task_start` and `task_progress`. Validation consumes fixture data only;
  it has no production child admission callback or database access.

See [the SDK](../../skills/codemode.md),
[DB integration tests](../../test-db/Max/WorkflowAgentSpec.hs), and
[the live evaluator](../../workflow-eval/README.md).
