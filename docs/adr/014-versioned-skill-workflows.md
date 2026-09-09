# ADR-014: Versioned skill workflows

Status: workflow packages, authoring, and publication contract continuity implemented (2026-09-10); release and deployment are separate.

Publication/load/recovery contract continuity and the live frontend acceptance
harness are specified in [skill-contract-acceptance](../skill-contract-acceptance.md).

## Decision

A skill may contain an instruction body and a versioned package of JavaScript
workflows. A package declares fixed skill dependencies and named entry points,
each with source, input/output contracts and required tool names. These names
declare requirements, never grants. The host registry remains authoritative for
schemas, effects, deadlines, concurrency and retry behavior.

`use_skill` resolves the complete dependency graph from one registry snapshot,
deduplicates it, validates it and returns all instructions and workflow contracts.
Workflow packages implicitly depend on codemode. Loading pins the package and
the current required tool fingerprints in the trusted receipt. A missing tool
rejects the load without partial activation. Independent executions start empty.
Existing instruction-only skills and their fixed host bundles remain compatible.

`run_code` accepts either `{code}` or `{workflow: "skill/entry", args}` as the sole
model call in a round. Saved references resolve only against already loaded host
receipts, including after recovery. Source is never re-read from the current
registry during execution. The host validates input before admission and checks
required tool fingerprints against the current catalog before any guest effect.
The saved run receives only its declared tools intersected with that catalog;
leaf admission must enforce this restriction as well as guest visibility.

Both submissions use the existing JavaScript/Wasm adapter and execution session.
There is no workflow leaf runner, recursive scheduler or second tool authority.
Input is passed as a JSON value, not interpolated as executable source. Output
contracts are checked before container journal settlement; an invalid output
never makes preceding leaf effects safe to replay. Container evidence includes
the pinned version, workflow identity and arguments. Model results include a run
reference and bounded leaf receipts. Finish/yield keeps its existing semantics:
the program stops, and does not resume after a background handoff. Steering is
observed only after a complete code submission (ADR-013).

## Persistence and scope

The existing skills registry remains the publication surface. Database skill
edits append immutable revision snapshots and atomically advance the current row
using an expected revision. Cache publication happens only after commit and
cannot regress to an earlier revision. Loaded receipts retain exact content;
updates cannot alter in-flight or recovered programs. Current tool grants still
apply to that content. Package shape, dependency resolution and execution policy
live in Haskell; SQL stores content, scope, revisions and provenance only.

Existing admin APIs can seed and update packages. Package updates require an
expected revision. Model authoring/publishing uses the separate scoped draft
path described below. Two embedded read-only workflows exercise fleet status aggregation and
batch search. They ship with the binary and require no production DB seed.

## Contracts and limits

Contracts use a documented, bounded JSON Schema subset; unsupported keywords
are rejected rather than silently ignored. Packages, sources, dependency depth,
workflow count and complete load size are bounded. No npm imports, ambient IO,
stored credentials, automatic whole-program retries, guest state persistence,
or dynamic dependency discovery is added. Compatibility is conservative: a
changed required tool fingerprint requires loading a new execution snapshot.
This checks compatibility against the load-time catalog; it does not statically
prove source compatibility with every future tool API. Validation records tied
to authored package versions are provided by the authoring path described below.

## Acceptance

Test complete ordered dependency loading, cycles/missing dependencies, scope,
immutable updates and concurrent edits; saved/inline execution parity, nested
argument validation, output failure after committed work, changed/revoked and
undeclared tools, recovery using pinned source, media/control propagation and
both real embedded sample workflows. Run build, unit/real PostgreSQL suites,
architecture positive/negative boundaries, HLint and prompt-flow generation/check.
Use a separate test database and worktree while other changes are in progress.

Execution evidence browsing, rollback UI, cross-task continuation and runtime
compilation caching remain subsequent batches.

## Model authoring follow-up (2026-09-10)

The second batch is implemented locally: `skill-authoring` loads a fixed set of
four tools for immutable drafts, fixture-only validation, inspection and scoped
publication. See [the authoring contract](../skill-authoring.md) for exact writer,
transaction, validation and authority boundaries. Execution evidence browsing,
rollback UI, runtime caching and cross-task continuation remain future work.
