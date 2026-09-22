# ADR-010: Fixed skill tool bundles

> 2026-09-15: The legacy maxops integration described here has been removed.
> Current operations use [SSH and the sandbox runtime](../runbooks/ssh-operations.md).

Status: fixed bundle mechanism implemented. Updated 2026-09-15 for the deployed
SSH operations integration. The original API adapter is retired; its dated
acceptance below is historical evidence, not the current tool contract.

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
| web | web_search, browser, view_zhihu, view_bilibili |
| sandbox | sandbox lifecycle/execution/files, nix_search, file import/export |
| office | office instructions and the complete sandbox dependency |
| self-knowledge | inspect_source |
| operations | SSH workflow and the complete sandbox dependency; requires an enabled group network |
| skill-authoring | skill_save, skill_validate, skill_inspect, skill_publish |
| codemode | workflow instructions; run_code remains governed by its existing task/host policy |

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
For operations, the group network policy is enforced by the native broker.
Loading `operations` checks that policy and loads sandbox instructions/tools;
it cannot change the policy or supply a new credential.

task_start and monitors derive their authority from the allowed ceiling, not the
currently visible subset. A child profile only narrows that ceiling, and the
child loads its own skills. The basic profile has no shell grant. Shell and SSH tasks use the sandbox profile,
so an enabled group's sandbox can use full-sudo
SSH; the profile name is not a separate read-only boundary. Group restrictions,
policy changes and unavailable capabilities remain effective.

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

## SSH operations

`operations` depends on `sandbox`; commands use `ssh hostname` inside the
broker-selected dedicated network. The fleet account is `max`, the local daemon
account is `max-service`, and the shared client/node name is `maxops`. There is
no registry-discovery, Hub API, management token or automatic job observer.
Long remote work belongs in named systemd jobs; reconnect and inspect the actual
result before retrying uncertain commands. See [the runbook](../runbooks/ssh-operations.md).

## Historical API adapter acceptance (2026-09-07)

The following describes the retired adapter's original validation, not current
release requirements or callable tools. The fixed bundle/recovery mechanisms
remain; API-specific code, fixtures and tests were removed on 2026-09-15.

### Original implementation and acceptance

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

Versioned, executable skill content and validated package dependencies are
defined in [ADR-014](014-versioned-skill-workflows.md). They preserve fixed,
complete loading and cannot change host-owned tool authority or effects.
