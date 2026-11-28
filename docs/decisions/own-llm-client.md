# The LLM client is written in-house

Max talks to model providers with a client of its own, on reqwest and
sse-stream.

## Context

`max-llm` speaks two protocols, Responses and Chat Completions, to
several providers, and passes reasoning through unchanged.

## Decision

Small structs cover only the dozen or so fields Max reads; everything
else stays raw JSON and is passed through. sse-stream only splits the
byte stream into events.

## Why

A library for the protocol, async-openai in its "bring your own types"
mode, was the other way:

- In that mode the request and response types are written by hand
  anyway, which leaves the library doing nothing but sending requests and
  parsing SSE.
- Each of its streams starts a task with `tokio::spawn` that Max doesn't
  control, against the rule that every task belongs to a `Scope`
  ([Runtime structure](../architecture.md#runtime-structure)).
- When a connection drops midway, its stream simply ends without an
  error, so a cut-off answer looks complete.
- It releases a breaking minor version roughly once a month.

## Cost

Every protocol change is Max's to follow. The client is tested against
real responses recorded from four providers.
