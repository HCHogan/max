# ADR-012: One host execution boundary for native calls and Wasm

Status: accepted; first implementation batch complete (2026-09-07).

## Context

ADR-008 owns durable task authority, attempts, cancellation, journal and
recovery. ADR-010 owns skill visibility. The low-level `Tools` interpreter
already validates registry schemas, applies runner deadlines and classifies
outcomes, but `Agent` still owns batch scheduling, call budgets and journal
settlement. Giving a Wasm import access to only `invokeTool` would bypass these
rules. The language experiments in `experiments/wasm-codemode` exercise mock
hosts; they are not evidence of Max integration.

## Decision

Both adapters use `Max.Execution.Tools`: native model calls are translated to
neutral requests; Wasm imports decode only a tool name and argument object.
The shared executor owns the invocation budget, batch suppression, scheduling,
pre-effect admission, journal completion and typed host controls. It returns
`ToolInvocation`, never model protocol messages. `Agent` retains the LLM loop,
debug events, media draining and construction of conversation messages.

The executor uses the existing validated `Tools` interpreter. Registry metadata
remains the single source of schemas, deadlines, effects, retry classification
and parallelism. Its catalog is a round snapshot, identical to the invocation
registry. An execution session is created once per agent invocation and shared
by its adapters. Concurrent submissions serialize at its batch boundary;
parallel-safe members of one batch may run concurrently. Sequential tools and
finish calls cannot overlap another submission. Work calls consume the shared
local budget exactly once; the database interpreter atomically reserves durable
task budget and writes the pre-effect row. Checkpoints and the Wasm container
record do not consume leaf-call budget. Unstarted reservations are released.

Each call starts its journal immediately before execution, not by preparing all
rows before running the batch. Cancellation before admission leaves no started
row; interruption after admission settles that row conservatively as unknown.
Successful earlier calls remain committed if a later call or guest traps. No
automatic retry is introduced. Durable admission and recovery fencing remain in
the existing task/turn interpreters, not in the Wasm runtime.

`FinishLoop` and `YieldLoop` latch the session closed to further calls. Guest
JSON cannot construct a control. `LoadSkills` remains trusted host data and is
applied by the agent only at the next model round. A running guest retains its
initial catalog; it cannot load a bundle and invoke hidden tools in that run.
Private journal metadata is removed before either adapter exposes results.
Media use the existing `ToolOutput` queue and Message IR path.

## Wasm boundary for this batch

Embed Wasmtime through its C API, with a small C memory/ABI shim and a Haskell
driver. Do not spawn a language interpreter, CLI or subprocess to execute the
guest. Each run gets a fresh engine/store, fuel, memory/table/instance limits
and a wall-clock deadline. Epoch interruption stops guest computation; scoped
Haskell cancellation separately interrupts pending host tool IO. Callback
requests cross an STM mailbox: effectful actions run on the calling Haskell
thread, never on an FFI callback via an escaping sequential unlift.

ABI v1 is a core Wasm module exporting `memory` and `_start : () -> ()`, importing
only `max_v1.tool_call : (i32, i32, i32, i32) -> i32`. Arguments are request
pointer/length and reply pointer/capacity. UTF-8 request JSON contains exactly
`tool` and `args`; the host allocates call identities. The response records all
five existing outcome classes and their retry classification. Host controls
are delivered out of band, not decoded from response data. Requests and replies
are bounded, pointers checked before dispatch, and reply overflow traps without
redispatching a possibly committed effect. No WASI imports, environment,
filesystem preopens, sockets or arbitrary host IO are supplied.

The outer run has a separate journal row identifying the module digest and
resource limits. Inner calls have individual rows using host-generated call
labels tied to that run. A guest trap records failure of the container without
rewriting inner outcomes. The host result retains trusted controls even if the
guest subsequently traps. Recovery reads journal facts and starts a new attempt;
it does not persist a guest stack or replay the whole script.

The container enters from the orchestration adapter, outside the leaf batch
gate. Do not register `runWasmTools` as an ordinary `Tools` runner: a runner
already owns that gate, and recursively submitting leaves would deadlock. The
later model-facing adapter must distinguish a container submission from a leaf
request before dispatch, while feeding its inner calls through the same session.

## Acceptance and scope

Use small WAT fixtures compiled in the embedded runtime, not a selected guest
language or model-generated programs. Test native/Wasm result and journal
parity, last-budget contention, finish suppression, skill snapshot visibility,
forged control/identity rejection, memory and import rejection, cancellation in
both guest computation and host IO, and committed effects followed by a trap.
Run the real PostgreSQL integration suite, existing native Agent regressions,
build and architecture checks.

This batch exposes an internal embedding API and migrates native execution. It
does not advertise a `codemode` model tool, select a production guest language,
ship a compiler/SDK, create another scheduler, or deploy the experiments. Those
follow after this boundary is validated. Compilation is bounded by module size
but is not an interruptible guest instruction stream; production compilation
admission/caching belongs to the later user-facing code submission design.

## Validation of the first batch

Local Cabal build covers all components. The full unit suite passes 1,074
examples, including embedded C API execution, memory/ABI limits, resource
interruption, shared budget/control/skill behavior and one media budget across
the two adapters. The real PostgreSQL suite passes 327 examples in a dedicated
test database; six new integration cases cover journal/result parity, durable
budget contention, committed work followed by a trap, host-call cancellation,
lease takeover, and durable skill activation even if the guest later traps.
Architecture checks, HLint, package checks and prompt-flow generation/check pass.
The macOS Nix package builds with the pinned Wasmtime C library and its packaged
`max --help` startup check passes.
These are local implementation tests, not evidence of a deployed code mode.

The initial macOS embedding check caught an omitted C source link and then a
libffi trampoline allocation assertion in the current Nix toolchain. The final
bridge uses a static `foreign export` and a scoped mailbox `StablePtr`, and all
embedding tests run against the linked Wasmtime 45 C library. The historical
Python experiment does not substitute for these tests.

## References

- [ADR-008](008-durable-tasks-conversation-coordination.md)
- [ADR-010](010-skill-tool-bundles.md)
- [Wasmtime C API](https://docs.wasmtime.dev/c-api/)
- [Wasmtime interruption](https://docs.wasmtime.dev/examples-interrupting-wasm.html)
