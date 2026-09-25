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

Configure only `context_window` on the selected profile: it is the **combined
input plus output** token limit, not usable input space. Omission defaults to
131,072. Max derives an output allowance `O = max(1, C / 8)`, hard input ceiling
`I = C - O`, tool-round reserve `T = C / 8`, and attachment reserve `A = C / 8`
for multimodal profiles (zero for text-only profiles). Integer division rounds
down. The effective text budget is `B = I - T - A` with attachments, or
`B = I - T` without them. Output is subtracted exactly once, during configuration
resolution; both initial prompts and working-turn pruning use the resolved limits.

For `context_window: 262144`, the default output limit is 32,768, the hard input
ceiling 229,376, and the planning budget 196,608 without attachments or 163,840
with attachments. These are conservative planning budgets, not an exact provider
tokenizer or a promise that every request can fill the entire window.

Advanced `max_tokens`, `tool_round_reserve`, and `attachment_reserve` overrides
remain available for provider-specific limits; increasing output reduces the
derived input ceiling. Invalid output/reserve combinations fail at startup.
Legacy `max_input_tokens` remains an input-only compatibility setting with the
old default reserves; it must not be combined with `context_window`. New configs
should never need to calculate or specify `max_input_tokens` themselves.
The CLI/environment equivalents are `--llm-context-window` and
`MAX_LLM_CONTEXT_WINDOW`.

`context_budget` optionally sets a smaller **working budget** `W = min(B,
context_budget)` for the context assembled up front. The window stays the hard
ceiling for a turn (tool rounds, final fit checks); the working budget trades
prefill time and long-context quality against recall. Without it `W = B`.
Startup rejects a budget above the text planning budget. For example
`context_window: 262144` with `context_budget: 131072` keeps a 196,608-token
turn ceiling while sizing the initial context from 131,072.

At startup Max also lists each OpenAI-protocol server's models and warns when a
profile's configured window exceeds the context length the server reports
(`context_length`, `max_context_length`, `max_model_len` or `context_window`).
The check is advisory: an unreachable server or unreported length is skipped,
and the configuration remains the source of truth.

### Vision envelope

A multimodal profile may declare its server's vision limits: `vision_tokens`
(all images and videos in one request), `vision_item_tokens` (one medium;
default `min(vision_tokens, 16384)`), `video_max_seconds` (default 600),
`video_max_frames` (default 768) and `video_max_pixels` (the video processor's
kept pixel volume; default 25,165,824, Qwen-VL's `longest_edge`). NInfer rejects
a whole request that exceeds any of these, so with a declared envelope Max
prepares media to fit instead of sending them as-is:

- **Costs** follow the Qwen-VL geometry: one token per 32×32 merged patch after
  the server's rounding, two video frames per temporal patch. Images are priced
  from their header; videos carry the measured token count of their rendition.
- **Images** above half an item are downscaled to the largest patch grid within
  that cap.
- **Videos** are re-encoded (audio dropped, rotation applied) within
  `min(vision_item_tokens, video_max_pixels / 2048)` tokens. Frames keep at
  least 256 tokens (about 512×512); the frame rate falls below the server's
  2 fps before frames become illegible. A window longer than
  `video_max_seconds` is time-compressed into an overview; the label states
  duration, window and speed. `view_video` accepts `start_seconds` and
  `end_seconds` to watch a section at normal speed. Renditions are cached in
  `video_renditions` by source content, envelope and window, so repeated views
  send identical bytes.
- **Per request**, trigger and quoted videos take the budget first, then images
  in priority order. Before each model round the turn's oldest media are
  replaced by a text note until the request fits `vision_tokens`. If the
  server still answers `media_budget_exceeded`, the round is retried once
  without media.

`attachment_reserve` defaults to at least `vision_tokens` so media fit inside
the input window beside the text budget.

With `services.max.videoAcceleration.device` (for example
`/dev/dri/renderD128`), the NixOS module binds that VA-API render node into
the service and renditions decode, drop frames and scale on the GPU. Only the
kept frames are downloaded for x264, so quality and token counts match the
software path. The hardware path applies rotation itself, and any failure
falls back to software decoding. The `video rendition prepared` log records
the decoder. On h610's Arc A380 this cuts CPU time by 6–10×, and HEVC sources
finish about 3× sooner.

| Capacity | Target |
| --- | --- |
| Raw history collection/high watermark | `W / 2` |
| Raw tail retained by automatic historian | `W / 4` |
| Episode summary injection | `W / 8` |
| Memory candidates per subject | `max(1, W / 32 / 364)` entries |
| Read page text budget | `W / 32`, transport guard at 16,384 estimated tokens |
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

## Prompt layout and cache boundaries

The prompt is ordered by how often each part changes, so the provider's prefix
cache covers as much as possible: system prompt, then the tool definitions,
then pins and episode summaries, then the append-only raw transcript, and
last the per-turn blocks (recent work turns, environment, memories, quoted
context, current message). Ordinary foreground turns list the same tools
whoever speaks; `arm_monitor` is visible to every initiator and still rejects
arming below group admin. Every tool description ends with its result shape
(`返回：`), used by native calls and code mode alike; the shapes live in
`Max.Tool.Returns`, outside the schema hash.

The user message carries `CacheBoundary` markers after the summaries and after
the transcript. A profile with `prompt_cache_breakpoints: true` sends them as
prefix-cache hints (`prompt_cache_breakpoint` for NInfer's OpenAI protocol,
`cache_control` for Anthropic); every other profile receives the unsplit
text. Each marked part ends in a newline and the next begins with a block
header, so the boundary is a token boundary. Hybrid attention models can only
resume from an exact checkpoint, so these markers are what let a new turn
reuse the summaries and the transcript it shares with the previous one;
whether the server keeps them depends on its own cache capacity.

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
