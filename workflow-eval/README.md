# Delegated-workflow live comparison

`max-workflow-eval` compares serial `agent()` calls and independent `max.batch`
calls over the same three real source-audit objectives. Children use the ordinary
`runDurableAgent`, task report tools, task scheduler, root reservation accounting,
phase/join callbacks and journal. A frozen `web_search` reader serves the exact
repository sources captured at startup; no production read/write tool is installed.
Only the selected production model endpoint uses the network.

The two scripts are host-authored. This tests the execution primitive, not whether
a model spontaneously chooses delegation or an entire production frontend prompt.
Counterbalanced pairs run serial/parallel then parallel/serial against the same
model endpoint during the same session. External production load is **not** frozen
or reproduced. Report `historical_load_reproduced` is therefore always false.

Use a fresh disposable database. The evaluator verifies the connected database
name starts with `max_workflow_eval_` and that it contains no prior messages. It
refuses local `MAX_LLM_*` overrides; use the exact production configuration through
a private config path. The DB override only points to the local evaluation DB.

```sh
createdb -h 127.0.0.1 -p 55435 max_workflow_eval_example
MAX_DB_URL=postgresql://127.0.0.1:55435/max_workflow_eval_example \
  cabal run max-workflow-eval -- \
    --config-file /private/production-config.json \
    --eval-profile qwen3.8-27b --eval-seconds 300 --eval-pairs 2 \
    --eval-report /private/workflow-comparison.json
```

Choose the whole-tree deadline before either arm runs. Each child inherits it;
leases renew independently. A timeout cancels the guest and local workers and
fences remaining children. Successful parents are settled through the normal
report gate. The report is updated after each arm and retains source fingerprints,
actual model names, wall-clock duration, usage and child reports.

The current evaluator records final parent/child settlement and reserved model
rounds as well. A cancelled request may have no completed call or usage record;
`usage_complete: false` means reported token totals are incomplete. Older report
bytes may have pre-cleanup child states; preserve them and attach a separately
hashed DB settlement readback instead of rewriting observations.

Completion requires the guest to finish and all three durable child reports to be
succeeded. Output shape validation alone is insufficient to assess their factual
quality: review claims and citations against the recorded source snapshots. A
reporting/DB/provider error is a failed experiment, not a performance win. Do not
pick a shorter deadline after observing a pair and relabel that pair as a timeout.
The historical fifty-minute production incident is a separate, unproven causal
claim and is not reproduced by this controlled workload.

For the stronger undelegated baseline, use another fresh database and pass
`--eval-mode ordinary --eval-source-snapshot /private/workflow-comparison.json`.
This runs one ordinary model loop over all three objectives and the exact frozen
source corpus from the paired run. Keep the same model and deadline; run it after
the paired experiment so the evaluators do not add load to each other. Serial
agent-call timing alone is not evidence of an improvement over an ordinary agent.
