# Structured-output release gate

Issue #22 requires twenty real production inputs per structured-output contract,
with zero first-response decode failures. `max-contract-eval` calls the configured
production model using the current production prompt and decoder. It installs no
tool runners and connects to no database. It does not repair failed answers or
resample failures. Provider failures also fail the gate; an abstention (`null` for
experience, `[]` for maintenance) is decoded data, not proof of useful output.

`contracts.json` inventories all current non-tool JSON generation paths:
Historian (including memory proposals), task experience, memory maintenance,
intent classification, and task notice/progress review (one shared contract).
Captioning returns prose. Native agent tool arguments use the tool catalog and
execution admission rather than a separately requested JSON answer. User-defined
workflow output contracts still require their own fixture and live acceptance.
Adding a JSON generation path must add its production prompt/decoder, source
dependencies, and twenty-sample report here before release.

Export real requests to a private local directory using
`scripts/export-contract-inputs.sql` with `psql -X -qAt -v ON_ERROR_STOP=1` against
the production read-only connection. The export retains twenty recent requests
per contract, including failed historical answers. Do not check raw requests,
answers, configuration or credentials into Git. Reuse the serving configuration;
unset local `MAX_LLM_*` overrides so the default profile is not silently changed.

From the repository root, for each contract name in `contracts.json`:

```sh
cabal run max-contract-eval -- \
  --config-file /private/path/production-config.json \
  --contract-fixture /private/path/production-calls.jsonl \
  --contract task-experience \
  --contract-report /private/path/task-experience.json \
  --contract-raw-report /private/path/task-experience-raw.jsonl
```

The public report records source/prompt/input/output hashes, actual model,
profile, first-response rates, usage, and per-call elapsed time. Source hashes
come from bytes embedded when the evaluator is compiled, so a stale executable
cannot certify newly edited source. Reports are updated after each sample;
interrupted runs have `complete=false` and cannot pass. Raw reports are optional,
private evidence for semantic review. Keep failing runs as evidence; after fixing
the cause, run a new complete batch, never remove individual failed samples.

Review semantic evidence separately: decoding does not verify a memory mutation,
task completion, cited receipt, authorization, or useful delegation. Copy the
public reports to `docs/research/structured-contracts/<contract>.json`, then run:

```sh
python3 scripts/check-structured-contracts.py
```

CI repeats this offline certificate check on every change. A missing report,
source change, insufficient sample count, model drift, incomplete batch, or any
first-response failure rejects release until a fresh real-model gate is recorded.
