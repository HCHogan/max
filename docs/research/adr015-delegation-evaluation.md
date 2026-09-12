# ADR-015: delegated workflow evaluation

Measured on 2026-09-12 in the isolated worktree. The implementation passes its
local behavioral gates. **The performance acceptance criterion remains open.**
These measurements do not support making fan-out the default. Nothing was
deployed and no production task or memory was modified.

## Controlled live-model comparison

The [evaluator](../../workflow-eval/README.md) uses the real durable task scheduler,
authority checks, shared budgets, report validation, JavaScript host bridge and
journal. The production-configured `qwen3.8-27b` endpoint runs every model loop.
Three independent source audits cover authority, budgets/capacity, and reuse/
steering. The reader returns frozen repository files; external tools are absent.

The whole-tree deadline was fixed at **300 seconds before the experiment**.
Two pairs were counterbalanced serial/parallel, then parallel/serial. A separate
ordinary single-agent baseline subsequently received all three objectives and the
exact same source snapshot. Parent scripts in the paired runs were host-authored;
the ordinary baseline uses one model loop. They do not measure model discovery
of `agent()` or a complete production frontend prompt.

| Run order | Mode | Whole task completed | Seconds | Succeeded children | Recorded model calls | Source reads | Recorded prompt / completion tokens |
|---|---|---|---:|---:|---:|---:|---:|
| 1 | Serial delegation | No: deadline | 300.01 | 2/3 | 6* | 11 | 26,517 / 19,154* |
| 2 | Parallel delegation | Yes | 170.03 | 3/3 | 8 | 12 | 59,907 / 32,555 |
| 3 | Parallel delegation | No: missing `task_finish` | 205.22 | 2/3 | 6 | 11 | 25,439 / 38,623 |
| 4 | Serial delegation | No: missing `task_finish` | 282.44 | 2/3 | 6 | 11 | 25,529 / 36,381 |
| 5 | Ordinary single agent | No: missing `task_finish` | 135.01 | n/a | 2 | 10 | 18,075 / 16,744 |

The successful parallel parent was verified `succeeded` in the DB after normal
report settlement. Failures are retained, including early exits; an earlier exit
without completion is not a speedup. Parallel completion was 1/2, serial 0/2, and
ordinary 0/1. These sample sizes cannot establish reliability or general speedup.
The successful fan-out used more recorded calls and tokens than either serial run,
and comparing its full cost with incomplete tasks is not a cost-benefit estimate.

*The timed-out serial tree reserved seven model rounds but emitted six completed
call/usage records. The cancelled in-flight request's usage is unknown; the token
sum is incomplete, not zero usage for that round. The original report captured one
child as running before cleanup. The [settlement readback](adr015-workflow-settlement.json)
confirms it was cancelled, preserves final root/child states and reservation counts,
and hashes the unchanged [paired report](adr015-workflow-comparison.json) and
[ordinary report](adr015-workflow-ordinary.json).

External production load was not frozen. The gateway exposed process metrics but
no usable model queue/concurrency measurements, so equal endpoint does not mean
equal load. The historical fifty-minute incident was not reproduced. Its historical
deadline also differs from the current six-hour task deadline. The chosen
five-minute experiment does not demonstrate that historical incident is fixed.

## Output quality and failed attempts

The final paired run includes rejected native payloads (missing `sources`, then an
object encoded as a string) and subsequent correction. The report gate supplies
field/type feedback, and the model sometimes recovers. Three final experiments
still ended without `task_finish`; these remain failures, even when the model had
read the requested sources. No missing checkpoint was synthesized into success.

Shape and task completion do not establish every claim's truth. For example, one
budget audit treats a 60-second lease as a guaranteed bound on a capacity stall;
healthy workers renew leases, so that inference exceeds the provided evidence.
The authority audit explicitly lacks some admission implementations. The frozen
source also predates the final recursive descendant `run_code` restriction; the
final DB regression test covers that added behavior. These reports are execution
and reporting evidence, not independently validated research answers.

Earlier harness attempts were excluded as invalid experiments: invalid tool
metadata, missing root grants, and an unread child-result inbox causing a completed
parent to requeue. Those attempts and raw logs remain private. The evaluator now
uses valid catalog entries, consumes the parent's durable inbox and checks its
settled status. All four final paired arms, including failures, are published.

## Behavioral acceptance and release boundary

The final unit suite passed **1,115 examples** and the real disposable PostgreSQL
suite passed **423 examples**, including eleven dedicated workflow DB examples.
The latter cover:

- Exact parent/child grant intersection and profile rejection before effects.
- Atomic shared last-call/last-round reservations and no admission on exhaustion.
- Ten awaiting parents releasing per-owner scheduler capacity for their children.
- Real JavaScript edits reusing unchanged steps with original journal provenance;
  changed inputs, receipts or effective grants produce separate identities.
- Rejection of cancelled or superseded parent/child generations.
- Unconsumed steering interrupting a live await and stopping the next guest boundary.
- Cancellation cleanup and denial of `run_code` throughout awaited descendants.

Unit fixtures additionally cover host batch overlap, phase checkpoints, payload
normalization/validation and authoring fixtures without live child admission.
The worktree also passed the full Cabal build, HLint, architecture checks and the
prompt-flow generator/check. Nix package acceptance is reported separately when
the final source build finishes. This document does not claim deployment health.

ADR-015's mechanism is implemented; its proposed performance benefit is still a
hypothesis. Before broad adoption, use a representative workload, record model
load, repeat matched ordinary/serial/parallel runs, and review answer quality in
addition to durable completion. The present evidence warrants retaining ordinary
tool calling as the default.
