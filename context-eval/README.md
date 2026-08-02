# Unbounded-context release-gate replay

`max-context-eval` has two deliberately separate checks:

- labelled Historian fixtures are sent through the exact production
  Historian prompt and strict host validator against a configured live LLM
  profile;
- deterministic recall fixtures exercise the proposed strong-threshold,
  direct-user-turn-only auto-hint policy. That policy is not connected to
  prompt construction, so a passing eval does not silently enable it.

Run fixture/schema and deterministic recall checks without spending tokens:

```sh
cabal run max-context-eval -- --offline-only
```

Run the release gate against `memory.extract_profile` (or override it):

```sh
cabal run max-context-eval -- --min-pass-rate 1
cabal run max-context-eval -- --eval-profile historian-candidate \
  --runs 3 --min-pass-rate 1
```

Every Historian case labels required/forbidden summary terms, P1 evidence, and
expected semantic-memory proposals. Additional proposals fail by default:
omission is safer than turning ambient banter into durable fact. Reports show
estimated prompt size, provider-reported prompt/completion/cache tokens, and
request latency. Missing provider usage is a gate failure because cost cannot
be approved without measurements.

The default checked-in cases are minimal wiring fixtures. Before the
all-conversation production cutover, replay the separately reviewed,
production-derived anonymized cases:

```sh
cabal run max-context-eval -- \
  --historian-fixture context-eval/fixtures/historian-real.jsonl \
  --eval-profile PROFILE --runs 3 --min-pass-rate 1
```

`historian-real.jsonl` was manually transcribed from production log context.
Participant, conversation, and message identifiers are synthetic; names,
links, and identifying details were removed, while speaker order, correction
structure, technical substance, and memory/no-memory labels were hand-checked.
Never regenerate it by committing an unreviewed production export.

Together, the synthetic and production-derived cases are the LLM-quality part
of issue #10's release matrix. Pure and PostgreSQL integration suites cover
the remaining cursor, coverage, privacy, prompt-budget, rebuild, and recovery
properties. Every expected fixture label is reviewed by hand; never derive
labels from the model's prior answer.

## Current synthetic baseline

On 2026-08-03, `gpt-5.6-luna` passed all 27 captures in a three-run replay of
the nine checked-in Historian cases. Two captures used the bounded JSON repair
path (29 provider calls total). Provider-reported averages per capture were
1,469.1 prompt tokens and 694.7 completion tokens; average provider-call
latency was 13,184.2 ms. This is a synthetic schema and precision gate, not a
substitute for the production-derived replay.

The same candidate passed all 12 captures in a three-run replay of the four
manually anonymized production-derived cases without repair. Provider-reported
averages per capture were 1,407.8 prompt tokens, 674.6 completion tokens, and
13,947 ms latency. Both gates used the evaluator's default disabled optional
prompt-token ceiling; model-window safety remains enforced by production
`ContextBudget`, not by an arbitrary evaluation-cost cap.
