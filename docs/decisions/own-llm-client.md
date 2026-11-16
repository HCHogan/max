# The LLM client is written in-house

Max talks to model providers with a client of its own, in place of
async-openai 0.42.2.

## Context

`max-llm` speaks two protocols, Responses and Chat Completions, to
several providers, and passes reasoning through unchanged. It started on
async-openai in its "bring your own types" (byot) mode.

## Decision

Write the client on reqwest and sse-stream. Small structs cover only the
dozen or so fields Max reads; everything else stays raw JSON and is
passed through. sse-stream only splits the byte stream into events.

## Why

- In byot mode the request and response types had to be written by hand
  anyway, which left async-openai doing nothing but sending requests and
  parsing SSE.
- Each of its streams started a task with `tokio::spawn` that Max didn't
  control, against the rule that every task belongs to a `Scope`
  ([Runtime structure](../architecture.md#runtime-structure)).
- When a connection dropped midway, its stream simply ended without an
  error, so a cut-off answer looked complete.
- It released a breaking minor version roughly once a month.

## Cost

Every protocol change is Max's to follow. The client is tested against
real responses recorded from four providers (see
[archive/v1-implementation-order.md](../archive/v1-implementation-order.md),
step 5).
