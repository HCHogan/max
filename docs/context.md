# Context compaction and navigation

`!compact` immediately queues a historian capture with a fixed ingestion cutoff.
It does not clear chat, memory, persona, pins, tools, or sandboxes. `!clear` is a
compatibility alias; the explicitly destructive `!clear --all` and legacy
`!unclear` remain separate. Compaction requires the historian profile to be enabled.
The acknowledgement means accepted, not already published. Work involving an
active task's trigger waits for that task. Requests are process-local, not restart
jobs; reissue after a restart if needed.

The historian reads a bounded prefix, validates citations and source hashes, and
atomically publishes each episode with its cursor. Until publication, the old
representation remains authoritative. Failure leaves that batch unchanged. Large
prefixes use multiple batches; earlier successful batches are not rolled back if
a later one fails. Messages arriving beyond the captured cutoff are not included.
Original messages remain available indefinitely under the existing storage policy.
Compaction creates sourced chronological episodes, not a cross-episode semantic
merge. Consolidation/dreaming is intentionally deferred.

## Capacity policy

All context **capacity** targets derive from the selected profile. `max_input_tokens`
is an input ceiling, not a combined input/output window; do not subtract output
twice. The effective input budget `B` subtracts the configured tool-round reserve
and, when attachments are present, the attachment reserve. For a combined 262,144
token deployment, first configure an input ceiling compatible with its output
allowance; merely setting both input and output to 262,144 is not valid.

| Capacity | Target |
| --- | --- |
| Raw history collection/high watermark | `B / 2` |
| Raw tail retained by automatic historian | `B / 4` |
| Episode summary injection | `B / 8` |
| Memory candidates per subject | `max(1, B / 32 / 364)` entries |
| Read page text budget | `B / 32`, transport guard at 16,384 estimated tokens |
| Historian source batch | `2 / 3` of the historian profile's own input budget |

Automatic capture keeps the recent raw tail; a single newest message exceeding
the high watermark is instead offered to the historian so pressure cannot get
stuck with an empty raw selection. Manual compact deliberately captures
the requested prefix even when it is small. Quiet-period capture still waits ten
minutes, while sustained traffic schedules a coalesced pressure check after one
minute that subsequent messages cannot postpone. Background history checks use
the session's text-only budget; prompt construction applies attachment reserves
when needed. Final prompt selection still accounts for protected input, pins,
media, and the total ceiling; these targets are not extra space outside it.

Model switching changes injection/work sizes, never deletes data. Age, confidence,
retry delays, storage quotas, and expiry semantics are not context capacities and
are not multiplied by the model window. Existing summary tiers remain an age and
importance policy under the model-sized summary budget.

## Three primitives

`context_search({query, kinds?, from?, until?, sender?, limit?})` finds relevant
message/episode/memory candidates. Pins and media captions are message attributes.
Each result carries a stable string `ref` and a ready-to-use `read` request. Filters
apply before candidate limits. Search is ranked retrieval, not an exhaustive log
export. `sender` is a canonical principal ID and limits results to messages and
personal memory; episodes are not attributed wholesale to one speaker. Dates
filter message receipt time, episode source messages, and memory update time.

`context_read({ref?, from?, until?, before?, after?, limit?, cursor?})` reads raw data:

- `{}`: latest page.
- `{ref: "message:123"}`: exact message; add `before`/`after` for neighbors.
- `{ref: "episode:<uuid>"}`: start at its first source message. Episode bounds and
  `in_episode` annotate evidence; navigation can cross either boundary.
- `{from: "2026-09-23", until: "2026-09-24"}`: chronological date range `[from,until)`.
- `{ref: "memory:12"}`: full stored fact and scoped evidence references.
- `{ref: "forward:123"}`: forwarded children in their own order, not interleaved
  with the group's main timeline.

Results use `items`, `prev`, and `next`. Pass continuation objects unchanged.
Backward pages are still in chronological ingestion order. Date ranges are hard
filters across pages; offset-free dates use the configured fixed-offset timezone,
while ISO-8601 `Z` and explicit offsets are honored. Responses report normalized
UTC bounds and distinguish `received_at` from `occurred_at`. Message and principal
IDs are strings, including in code mode, to avoid JavaScript integer precision loss.

`limit` and neighbor counts are upper bounds under the model's page budget and
the 100-row I/O guard. Large bodies return `complete: false`, `text_offset`, and
`more`; pass `item.more` to the same tool to read the rest. `page.next` advances
messages, not body text. Body continuations reject edits rather than splice two
versions together. Timeline/forward pages are live navigation, not an immutable
export snapshot. All reads recheck current-conversation scope; opaque cursors and
known IDs are locators, never permission to read another room.

`context_resume({turn: "t#42", call_id?, after_cursor?, limit?})` reads a previous
working turn's request reference, execution trace, outputs, and termination state.
Output previews show the latest five chunks; `outputs_has_older` indicates more,
reachable with `context_read` around the supplied output references.
Use its `next` object for more trace entries, or an entry's `resume` object for
the full JSON-text result. Reading does **not** replay tools or restart tasks.
Uncertain effects remain uncertain; inspect current external state before acting.
User corrections can also be in surrounding chat, reachable from the request's
`read` reference. Old `context_expand`, `get_message_by_id`, and `view_forward`
are no longer registered; historical journals retain their original tool names.

Native calls and `tools.context_read(...)` in code mode use the same schema,
conversation binding, and execution/journal path. See the code-mode manual for
an executable-style navigation example and its output-size limits.
