# Research: the classification model

Recorded 2026-10-28. This is a record only, not a to-do list.

[Jev](https://docs.typesafe.ai/models) (TypeSafe AI, 2026-09) is a non-autoregressive judgement model: it handles three kinds of question (yes/no, multiple choice and scoring) and returns probabilities directly. It costs $0.042 per million input tokens, with output free; it is available only as a hosted API in the United States and is closed-source; officially, English works best, while Chinese, Japanese and Korean are usable but somewhat weaker.

For now it will not replace intent's small model:

- The savings are not where the bottleneck is. The current small model runs on our own machine, with no per-call cost; what costs money is false triggers, each of which runs a frontier model's turn for nothing. Two days of the Haskell version's logs in July: about 7,500 messages that did not address Max by name, 2,051 classifications and 77 triggers.
- There is no public evidence at all for multi-person Chinese group chats; in English tests, adding injections flipped 22% of its verdicts, the highest among the judge models tested ([Braintrust](https://www.braintrust.dev/evals/jev-vs-gpt-eval-judges)).
- Every casual message would have to be sent to an American company; versions are deprecated after 30 to 60 days, and every upgrade requires re-evaluation and new thresholds.

Possibly useful:

- Have the small model read the logprobs of the labels instead (llama.cpp's `n_probs`), taking the probabilities directly and setting a threshold, which is much faster than generating JSON; the cost is that there is no `reason`, so the verdict line loses its explanation.
- Build an evaluation set from the ledger: messages that genuinely @-mention or reply to Max, with the @ and the quote removed, are positive examples of "addressing Max without an @"; cases where a classification triggered and the main model answered `[silence]` are weak negatives, and cases where someone afterwards ran `/proactive off` or told Max to shut up are strong negatives; a few hundred hard cases are then sampled by hand. The evaluation set is real group chat and does not go into the public repository. With an evaluation set, Jev could be tested offline once for a few cents.
- The most valuable labels are "is this talking to Max", "is this waiting for Max to respond" and "is this annoyed with Max"; the last was implemented as intent's `dismiss`, removed on 2026-10-29, and now exists only in the classification prompt. Topic changes, whether something is worth remembering, sentiment, and spam and injection detection are not worth classifying message by message.
