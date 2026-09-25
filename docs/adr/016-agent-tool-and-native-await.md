# ADR-016: One agent tool, native await, and foreground waits

Status: implemented 2026-09-26. Amends [ADR-015](015-delegated-agents-in-workflows.md).

## Context

ADR-015 gave codemode an `agent()` host primitive (`host:workflow_agent/v1`)
next to the model's `task_start` tool. The two diverged: `agent()` had its own
argument shape (`inputs`, `output_contract`), its own admission path, a host
batch for concurrency, and ran only inside a root background task. In the 30
days before this change production ran 205 codemode programs and no
`agent()` call at all, while `task_start` was used directly. The name "task"
also described the wrong thing: what starts is another agent with its own
model loop, tools and report.

The SDK's calls were synchronous. `__maxCall` blocked the Wasm instance until
the host answered, so `await Promise.all([...])` ran one call after another and
concurrency needed `max.batch`, a second way to spell a call.

## Decision

**One tool.** The model-visible family is renamed: `agent`, `agent_status`,
`agent_list`, `agent_steer`, `agent_replace`, `agent_cancel`, `agent_wait`,
`agent_progress`, with `agent#N` handles (`task#N` still parses). `agent` takes
the union of both old shapes (`objective`, `profile`, `context`, `resources`,
`inputs`, `output_contract`) plus `wait`. Without `wait` it returns at once, as
before. With `wait` the same call returns the finished agent. Its metadata is
`ParallelIndependent` with a six-hour deadline, so independent waiting calls in
one round, native or in code, run together.

**agent() is the tool.** In the SDK, `agent(args)` is `tools.agent({...args,
wait: true})` and `max.phase` is `tools.agent_progress`. The host primitive,
its host batch and the per-call source-fingerprint enrichment are gone; agent
calls journal, budget and authorize exactly like any tool.

**Native await.** SDK calls return pending promises and only queue. The QuickJS
guest's C loop drains jobs, and when none can run it calls the SDK's flush,
which submits everything queued as one ordinary host batch and resolves it.
Calls started together (`Promise.all`) therefore share a batch and run under the
tools' concurrency metadata. Sequential `await`s stay sequential. A batch still
owns the session's scheduling gate, so budget reservation and journal ordering
are unchanged. Calls queued but never awaited run before the result is
published. A result read without `await` raises an error that names the
missing `await`. `max.batch` remains as `Promise.all` over `max.raw`.

**Foreground waits.** A foreground turn may call `agent` with `wait`. The
admitted root is marked awaited by that turn: when it finishes, its report
returns to the call instead of queueing a relay notice. If the turn stops
waiting first (cancelled, timed out, or the objective was replaced), or had
already ended when the agent finished, the job reverts to an ordinary root and
its report is relayed as usual.

**Leaf workers.** An agent started with `wait`, and its descendants, cannot run
`run_code` (the ADR-015 rule, now keyed on `wait`). Detached agents keep
codemode.

## Consequences

- The model has one way to start an agent and one way to express concurrency.
- A foreground turn blocked in a wait still holds its conversation; independent
  requests queue for the next turn. Detached agents remain the way to keep the
  frontend free.
- Tool fingerprints change with the names. No armed automation or stored skill
  referenced the old ones when this shipped.
