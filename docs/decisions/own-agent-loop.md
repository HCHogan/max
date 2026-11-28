# The agent loop is written in-house, sans-I/O

Max's agent loop is its own code, a state machine that does no I/O,
rather than a framework's.

## Context

Max needs an agent loop: call the model, run its tool calls, feed the
results back, take new messages in between. The frameworks looked at are
rig, yoagent, adk-rust, autoagents, swiftide-agents, aisdk and genai, and
pi-agent, a third-party Rust port of pi.

## Decision

The loop is in-house, a sans-I/O state machine in `max-core`
([The core](../design/core.md)). Two things are borrowed: rig-agent's
`AgentRun`, which writes the loop as a sans-I/O state machine, and the
steer semantics of pi and yoagent.

## Why

- Each framework brings its own provider layer or session layer, which
  conflicts with Max's own protocol adapters and with the ledger.
- They are far larger than the part Max would use: rig-core with
  rig-agent is about 130,000 lines, yoagent about 39,000, against a loop
  and two protocol adapters of a few thousand.
- A sans-I/O core can be tested synchronously, step by step, with no
  runtime and no fake provider, and the compiler keeps it free of I/O
  (see [Crate layout](../architecture.md#crate-layout)).

## Cost

Every protocol detail is Max's to keep up with: Responses and Chat
Completions, reasoning pass-through, and each provider's quirks, in
`max-llm`.
