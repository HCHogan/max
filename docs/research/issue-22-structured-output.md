# Issue 22: structured output and memory maintenance

Validated in the isolated `feat/issue-22-delegated-workflows` worktree on
2026-09-12. Production inspection and exports were read-only. Candidate creation
was performed on a restored production snapshot; this is not deployment evidence.

## Contract failures and fixes

`ExperienceCapsule` now accepts either a string or an array of strings for
`applicability`, `procedure`, and `invalidations`. Arrays normalize into bullet
text for the existing storage/publication format. Blank list items are dropped;
an entirely blank field still fails the semantic gate. Objects and non-string
array members remain decoding errors. Explicit `null` is successful abstention.
The extraction prompt gives the actual accepted shapes and receipt syntax.

The completion snapshot previously excluded the old `task_report` name but
included its replacement, `task_finish`, and progress reports. These self-reports
are now excluded alongside `request_finish`. A candidate still needs a succeeded
current task revision, no unresolved items, no started/unknown journal effects,
and citations belonging to successful non-report journal entries in its scope.

Historian's prompt now explicitly distinguishes an internal `principal_id` from a
platform/QQ user number. The notice review prompt requires one-line JSON with
escaped string newlines and quotation marks.

## First-response real-model gate

The replay inputs are the latest twenty distinct production calls per inventoried
contract, preserving their user/context messages and production model/profile.
Only the current contract system prompt is substituted. The evaluator uses the
production decoders, no tools, no JSON repair, and no transport retry. Local
`MAX_LLM_*` overrides are refused. Sources are embedded in the evaluator so an old
binary cannot certify newer files.

| Contract | Production model | Final first responses | Decode failures | Provider failures |
|---|---|---:|---:|---:|
| Historian | gpt-5.6-luna | 20 | 0 | 0 |
| Task experience | gpt-5.6-luna | 20 | 0 | 0 |
| Memory maintenance | gpt-5.6-luna | 20 | 0 | 0 |
| Intent | qwen3.5-4b-q4_k_m | 20 | 0 | 0 |
| Task/progress notice review | qwen3.8-27b | 20 | 0 | 0 |

The first notice batch had one malformed response out of twenty: literal newlines
inside a JSON string. After the prompt correction the **entire twenty-input batch**
was rerun; the table describes that final batch. The original failure was retained
privately. An initial experience run used an unintended environment credential and
received twenty provider errors; those were not decode failures and are retained
separately. They are not counted as passing evidence.

The [inventory](../../contract-eval/contracts.json) covers direct model-generated
JSON contracts. Task/progress reviews share the notice decoder. Native tool
arguments use their catalog schemas; workflow payloads use the requested closed
schema and the existing task report boundary. Neither is an unlisted free-text
JSON parser. Captions are prose.

[Certificates](structured-contracts) contain source/model/input/output fingerprints,
distinct source references, usage and latency; they contain no private messages or
credentials. `python3 scripts/check-structured-contracts.py` rejects missing,
stale, incomplete, mismatched-model or nonzero-failure certificates in CI. See
[reproduction instructions](../../contract-eval/README.md).

Zero observed decode failures in twenty inputs is a measured sample result, not a
promise of zero failures on every future response. Semantic truth, citation
validity, and candidate publication remain separate gates.

## First evidence-backed candidate

A completed production task and its real model-generated capsule passed the
current `createExperienceCandidate` path on the restored snapshot. The candidate
table changed from **0 to 1**. Its cited committed `maxops_exec_run` receipt records
job admission; the durable task's host-observed completion report separately
contains the remote succeeded result, exit code 0, and complete output. These two
facts must not be confused: a queued admission receipt alone is not completed work.

The candidate remains unpublished and no serving skill was enabled. The
[public proof](issue-22-candidate-evidence.json) records source/capsule fingerprints
and the scoped receipt. The production table was not modified. Publication still
requires a later task, operator-reviewed paired replay, unchanged fingerprints,
and the existing publication gate.

## Why maintenance returned `[]`

The read-only snapshot contains **496 maintenance events, all finished with `[]`,
zero pending, and zero expiry records**. The issue's 492 count was an earlier
snapshot. The worker was reaching the model: twenty real maintenance requests
were replayed and all returned decodable arrays. This is not evidence that every
abstention was semantically correct.

The source-message search for correction language found 25 events. Thirteen were
from a known external bot account and were excluded from the human-correction
analysis. Of the remaining examples:

- An associated-type namespace clarification had already changed the same memory
  from version 1 to 2 through Historian's successful CAS update.
- Registration/exam clarifications had already changed one memory from version 5
  to 6; maintenance saw the updated version. No explicit expiry date was supplied.
- A sandbox journal/narrator clarification had already changed one memory from
  version 1 to 2.
- Two terse negations accompanied newly added memories. They do not establish a
  conflicting pair of independently stored active facts; no supersession can be
  justified from those words alone.

The [audit references](issue-22-maintenance-evidence.json) link those classifications
to hashed source/event identities and versions without publishing conversations.
For the three in-place corrections, the previous text resides in `memory_versions`;
it is not another active memory to supersede. `applyMaintenanceProposal` requires
**two different memory IDs**, matching namespace and current versions, plus newer
independent human evidence on the replacement. Rewriting the same ID again is
outside this maintenance contract.

Expiry is intentionally narrower than natural-language time interpretation: both
source and memory must contain the explicit `YYYY-MM-DD` date with expiry wording.
Phrases such as “two months” or a question about “today” do not satisfy that gate.
The DB integration suite separately exercises actual supersession and dated expiry
with valid independent evidence, along with scope, stale-version and bot-evidence
rejections.

These observations explain conservative abstention for the examined corrections
and disprove a universally unreachable maintenance write path. They do **not**
prove all 496 abstentions correct or justify relaxing the evidence requirements.
No maintenance mutation was made in production.
