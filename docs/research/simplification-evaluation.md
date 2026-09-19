# Simplification: live model-loop comparison

On September 19, 2026, a small paired experiment compared baseline `b9d3e34`
with `e99a0a3`. Both used the running service's default profile,
`gpt-5.6-luna` through Responses, streaming enabled and `xhigh` effort.
This identifies the configured/requested model, not the gateway's internal
checkpoint.

The subsequent [h610 deployment report](simplification-release-20260919.md)
records real QQ receipts, migration preservation and operational limitations.

The [experiment record](simplification-20260919.json) contains the predeclared
order, exact runner and frontend-contract source, outputs, events, tool names,
usage and request/response fingerprints. Credentials and production messages are
absent. Full provider payloads remain in the local experiment directory
`/tmp/max-simplification-live`; their original report hashes are recorded.

## Method

Three synthetic cases each ran twice per version: a three-paragraph explanation,
a request to convert an unspecified file, and a lookup in a fixed fictional
release record. Each case ran old/new in the first pair and new/old in the
second. Requests were sequential, with a four-round Agent limit and a
240-second whole-case timeout selected before the first request.

Each binary used its revision's actual Agent loop, system prompt, frontend
contract, model transport and shared tool executor. Both had only one frozen
read tool and no skill index. The old version additionally used the original
`request_finish` schema/description with a local report receiver and its real
finish control signal. Admission and diagnostics were in-memory fixtures:
this experiment does not evaluate the SQL coordinator, actual tools, Jobs or
platform sending. Those require the separate integration/release gates.

## Observations

Each column contains six cases. Provider usage was present for every call.

| Observation | Old | New |
|---|---:|---:|
| Model calls | 9 | 8 |
| Tool calls | 9 | 2 |
| `request_finish` calls | 6 | 0 |
| Read-tool calls | 3 | 2 |
| Tool validation/errors | 0 | 0 |
| Timed-out or aborted cases | 0 | 0 |
| Reported prompt tokens | 39,772 | 30,036 |
| Reported completion tokens | 1,965 | 2,064 |
| Reported cached prompt tokens | 17,920 | 14,336 |
| System prompt UTF-8 bytes, including frontend contract | 12,264 | 10,640 |

The single extra old model call came from an unnecessary fixture read during
a missing-file clarification. Removing a finish tool does not by itself remove
a model round: it can share the model's final call, as all six old runs did.

Both versions asked for the missing attachment in both clarification cases
and returned all four expected release facts in both lookup cases. The old
finish reports used `waiting` for clarification and `answered` otherwise.
Neither version needed a tool-error correction round.

All long responses had three paragraphs and identified buffering of tool
arguments. Their explanations also made unsupported generalizations about
waiting for tool execution or another model answer; Max's old finish operation
could return the supplied reply immediately. These samples do not establish
better factual accuracy after simplification.

## Timing

Times below are medians of two cases, in seconds. First output includes progress;
first answer excludes progress and uses a stream event or returned final tail.
They measure the Agent output boundary, not arrival in QQ.

| Case | First output, old / new | First answer, old / new | Total, old / new |
|---|---:|---:|---:|
| Three paragraphs | 12.45 / 12.21 | 12.45 / 12.21 | 12.45 / 15.07 |
| Missing-file clarification | 12.45 / 7.13 | 14.89 / 7.13 | 14.89 / 7.13 |
| Frozen release lookup | 4.81 / 5.15 | 11.87 / 9.80 | 11.87 / 10.70 |

Both new long answers released text before the model call finished: roughly
1.49 and 4.24 seconds before completion. Both old long answers became visible
only at the end. This demonstrates incremental output with a live model;
the controlled SSE-to-QQ integration test separately verifies native sending
before provider EOS.

The new version was not uniformly faster. Its first long answer started later
than the matching old answer, and its median total duration for that case was
longer. Two samples per case, differing output lengths/cache usage, and
uncontrolled production endpoint load do not support a general latency,
billing-cost or model-quality improvement percentage. Refusals, live feedback,
long-running background work and real QQ network latency were not sampled.

## Reproduce

Extract `harness.source` from the JSON record into `Main.hs`, and each matching
`harness.frontend_contract_modules` entry into an arm directory as
`FrontendContract.hs`. Use clean checkouts of the recorded revisions and a
private config file. Build each library first, then compile within its checkout:

```sh
cabal build lib:max
cabal exec -- ghc -O0 -package max -i<arm-dir> -odir <arm-dir> \
  -hidir <arm-dir> Main.hs -o <arm>-eval
```

Add `-DOLD` for the baseline. Run the recorded `plan.sequence` serially:

```sh
<arm>-eval <private-config.json> <scenario> <result.json> <revision>
```

The runner removes local `MAX_LLM_*` overrides before loading the private config.
Use a new output directory; preserve failed attempts and do not rerun selectively
to improve the comparison. No production write tool is installed.
