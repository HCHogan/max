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
  --runs 3 --max-average-prompt-tokens 1200
```

Every Historian case labels required/forbidden summary terms, P1 evidence, and
expected semantic-memory proposals. Additional proposals fail by default:
omission is safer than turning ambient banter into durable fact. Reports show
estimated prompt size, provider-reported prompt/completion/cache tokens, and
request latency. Missing provider usage is a gate failure because cost cannot
be approved without measurements.

These checked-in cases are minimal wiring fixtures. Before the all-conversation
production cutover, add anonymized real conversations covering the full matrix
in issue #10 and review every expected label by hand. Never derive labels from
the model's prior answer.

## Current synthetic baseline

On 2026-08-02, `gpt-5.6-luna` passed all 27 captures in a three-run replay of
the nine checked-in Historian cases without invoking the bounded JSON repair
path. Provider-reported averages per capture were 1,266.8 prompt tokens, 670.7
completion tokens, and 14,138 ms latency. This is a synthetic schema and
precision gate, not a substitute for the anonymized real-conversation replay
required before cutover.
