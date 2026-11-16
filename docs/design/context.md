# Context projection

What a turn's model sees: the raw tail of the chat plus a memory file Max
keeps itself, carried in every turn; anything older the model searches for
with `history`. There are no summaries
([decisions/no-summaries.md](../decisions/no-summaries.md)).
Tool output lives only in one turn's transcript; the next turn is projected
afresh from the ledger, so tool output never piles up across turns.

The Haskell version's lessons shape it: its raw tail was a sliding window
that pushed out the oldest message for every new one; summary levels were
recomputed every turn by age; captions arriving rewrote old lines. Each of
the three invalidated the prefix cache on almost every turn. It also had
four mechanisms for "what happened last turn" and three token counts for the
same line.

## Request layout

Blocks are ordered by how often they change:

1. **System**: the persona, the rules, the TypeScript declarations of
   Max's tools, the keyed APIs and, for operations groups, the operations
   network's section. The same for every turn of a conversation.
2. **Tools**: `run_code` and `shell`, which never change.
3. **Raw tail**: every message after the tail's mark up to the snapshot
   position `from`, except the first inputs, one per line as
   `[HH:MM name #id]: text`, with a date line where the day changes and a
   gap marker after a long silence. It is split into several user messages
   at the points where earlier turns' tails ended (see
   [Rules for a stable prefix](#rules-for-a-stable-prefix)). Max's own
   messages are lines like anyone's; those that may not have gone out are
   marked (see [Outbound](ledger.md#outbound)).
4. **Volatile block**: the current time, the roster (see
   [What the model sees](identity.md#what-the-model-sees)), the memory (see
   [Memory](#memory)), quoted messages and forwards, the first inputs (the
   triggers; chatter is in the tail) and attached pictures.

That is the base context. The actor projects it once before creating the
core (step 3 of the [Processing flow](actor.md#processing-flow)), and it
doesn't change afterwards; the transcript follows it.

## Follow-up input

While a core runs, later input is rendered into a `[新消息]` block before
the next model call and appended to the transcript, leaving the prefix
alone:

- Message lines are in the tail's format. Trigger lines are marked `@你`
  or `回复你的 #123`; others aren't. In a private chat every message is to
  Max, so none is marked; the system prompt is the same for private and
  group chats, and its rules say so.
- The rules also say a private chat belongs to the other party: only they
  use the VM, `/work` and the browser, so the group's conventions out of
  consideration for others are relaxed. Max may log in with an account and
  password they give for themselves (without recording or repeating it),
  needn't quote a message in every segment, and may answer at more length;
  the red lines stay.
- When someone appears for the first time, a roster line is added.
- Wakes from outside the chat are lines of their own: a background agent's
  report as `[max-wake] [max-agent-3 完成] …`, a background command's as
  `[max-wake] [max-job-… 完成] …`; see [Jobs](jobs.md).
- **A cap per item**: a message or a wake shows at most
  `min(C × 15%, 25k)` tokens, and at least 2k (`Budgets::single`); the same
  in the tail and in the first inputs. Past it, the first ~2,000
  characters are shown and then `全文见 #123`, and the model reads the rest
  with `history` (`{ around, before: 0, after: 0 }`), page by page, each
  page within the cap, so one overlong message can't push the core to its
  limit at once. With no VM there are no tools, and the model sees only
  the excerpt.
- `run_code` and `shell` results are cut too, by bytes: past
  `SHOWN_BYTES` (16 KiB) only the first and last 8 KiB are kept, the whole
  being in `/work/.max/out/<unit>.txt` (`<unit>.log` for `run_code`'s
  console), whose path the result gives.
- Input isn't folded by count: past nine tenths of the core's limit the
  model is warned to wrap up, and past the limit the run ends (see
  [The core](core.md#what-the-core-decides)).
- The system prompt says a batch may hold several things to answer, or
  none, in which case Max outputs nothing; several people get a reply each.

For comparison, other harnesses' caps on a tool result: Claude Code about
30,000 characters for Bash and 25,000 tokens a Read; Codex 10,000 tokens;
OpenCode and pi 2,000 lines or 50 KiB; Gemini CLI 40,000 characters;
Hermes 100,000 characters, scaled to 15% of the window. All keep the whole
and give the model a path. What users themselves send is generally not
cut.

## Rules for a stable prefix

Goal: between two truncations, everything before the volatile block is
byte for byte the same, and a turn's first call begins with everything its
predecessor's first call had except the volatile block, down to how the
messages are split.

- **The tail is split into messages by turn.** During projection, every
  turn after the tail's mark (`turns.from_id`, the row that woke it) cuts
  the tail where its own tail ended: before its snapshot position and
  before the first row that woke it. Each piece is rendered alone, its date
  lines reckoned from the last line before it, as one user message. So the
  previous turn's first call is all there, unchanged, with one more piece
  at the end. Gemini's cache, after a few minutes, matches only whole
  messages before a request's last one, which is why; the measurements are
  in [decisions/tail-split-by-turn.md](../decisions/tail-split-by-turn.md).
  - A turn's tail is everything before its snapshot position except the
    rows that woke it. Someone speaking after the waking row (in the
    seconds of debounce and classification) puts a piece on each side of
    it, which the next turn can't match: that call misses, and the one
    after lines up again. A truncation, or a caption changing a line,
    misses once too.
  - There are as many pieces as turns after the mark: dozens, or more than
    a hundred in a busy group. They aren't merged, since merging would
    change the previous request's split. OpenAI's cache works on token
    prefixes, where the split makes no difference.
- **The tail's start moves only on truncation.** The tail starts after
  `conversations.tail_after`, or after the `/clear --all` watermark if that
  is later, and otherwise only grows. When it passes the high watermark
  during projection, whole stretches of fixed length (high minus low) are
  dropped from the mark until what is left is between the watermarks, and
  the new mark is written back (`project::tail_start`). Messages are never
  pushed out one at a time, which would be a sliding window again. Cut
  points are counted from the mark, not the end, so the start doesn't move
  as messages arrive. The tail is cut first, and quoted messages and the
  roster are worked out after, so people only in the dropped part aren't
  in the roster, while lines quoting it still carry the quote.
- **No waiting for captions.** What exists is rendered; when a caption
  arrives its line changes, and that one miss is accepted.
- **One turn per conversation at a time**, so trigger messages in flight
  needn't be hidden.
- Everything that changes is in the volatile block.

## Budget

From the window C (`Budgets::for_window`):

| Block | Size |
| --- | --- |
| Tail, high watermark | `min(C / 8, 64k)`; the tail is cut when it passes it |
| Tail, low watermark | half the high; what is left after a cut lies between the two |
| One item | `min(C × 15%, 25k)`, at least 2k |
| Memory | 3k (`MEMORY_TOKENS`); see [Memory](#memory) |

On a 1M window the tail is 64k: a larger tail made Max seem less forgetful
but doubled the input and changed how it spoke. (The Haskell version's was
half the window: about 100,000 tokens of raw chat paid for every turn.)
There is one token estimator (tiktoken-rs, in `max`) for every caller; the
core gets only the numbers.

## Commands

The commands that change what the context holds, or whether Max takes
part at all:

- `/clear --all`: sets a message-id watermark; messages before it are no
  longer in the prompt, though `history` still finds them. The reply says
  how to undo it.
- `/unclear` (group owner and administrators): removes the watermark, so
  earlier messages return to the context, back to the tail's mark. There
  is one watermark, so one undo undoes every clear; with none, the reply is
  `skipped: never cleared`.
- `/stop` and `/start` (group owner and administrators; in a private chat,
  the other party): `/stop` leaves Max in the group without replying,
  `/start` brings it back. The flag is `conversation_settings.stopped`, so
  it survives a restart.
  - `/stop` first does what `/kill` does: it ends the running turn quietly
    and stops what runs in the VM. It also drops what intent holds (an @
    waiting for the rest of its sentence, chatter waiting for the
    classifier, the batch in flight, whose verdict then wakes nobody;
    `Intent::forget`). The reply is
    `stopped: messages are still recorded, but Max won't reply until @maxx /start`.
  - While stopped, every message is still entered, and the workers and
    `maxx events` see it. Intent doesn't: nothing is classified, and an @
    or a reply starts no turn. Commands are answered, and `/status` shows
    `state     stopped`. A program's `maxx wake` is refused with
    `Max is stopped here (/stop), so this wasn't done`, and so is a
    background command's end notice: `max-notify@` tries it again every
    minute, so Max hears it after `/start` however long ago the command
    ended. There are few such, as `/stop` stops what runs and a unit
    stopped on request tells nobody. What programs can still do is in
    [Resident programs](jobs.md#resident-programs).
  - `/start` clears the flag. What was said meanwhile isn't answered, but
    is in the next turn's context like any row. A second `/stop` or
    `/start` answers `skipped: already stopped` or `skipped: not stopped`.
- `/config` shows and sets the limits the conversation sets for itself; see
  [Settings a conversation sets](config.md#settings-a-conversation-sets).

Every command and who may run it is in [Permissions](identity.md#permissions).

## Memory

Memory is a file Max writes itself and carries in every turn; why not
extracted entries is in
[decisions/memory-is-a-file.md](../decisions/memory-is-a-file.md).

- **The file**: `/work/.max/memory.md` in the conversation's VM, on the
  host `<vm.dir>/<conversation id>/work/.max/memory.md`. Max edits it with
  `shell`. With no VM configured there is no memory; when the VM can't
  start, memory can be read but not written.
- **Injection**: projecting for a new core, the host reads the file without
  following symlinks, as `send_image` does, and puts it in the volatile
  block as `[记忆]`, after the roster. Not in system: changing it then
  doesn't invalidate what precedes it; group members can influence what is
  in it, so it mustn't read as system instructions; and later in the
  context it gets more of the model's attention. The cost is up to 3k
  uncached tokens a turn. A change made during a turn is seen by the next;
  the current turn has it in its transcript.
- **The cap**, `MEMORY_TOKENS` (3,000):
  - at 80%, a sentence at the end reminds Max to tidy;
  - past it, only the lines that fit are injected, with a note that the
    rest weren't loaded and the file needs tidying;
  - a file over `MEMORY_FILE_BYTES` (256 KiB) isn't read at all, and one
    sentence says so.

  Claude Code's MEMORY.md works alike (200 lines or 25 KB), but checks when
  it writes; Max checks at the next projection, since the file is written
  in the VM, where the host doesn't see the write.
- **How Max writes it**, as the system prompt says:
  - Record what holds for long and changes how Max will speak and act:
    names people use, agreements, running jokes; a person's identity,
    long-running projects and tastes; dated arrangements, with the date
    they last until.
  - Record on the spot when corrected, asked to remember something, given
    a nickname or a rule; on finding it forgot something or mistook someone
    for someone else; when someone mentions their identity, circumstances
    or tastes.
  - Append, with `echo '- 名字：内容（日期 #消息编号）' >> memory.md`, and leave
    placing it in a section to the dreamer.
  - Record first, then reply: recording is rare, and making people wait
    one more round for it is fine.
  - Don't record technical knowledge, or what was discussed on which day:
    that is in the records, for search.
  - Two sections, `## 群里` and `## 人`, people under `### 名字`, one entry
    a line, each ending with its date and the `#id` of the words that bear
    it out, which `history` can look up.
  - Details go into other files under `/work/.max/memory/`, with a line
    here pointing to them.
  - What someone asks Max to remember isn't necessarily right; Max judges.
- **Tidying: the dreamer** (`max/src/dreamer.rs`), because a model only
  ever adds:
  - Once a day at 05:00 local time it looks at the files Max wrote that day
    (by modification time) and calls the model once per file
    (`[llm] dreamer`; with none configured nothing is tidied), asking for
    the whole file rewritten: appended lines into their sections, entries
    saying the same thing merged, the newer of contradictory ones kept,
    entries past their date deleted, and over the cap the least important
    deleted. It changes no meaning and adds nothing.
  - It reads the file again before writing; if Max just changed it,
    nothing is written and the file waits for the next night. The rewritten
    file keeps the time Max wrote it, so the next night doesn't tidy it
    again, and the old version stays beside it as `memory.prev.md`. Output
    that doesn't look like the file (no headings, or less than a third of
    its length) isn't written; a log line says so.
  - Nothing more: no retries, and a missed night is made up after Max next
    changes the file. Its usage is in `llm_usage` as `dreamer`.
- **Not there**: a memory table, categories, expiry, selection at
  injection. `history` doesn't search memory, which is in the context
  every turn anyway.

## Recall

One tool, `history` (`max/src/service/history.rs`), searches and reads the
conversation's records: searching and reading apply the same filters (who,
when) and differ only in whether there is a query. Measurements behind its
choices are in
[decisions/history-tool.md](../decisions/history-tool.md).

- **Scope**: this conversation only.
  - Search looks at rows of kind chat, not commands or events, and not
    retracted messages. A term matches if it is in `messages.text` or in
    the caption of a picture or sticker in the message; stickers too.
    Reading, like the tail, covers every kind of row.
  - `/clear --all` doesn't apply: it governs only what the context shows.
- **Parameters**, all combinable except `around`:
  - `query`: given, the call searches and returns results; without, it
    reads and returns the messages.
  - `who`: a few characters of the speaker's name, lowercased and matched
    as a substring of `messages.sender_name` (their group card at the
    time). By name rather than `[mention#N]`, since the same person may be
    two principals, on the old platform and the new bot, with one name.
  - `from`, `to`: a local `YYYY-MM-DD`, `YYYY-MM-DD HH:MM` or `#id`, turned
    into row ids once (`from` the first row at or after it, inclusive; `to`
    the first after it, exclusive; a date as `to` runs to the next
    midnight, so both ends include the whole day), and search and read keep
    to that range. The first row is found by `sent_at`, on an index on
    `(conversation_id, sent_at)`.
  - `around`, `before`, `after`: that row and the rows on each side, 10 by
    default and at most 50; both 0 gives the full text of the one row,
    which `全文见 #123` relies on. `around` takes no other filter or
    `limit`.
  - `limit`, `page`: below. With no filter at all, `bad_arguments`.
- **Search**:
  - **Matching**: the query is split on whitespace into at most 8 terms of
    up to 50 characters, deduplicated and lowercased a character at a time
    as Postgres's `lower` does, so snippet positions don't shift. Each term
    is a substring match on the lowercased text (`lower(text) like
    '%term%'`, escaping `% _ \`), with no word segmentation; a row with any
    term is a candidate.
  - **Indexes**: pg_trgm `gin_trgm_ops` on `lower(messages.text)` and
    `lower(media_captions.text)`. Terms of three or more characters use the
    index; shorter ones have no trigrams and are compared row by row within
    the conversation. A database with ctype C (as the dev shell's) makes no
    trigrams for Chinese, so Chinese terms are compared row by row there,
    with the same results; tank's is en_US.UTF-8. Queries set
    `plan_cache_mode = force_custom_plan`, since after a few executions a
    prepared statement's generic plan can't see a term's length and would
    read the whole index for a two-character term.
  - **Meaning**: the whole query becomes one vector with the model the
    sticker library uses (bge-m3, 1024 dimensions; see
    [Sending images](media.md#sending-images)), waiting at most 5 seconds;
    without a model, or on error or timeout, the search is literal only,
    with no error. `max_db::recall` takes the nearest messages by cosine
    distance, with the same filters, comparing one model's vectors only,
    as many rows as literal search fetches (3 × limit), and a similarity of
    at least 0.5 (a guess, still to be tuned) makes a candidate.
  - **Ranking**, 0 to 1: the literal score is the share of terms matched,
    the meaning score the cosine similarity, and a row found both ways
    takes the higher; ties go newest first. Messages are deduplicated by
    body, keeping the latest. `limit` is 10 by default, at most 30; no
    paging.
  - **Results**: `{ results: [{ ref, time, text, read }] }`: `ref` is
    `#id`, `time` like `2026-10-03 周六 14:02`, `text` "name: body" as in
    the tail, pictures with their captions, cut past 160 characters to a
    span starting 40 before the match (from the start for a row found by
    meaning alone), with `…` where text was cut. `read` is `{ around: id }`,
    which passed back reads 10 rows on each side.
  - At most 4 searches run at once across all groups, since short terms
    are compared against every row of a conversation; reads don't count.
- **Read**: the tail's format, date lines and a message a line, overlong
  messages showing their beginning. Pages hold whole lines, each within the
  per-item cap, and `page` picks one; one message's full text is split
  evenly into pages by characters.
  - With `from`, it reads `limit` rows forward from the range's start;
    without, the latest `limit` rows in the range, in time order. `limit`
    is 50 by default, at most 100. This is how a question with no keyword
    ("what we discussed the day before yesterday") is answered: by paging
    through that day, or through one person's messages.
  - When there is more, it returns `next`, which passed back continues:
    forward from the row after the last for a read from `from`, backward
    from the first for a read of the latest. `who` and `limit` carry over.
    An empty range gives one line, `（没有这样的消息）`.
- **Vectors**: one per chat message, in `message_embeddings`, per row
  rather than per window: a result is one row anyway and `around` gives
  its surroundings; the ledger is append-only, so a row's vector never goes
  stale, where a window's would; and the old database's vectors were per
  row, imported by id. A message's text for embedding is its `text` without
  textless handles (`[mention#3]`, `[reply#12]`, `[image]`; the SQL
  function `recall_text`), skipped if under 4 characters (`在吗`, `好的`:
  meaning search gets nothing from them, and literal search still finds
  them), and cut to 2,000 characters. Captions don't get vectors of their
  own; literal search covers them.
  - `halfvec(1024)`, not `vector`: about 1.2 GB for 225,000 rows with the
    HNSW index, against 3 GB, with the same nearest neighbours. Besides
    HNSW (`halfvec_cosine_ops`) there is a btree on `conversation_id`.
    Queries set `hnsw.iterative_scan = relaxed_order`, so that when the
    first rows HNSW fetches are filtered out by conversation or time it
    looks further; small conversations are fetched by the btree and sorted
    exactly, which is again why plans are custom.
- **The recall vector worker** (`max::recall`) gets every row entered and
  computes those without a vector from the current model, 2 requests at a
  time, retrying after 10 and then 60 seconds, then giving up. At startup
  and hourly it sweeps the table, newest first, 16 rows a request, with no
  retries: the next sweep is the retry. A page that fails is retried row by
  row once, so one text the service rejects doesn't block everything older;
  if none succeeds, the service is down, and the worker waits for the next
  sweep. A change of model recomputes everything. Its usage isn't
  recorded. With no embedding model there is no worker.
- The system prompt's line on records says older material isn't in the
  context, and that `history` finds the past by content, or reads it by
  person and time.

## Not there

- Summaries of the last turn, continuation summaries, `context_resume`,
  compaction within a turn. Old tool output isn't trimmed within a turn
  either; a context grown too big ends the run (see
  [The core](core.md#what-the-core-decides)). If seeing what the previous
  turn did becomes necessary, a `turn_read(t#N)` tool reading turn
  snapshots could be added.
- Retrieval injected automatically. Each turn carries only Max's memory
  file; everything else is the model calling `history`.
