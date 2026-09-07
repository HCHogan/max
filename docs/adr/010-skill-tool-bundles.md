# ADR-010: Fixed skill tool bundles and maxops integration

Status: implemented locally (2026-09-07); deployment is separate.
Written before implementation; validation evidence is recorded below.

## Problem and decision

Before this change, ordinary conversation paid for browser, sandbox, file, self-inspection
and maxops tools even when unused. use_skill only returned instructions. maxops's
generic tools additionally made the model read a full RPC catalog and poll jobs.

Keep a small base tool set and a stable skill index. Calling use_skill loads the
entire host-declared bundle, including instructions and input schemas, before
the next model request. Never choose tools using query text, semantic retrieval
or an implicit relevance heuristic. Do not expose partial bundles to fit a budget.

## Fixed bundles

| Skill | Tool ownership / dependencies |
| --- | --- |
| web | web_search, browser tools, view_zhihu, view_bilibili |
| sandbox | sandbox lifecycle/execution/files, nix_search, file import/export |
| office | office instructions and the complete sandbox dependency |
| self-knowledge | inspect_source |
| maxops | all permitted registry-derived fleet tools and maxops instructions |

Replies, conversation/context/media reads, memory, reminders/monitors and task
control/settlement remain base capabilities. Shared tools and dependencies are
deduplicated. Dependencies are explicit, acyclic metadata, never inferred from
instruction text. Editable instruction text cannot grant tools or modify their
effects, retry class, authority or deadline.

## Visibility is separate from authorization

The host creates an authorized ceiling with existing schema/effect fingerprints.
The model sees base tools plus the union of loaded bundles, intersected with that
ceiling and current policy. A direct call to an unloaded tool is rejected before
effects, even if the name exists in the authorized registry.

Loading a skill is sequential and takes effect at the next model round. A call
batch cannot load a bundle and execute a previously hidden tool in the same batch.
The tool directory and invocation admission use the same visibility snapshot.
Only the registry owns execution metadata; skill loading cannot mint authority.
The maxops management grant includes both fleet mutation and durable task writes
before loading. Direct controls narrow that effect set; loading never adds a
previously ungranted effect. Older management fingerprints fail closed on upgrade.

task_start and monitors derive their authority from the allowed ceiling, not the
currently visible subset. A child profile only narrows that ceiling, and the
child loads its own skills. A read-only child cannot acquire management tools by
loading maxops. Group restrictions, policy changes and unavailable platform
capabilities remain effective and are reported explicitly.

## Scope, recovery and context

Loaded bundles belong to a logical request or durable task, never a global group
table. Repeated loads are idempotent. An independent request starts with base
tools. Concurrent requests do not alter each other's tools.

Use existing durable execution evidence/checkpoints to retain successful skill
loads and version fingerprints. Recovery rebuilds visibility under current grants;
it does not replay old mutations or trust a model-generated instruction as a
loading receipt. Do not create a second durable scheduler or conversation state.
Instructions needed by loaded bundles must survive normal tool-result trimming.
Provider ordering stays deterministic; changing visibility is explicit and occurs
only at a skill-load boundary.

## maxops adapter

The maxops public contract is documented in HCHogan/maxops at
`docs/api-client-contract.md`. The credential and HTTP mechanics stay in the
host adapter. Load the complete permitted input-schema catalog when maxops is
activated, without making the model browse it. Keep response schemas and raw
protocol metadata out of model results. Public catalog/resource discovery stays
available to callers, but never controls bundle composition through relevance.

Derive operation names, schemas and read/write metadata from the remote registry.
Use stable host-generated submission keys tied to a logical invocation. Preserve
revision checks, unknown outcomes and structured remote errors. Cache metadata
without treating it as authorization; changed credentials/config invalidate it.

All job submissions enter the existing durable Operations task runtime before
HTTP submission, releasing the frontend. This fixed policy avoids predicting a
job's latency. The host submits and observes programmatically, without LLM calls.
Reconnect using the same remote reference; waiting is not remote cancellation. The model receives
a compact terminal result or a decision-requiring conflict, rather than repeated
poll responses. Deployment progression remains in maxops, not Max's database.

## Implementation and acceptance

1. Implement and test fixed bundle metadata, visibility snapshots, explicit
   dependency loading and instruction retention independently of maxops.
2. Connect skill loading to the agent loop and durable recovery. Verify base
   visibility, input-schema completeness, next-round activation, idempotence, concurrent isolation,
   hidden-tool rejection, child ceilings, revocation and recovery.
3. Implement maxops discovery/error/wait/result/workflow APIs and adapt its
   generic clients, then connect Max's registry-derived bundle and job observation.
4. Update embedded skills, architecture/runbooks, prompt-flow and integration
   documentation. Verify local HTTP contracts and a real disposable PostgreSQL DB.

Required gates: cabal build all, unit and real DB suites, cabal check, relevant
lint/Nix evaluation, prompt-flow generation and --check. Report catalog size and
verify the base/loaded visibility boundary. Local gates do not claim fleet
deployment; commits/push/deployment are separately reported.

Local validation uses the actual 43-operation Hub registry exported into a checked
fixture: the compact input-only catalog is 25,173 UTF-8 bytes. The ordinary chat
catalog omits all five optional bundles. Agent tests prove next-round loading,
hidden same-batch rejection, independent contexts and retention of a 70,000-character
latest result. Real PostgreSQL tests cover trusted receipt recovery across task
attempts and isolation after revision replacement. Max/Hub HTTP tests cover scoped
reads, host/unit denial, idempotency conflicts, waiting and live config revocation.

The concurrent kill fix uses explicit cancelled settlement: terminal turn, request
cancellation and frontend lease release commit together. Duplicate cancellation
signals cannot interrupt that cleanup; a kill during publication failure cleanup
also reaches the same terminal path. Cancelled durable tasks never auto-retry.
