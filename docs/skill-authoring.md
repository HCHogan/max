# Model-authored skill publication (ADR 014, second batch)

Status: implemented locally, 2026-09-10. Deployment remains separate.

## Contract

Load `skill-authoring` once to receive the complete authoring instructions and
`skill_save`, `skill_validate`, `skill_inspect`, `skill_publish`. Ordinary chat
carries only its one-line index entry. This is a fixed bundle, not query-driven
schema discovery. Workflow dependencies must also be loaded in full before
validation/publication so their current authorized catalog is available.

`skill_save` appends an immutable group-local draft using an expected draft
revision (zero means absent). Drafts are not in the skill index and cannot run
via `run_code`. Content includes instructions, the existing workflow package,
and fixture cases. Each fixture names an entry, supplies JSON arguments, an
ordered sequence of exact tool calls and simulated outcomes, and expected JSON
output. At least one fixture must exercise each workflow. Builtin and
`learned-task-` names cannot be authored or shadowed through these tools.

`skill_validate` checks package shape, dependency closure, current tool contracts,
JavaScript execution, input/output contracts, exact fixture-call consumption and
expected output. It runs the same QuickJS guest, SDK and host executor, with a
fresh bounded execution session and a fixture-only Tools interpreter. It receives
catalog metadata and fixture data; it cannot acquire application tool runners,
DB, network, outbound, or the caller's execution session. Unexpected host calls,
misordered or unused fixtures, and rejected tool arguments fail validation even if the script catches the guest error. SDK-only errors are
ordinary JavaScript branches; they do not imply a host invocation. Control tools,
skill authoring and use_skill are not workflow leaves in model-authored packages. Fixtures do not prove live
success, permissions, completeness, or safety of untested branches.

Validation records bind an immutable draft, dependency receipt versions, required
tool fingerprints, validator version, embedded guest/SDK hash and test report.
`skill_publish` takes that validation ID plus the expected published revision (zero means absent). It
recomputes the context and rejects stale reports, changed dependencies/contracts,
failed validation, cross-group references and publication conflicts. Publication
writes the existing `skills` head, immutable `skill_versions` snapshot and a
provenance receipt in one transaction; cache publication occurs only after commit.
It can update only skills previously published by this authoring path. Admin
skills, builtins and experience capsules remain under their existing writers.
Existing loaded receipts remain pinned. Later use_skill still enforces caller
capabilities; publication never persists the author's authority for reuse.

## Boundaries

Four narrow capabilities: draft saving, inspection, fixture validation and
publication. Model-facing tools only parse/render these operations. The assembly
adapter supplies host-minted conversation and durable caller identity. All writes
recheck active caller and source provenance under the existing conversation lock;
no model arguments can choose group, principal, turn or publication authority.

Haskell owns shape checks, dependency resolution, caps and publication decisions.
SQL stores immutable draft versions, validation facts and publication provenance;
there are no database workflow programs or validation policies. Draft writes use
a scope/name transaction lock and compare expected revision; publication also
uses the skill registry's existing commit/cache serialization. Fixture execution
opens no DB transaction and never re-enters the production leaf gate. The outer
validation call occupies its normal tool scheduling slot. Its result is stored
only after rechecking the caller, so cancellation during validation cannot publish.

## Bounds and delivery

Group-only publication; bounded drafts, revisions, fixtures, source, calls, fuel,
VM memory and wall time; bounded inspection summaries with exact-version content
available explicitly, together with a bounded structural diff against the previous
draft (instructions, dependencies, fixtures and individual workflow fields). No automatic trigger, new scheduler, automatic whole-script
retry, approval UI, rollback UI or mid-codemode steering in this batch. User-facing
publication means available on the next use_skill, not automatically loaded or
executed. A failed/unknown publication must be inspected before trying a new call.

Acceptance covers real PostgreSQL CAS/provenance/fencing and cache commit behavior,
real Wasm fixture runs without live tools, stale report rejection, hidden authoring
tools before loading and successful model save/validate/publish/load/run flow.

## Validation evidence

Local acceptance uses the real embedded guest and a dedicated PostgreSQL test DB.
Fixtures test exact calls, error and outcome-unknown branches, batch ordering,
syntax failure, fuel exhaustion and output mismatches. Database tests cover
save/validate/publish/load/run, concurrent CAS across registries, scope isolation,
caller expiry, stale dependencies/contracts/reports, protected writers and
commit-before-cache publication. Architecture denial fixtures keep query, draft,
validation and publication capabilities separate. None of this is live fleet
acceptance or a proof of untested workflow branches.
