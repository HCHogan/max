# The ledger

The ledger is the record of conversations: every message said by anyone,
Max included, unified into one message format (see
[Message format](#message-format)), append-only. A conversation's
messages, in the order the conversation actor entered them, form its
timeline. The ledger answers "what happened in the group".

- A message holds its conversation, sender, content, raw payload,
  platform id, sequence number and time. The platform ids of what Max
  sends are in `deliveries` instead; see [Outbound](#outbound).
- What Max's model says carries its turn id and a segment number.

What Max does behind the scenes, how the model thinks and which tools it
calls, isn't in the ledger. There are three references between the ledger
and turns: a message Max's model said points to its turn; a turn points to
the message that triggered it; follow-up input references its messages. A
later turn's base context is projected from the ledger and the memory
file, never from other turns' transcripts; see
[Context projection](context.md).

## The timeline

A conversation's rows, ordered by id, are its timeline. Every ordering
question in the execution model is settled by one rule: **the conversation
actor is the only writer of the timeline, and everything else reads at
some position on it.**

- The actor enters messages one at a time, each committed before the next
  event is handled. Within a conversation, the order of ids, of commits and
  of handling are the same, and a position is simply a message id.
- On the timeline: other people's messages and events (edits,
  retractions), commands, every segment Max says, and everything Max does
  in the chat. All of it goes through the actor: the chat's connection only
  normalises and the sender only sends; a tool that says or does something
  sends the actor a `Post`.
- Not on it: platform receipts (in `deliveries`) and what Max did behind
  the scenes (in [turn records](#turn-records)).

The actor tracks three positions:

| Position | Meaning | Used for |
| --- | --- | --- |
| `head` | The last row on the timeline | The snapshot position when a core starts |
| `from` | The current core's snapshot position | The base context projects rows up to `from`; every row after it is fed to the core |
| `seen` | The last row that went into a model request | Whether an intent `Wake` is void |

What follows:

- **The core's input has neither duplicates nor gaps.** When a core
  starts, `from = head`; every row entered after that is fed to it, except
  what Max's account said or did through a tool. The core sees "the
  snapshot at `from`, plus every row after it" by definition, not by
  timing.
- **`seen` is easy to keep.** Rows are fed as soon as they are entered, and
  a request includes every waiting input, so a request sent holds exactly
  `..=head`, and `seen = head` is set then. `/kill` and startup set it too.
  See [Intent](intent.md).
- **Workers keep a cursor per conversation.** Within a conversation the
  order of ids is the order of commits, so a cursor moving forward can't
  miss a smaller id committed late. Across conversations there is no such
  guarantee, so there is no global cursor.

## Message format

One format, read alike by projection, search and memory, with no branch by
platform. It keeps the core idea of the Haskell version's
[ADR 003](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/003-message-ir-capability-rendering.md)
without its type machinery.

Each message stores two things:

- **Nodes**: text, mention, emote, media, card, forward and unsupported.
  Every non-text node carries its text fallback from the moment it is
  stored (a mention's display name, a media item's caption, a card's
  summary), so downgrading it anywhere later needs no lookup.
- **The raw payload**, exactly as the platform sent it. It is the source of
  truth: the nodes can be rebuilt from it if the normaliser changes, and a
  future mirror would need it for native round trips. The nodes are a
  cache shared by every reader. Rows read back carry only its `said_by`
  (who spoke for Max's account; see [Outbound](#outbound)).

Nothing is downgraded on storage. Each boundary has a type of its own:

```rust
// The adapter's output: platform-native ids, no database access
struct Inbound { /* ... */ }

// The stored format, converted from Inbound by the actor inside the transaction that enters it
struct Message { nodes: Vec<Node>, raw: serde_json::Value, /* conversation, sender, ... */ }

enum Node {
    Text { text: String },
    Mention { target: MentionTarget, display: String }, // an identity, or everyone
    Emote(Emote),                                       // a platform emote, its name the fallback
    Media { media: Option<MediaRef>, meta: MediaMeta },
    Card(Card),
    Forward(ForwardRef),
    Unsupported(Unsupported),
}

// What the model can write in a message: text and mentions
struct Draft { reply_to: Option<MessageId>, nodes: Vec<DraftNode> }

enum DraftNode {
    Text { text: String },
    Mention { principal: PrincipalId }, // resolved to an account on the destination platform when sent
}
```

- Each adapter writes its own lowering from `Draft` to its native message;
  there is no general downgraded type.
- The text shown to the model is rendered from a `Message` by a function,
  not stored as a type.
- The model mentions people by principal handle, resolved to an account at
  send time, following the Haskell version's
  [ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md);
  see [Identity](identity.md).
- The model side's entries follow the same approach: an `Item`'s `kind` is
  a node, its `opaque` the raw payload, and the protocol adapters'
  downgrading the lowering at send time; see [Entries](#entries).

Mirroring between chats is deferred with Matrix
([decisions/matrix-deferred.md](../decisions/matrix-deferred.md)).
It would add a capability table (for each endpoint and node kind: native,
text or dropped) and downgrade records. The raw payloads, the text
fallbacks, `deliveries` (one row per endpoint) and the dropping of echoes
are already what it needs, so it would need no data migration.

## How replies are written

The model's text is cut into `Draft`s by the segmenter in `max-core`. It
is the only place where model text becomes messages, progress narration
included: in the Haskell version, every send path that wrote its own
conversion eventually leaked `[split]` or `[reply#id]` into the group.

Cutting:

- Blank lines separate segments, and each segment is one message; blank
  lines inside code blocks don't cut. `[split]` forces a cut, with no limit
  on the number of messages.
- Once a Markdown heading (`#` to `######` and a space) appears, cutting is
  by section: each heading starts a message, blank lines no longer cut, and
  a section is sent whole with its tables and lists. Text before the first
  heading is still cut at blank lines. A thematic break (`---`, `***`,
  `___`) cuts wherever it is and isn't sent. Without this, a long Markdown
  answer came out as a lone heading, a lone table and an empty-looking
  `---`.
- A `[reply#id]` at the start of a line (indentation aside) starts a new
  message and ends cutting by section, back to blank lines; one in the
  middle of a line doesn't cut. So a jab at someone after a document
  doesn't become part of its last section, sent as a reply to that person.
- A message can begin mid-line: what follows `[split]` or an image handle
  is judged as a new line, and what follows a `[reply#id]` at the start of a
  line is what QQ shows as the message's start, so fences, headings and
  thematic breaks are judged by it. (Otherwise ````看代码：[split]```bash````
  would read the fence as body text.)
- A quote with nothing after it applies to the next message with content:
  in `[reply#3] ---`, or a `[reply#3]` alone on a line before a blank line,
  the quote waits for the next message, across blank lines and thematic
  breaks; a next message with a quote of its own uses that one; with
  nothing following, the quote is dropped. Images can carry a quote. The
  splitter's `cut` doesn't cut a segment that holds only a quote; lines
  that begin with a quote use `cut_for_quote`, which does, and the new quote
  replaces the old.
- A `<think>` outside code begins a reasoning segment, which runs to its
  `</think>` (or the end) and is never sent. A `<think>` inside a fence or
  inline code is Max showing the tag and is sent as it is; a fence inside a
  reasoning segment is part of the reasoning and opens nothing.
- Cutting looks only at the text, not at when streamed text arrives: the
  same output gives the same messages streamed or whole.

Placeholders:

- One form, `[type#id]`, optionally followed by `: description` and an
  immediately following `(attributes)`; only the id is significant. Words
  rather than symbols or sentences, since the model repeats sentence-like
  marks aloud and doesn't repeat `[unsend#id]`.
- `[reply#id]` at the start of a segment: the segment replies to that
  message; with several, the first is used and all are removed. For an
  invalid number, see [Resolution and sending](identity.md#resolution-and-sending).
- `[mention#N]` mentions a person; see
  [Resolution and sending](identity.md#resolution-and-sending).
- `[sticker#id.index]` and `[image#id.index]` each make a message of their
  own, which sends that image; see [Sending images](media.md#sending-images).
- Max can't send QQ face emoticons (the official API can't): a
  `[face#id]` the model writes by imitating the history, or a display form
  such as `[face: name]`, is removed. Received ones are shown to the model
  as `[face: name]`.
- An empty output, or one of only `[silence]`, sends nothing; a quote at
  the start of a segment doesn't change that. With other content,
  `[silence]` is simply removed. `[silence:表情名]`, from the Haskell
  version's reactions, counts as `[silence]`.
- A tool call written into the body, such as `[find_stickers query="无语"]`
  (a bracketed English identifier and whitespace followed by `=` or a
  quotation mark), is removed, except inside code.

While the core is awake, every message in the group reaches it as
`[新消息]`, so the prompt has it answer only what is addressed to it:
messages that @ it, reply to it or name it, and those a `[判定 …]` line
points to. It doesn't cut into other people's exchanges or answer
questions put to others, and told to be quiet, it outputs `[silence]`.

## Outbound

What Max says is **entered in the ledger as soon as it is said**: the
segmenter in the model call's task cuts out a segment and hands it to the
actor as `Said`, and the actor enters it and hands it to the platform
sender, without waiting for the receipt. A tool's picture or file and
actions such as retractions are entered first and sent afterwards too;
mutes aren't entered (see [The official QQ bot](qq.md)). So on the
timeline Max's words are ordered as Max saw things, though they may land
on the platform in the other order; and a new core's tail always holds what
the old one said.

- **The platform sender**: one resident task per platform. A
  conversation's items are sent in ledger order, one at a time; different
  conversations are served concurrently. Retracting one of Max's messages,
  or replying to one Max just sent, is queued behind it, so its platform id
  is known by then.
- **`deliveries`**: one row per send: message, endpoint, platform id or
  error, status, time. The sender is its only writer and only appends. An
  action such as a retraction has no platform id; a successful one is
  recorded as sent without one.
- **Finding a `#id` from a platform id**: inbound messages' are in
  `messages`, Max's are in `deliveries`. When someone replies to or
  retracts one of Max's messages, the actor looks in both as it enters the
  event, and falls back to the text if neither has it.
- **Failed sends** get a row with the error, and projection follows the
  message with `（没发出去）`, which the next core sees. The running core
  isn't told: repeated failures in a turn usually mean the connection is
  down, and the model could do nothing about it.
- **After a crash**, messages entered but without a receipt are recorded
  by the sender at startup as unknown, and projection marks them
  `（可能没发出去）`. They aren't resent, to avoid sending them twice.
- **Echoes**: the QQ gateway doesn't push the bot's own messages, so there
  are none. A platform that does would get an id such as
  `max-<message id>` on each send, for its adapter to recognise and drop;
  an action the platform reports back would be checked against the timeline
  before it is entered. What this process didn't send (someone using Max's
  account by hand) is entered as usual, with Max as sender.
- **`Post`**: everything sent that isn't the model's text is a `Post` to
  the conversation's actor, which enters it: what tools say, send or
  retract. A `Post` names no turn. Every tool is called from the VM, where
  the host doesn't tell a turn's program from any other, so the row has no
  `turn_id` and is marked as a program's, `程序发的`; nothing is refused for
  coming from a turn that has ended, and a turn killed while its program
  runs may see one more thing said before the program's unit stops.
  - Where the caller needs to know whether the send worked, the `Post`
    carries a reply channel that the actor hands to the sender, which
    answers after recording the `deliveries` row; the actor doesn't wait.
  - A `Post` of `Act::Queue` (`send_file`) is answered as soon as its row
    is entered, and the sender gets no reply channel: an upload can take
    minutes, longer than a call may wait, and whether it went out shows in
    the records like any message.
- **Command output** doesn't go through `Post`: the actor enters it in the
  conversation where the command was given, without quoting the command.
  (QQ offers no way from a group's `member_openid` to the person's private
  `user_openid`, and only trial users have private chats anyway.)

## Turn records

A turn is one continuous run of a core: it starts when a trigger starts a
core and lasts until the idle window runs out, a `/kill`, a failure or a
restart; the triggers it takes in along the way are all its input. It has
two records, both append-only:

```rust
// When a trigger starts a core
struct TurnStarted { turn, conversation, ordinal /* t#N, for the model to cite */, trigger: Wake, from /* the snapshot position */, started_at }
// When it ends: the outcome and the whole run; a turn lost in a crash has no run
struct TurnFinished { turn, outcome: Outcome, run: Option<RunRecord>, finished_at }

// What a run leaves: what the model was shown and what it said
struct RunRecord { spec: RunSpec, base: Context, transcript: Vec<Item> }

enum Input {
    Messages { ids: Vec<MessageId>, item: Item, people: Vec<PrincipalId> }, // rows on the timeline, what the core saw of them, and people it hadn't seen
    Wake(Wake),
}

struct Wake {
    ids: Vec<MessageId>,  // the rows it is about, voided ones already filtered out
    reason: Reason,       // Direct, Judged { note }, Program, Asked, Answered
    item: Option<Item>,   // the verdict line, a program's words, a question or an answer; None for a direct trigger, whose rows are marked already
}

enum Outcome { Answered, Silent, Interrupted, Failed { reason: FailReason }, Lost }
```

| When | What is written |
| --- | --- |
| A trigger starts a core | `TurnStarted` (`turns`) |
| The turn ends, an interruption at a restart included | `TurnFinished` with its run (`turn_outcomes`) |
| A crash | nothing; a `Lost` outcome is added at startup |

- **The trigger is in `TurnStarted`**: a direct trigger could be derived
  from its message, but a verdict, the messages a debounce merged or a
  program's wake couldn't.
- **One snapshot per turn**, written at the end in the outcome's row. The
  core writes nothing midway, so there is never one copy in the database
  and another in memory.
- **Status**: a turn with a `TurnFinished` has ended; one without is
  running in this process, and one seen at startup was running at a crash.
- **The outcome** is the only derived result stored, since finding which
  turns haven't ended depends on it. `Answered` and `Silent` say only
  whether the run said anything. `Lost` is written at startup for a turn
  that was running at a crash, and has no run.
- What Max said is in the ledger, not the outcome.

## Entries

The base context, the transcript and requests are made of entries:

```rust
struct Item {
    kind: ItemKind,
    source: Option<ModelTag>,          // for a model's entries: the protocol and the model
    opaque: Option<serde_json::Value>, // the provider's opaque fields, carried and never interpreted
    tokens: u32,                       // estimated by max; for model output, the provider's usage
}

enum ItemKind {
    Text(String),
    ToolCall(ToolCall),
    ToolResult(ToolResult),
    Reasoning { text: Option<String> }, // the readable part: a summary or plaintext reasoning
    // ...
}

struct ModelOutput { items: Vec<Item>, usage: Usage /* with the reasoning tokens */ }
```

Reasoning:

- **Responses**: requests carry `store: false` and
  `include: ["reasoning.encrypted_content"]`, and never rely on
  `previous_response_id`. Each `reasoning` item is one `Reasoning`: `opaque`
  is the whole raw item, `encrypted_content` included, and `text` its
  summary.
- **Chat**: `reasoning_content` (or `reasoning`) is one `Reasoning`.
  Signatures on tool calls (Gemini's, through cliproxy) go into that
  `ToolCall`'s `opaque`.
- **Reasoning written into the body**: a `<think>…</think>` at the start
  is split off into a `Reasoning`. A body that begins with a heading on a
  line of its own, such as `Thinking Process:`, `**Thought Process**` or
  `思考过程：`, isn't said at all: the call fails with `Error::Aloud`, which
  is retryable, and the task sends it again. Whether a real answer follows
  such a heading can't be told, and once one leaked, the model took it for
  its own style and did it again.
- **Reasoning belongs to its turn**: it is in the transcript and the
  snapshot, never in the ledger, a later base context or the group, and
  tools such as `history` can't read it.
- Reasoning cut off midway through a stream isn't stored: an incomplete
  blob is of no use.

## Schema

The schema was designed afresh rather than carried over from the Haskell
version, which after 135 migrations had two conversation keys, three
kinds of message id, four copies of the message body, 31 tables no code
read and migrations undoing one another.

### Conventions

- **One key per entity.** A conversation has only `conversation_id`; a QQ
  group appears only in `endpoints.native_id`. A message has only `id`,
  which within a conversation is the order of entry (see
  [The timeline](#the-timeline)) and is the model's `#id`. A platform's
  native id is an attribute, unique per `(endpoint_id, native_id)`:
  inbound ones in `messages`, Max's in `deliveries`. A person has only
  `principal_id`; platform accounts are `identities`.
- **JSONB holds three kinds of data**: `nodes`, `raw`, and blobs stored and
  loaded whole (runs, `opaque`, tool output). Everything else is columns.
- The ledger and the turn records are append-only
  ([principle 1](../architecture.md#principles-of-the-data-and-execution-model)).
- Naming: the primary key is `id`, foreign keys `<table>_id`, times
  `timestamptz` named `*_at`.
- Migrations are append-only. An applied migration is never edited, not
  even a comment: sqlx checks its checksum.
- No source hash and no CAS cursor.
- Id columns are `generated by default as identity`, which let the import
  write the old ids.
- All queries are in `max-db` and take a `&mut PgConnection`; the caller
  decides which writes share a transaction. A query that needs several
  statements to agree opens its own transaction, a savepoint inside the
  caller's.
- The `.sqlx` offline metadata is in `crates/max-db/.sqlx`, and the Nix
  build sets `SQLX_OFFLINE=true`. After changing a migration or a query,
  run `scripts/prepare-queries`, which rebuilds the development database
  and regenerates it.
- Vectors use pgvector, which isn't a trusted extension, and `maxx` isn't a
  superuser: the NixOS module creates it as postgres in
  `postgresql-setup`, and the migration's `create extension if not exists
  vector` does nothing. A database dropped and recreated needs it again;
  restarting `postgresql-setup` is enough.

### Tables

| Area | Table | What it holds |
| --- | --- | --- |
| Platform | `conversations` | Kind (group, direct), title (a group's name on QQ, asked for when its actor starts; a private chat's is the other party's name where the platform gives one, which QQ doesn't), and `tail_after`, where the raw tail starts (see [Rules for a stable prefix](context.md#rules-for-a-stable-prefix)) |
|  | `endpoints` | Conversation, platform, `self_identity_id` (the account Max uses), `native_id`. A conversation has one endpoint; mirroring would give it several. `native_id` is the adapter's string: `group:<group_openid>` or `c2c:<user_openid>` for QQ; imported old QQ endpoints (platform `qq_legacy`) are `group:<group number>` or `private:<QQ number>` |
|  | `principals`, `identities` | People, and their accounts on each platform. Each actor creates them as it enters messages; see [Identity](identity.md) |
|  | `conversation_settings` | Mutable: `model`, `effort`, `persona`, `proactive`, `stopped` (`/stop`), `cleared_upto` (`/clear --all`) and `overrides` (what `/config` set; see [Settings a conversation sets](config.md#settings-a-conversation-sets)) |
|  | `links` | Which conversation's Max may ask which other's: asker, asked, time. `/link` adds a row and `/unlink` deletes it; see [Asking another conversation](jobs.md#asking-another-conversation) |
| Ledger | `messages` | Conversation, endpoint, `sender_identity_id` with snapshots of the sender's name and role, `native_id`, `sent_at`, `received_at`, kind (chat, command, event), `reply_to`, `nodes`, `raw`, and `text` (rendered, for search, with a trigram index on `lower(text)`; see [Recall](context.md#recall)). What Max's model said carries `turn_id` and a segment number. Retractions and edits are rows of kind `event`, whose `event` column says which, with `target_id` and a text fallback; an edit's new content is in `nodes`. Only the actor writes it |
|  | `deliveries` | Outbound receipts: message, endpoint, platform id or error, status (sent, failed, unknown), time. Only the sender writes it, appending |
| Media | `media` | By sha256: MIME type, size, width and height, when first seen, and the sha256 of the version for the model. The kind is in the message's node, since the same bytes may be a picture in one message and a sticker in another. See [Media](media.md) |
|  | `message_media` | Message, ordinal, sha256. An inbound node holds a download URL, and the file is recorded here once downloaded; a picture a program handed over (`tools.show()`) has its sha256 in the node |
|  | `media_captions` | One row per sha256, written once: the prompt used (image or sticker), the text (empty if the model gave up), `skip` (pictures that don't look like stickers, kept out of the sticker library) and the model (empty for imported captions). Only the caption worker writes it. Queries that read rows fill captions into media nodes without a description. See [Media](media.md) |
|  | `caption_embeddings` | One row per sha256: a sticker caption's `vector(1024)`, its model, time. Only the embedding worker writes it; after a change of model it recomputes them all, and search compares one model's vectors only. See [Sending images](media.md#sending-images) |
|  | `message_embeddings` | One row per message: conversation, a `halfvec(1024)`, its model, time. Only the recall vector worker writes it, recomputing all after a change of model. See [Recall](context.md#recall) |
| Turn | `turns`, `turn_outcomes` | See [Turn records](#turn-records). `t#N` is `turns.ordinal`, counted from 1 in each conversation |
|  | `llm_usage` | Turn (nullable), purpose (turn, intent, caption), provider, model, effort, tokens (bigint, with cache hits and reasoning tokens), `cost_micros` (millionths of a US dollar, null while the price is unknown, as it so far always is: `/status` works the cost out from the tokens and the configured `price`), and three timings: `first_ms` to the first output of any kind, `took_ms` to the end, and `quiet_ms`, the longest stretch with nothing arriving, which is what `stream_idle_timeout_secs` cuts off; check it before lowering that timeout. Turns, `complete`'s calls (intent, caption) and the agents' calls through the forwarder (see [Background agents](jobs.md#background-agents)) are all recorded |

Tables kept with their rows but no longer read or written:
`summaries`, `summary_runs` and `summary_embeddings`, from the historian
([decisions/no-summaries.md](../decisions/no-summaries.md)),
and `llm_usage` rows of purpose `historian`. `llm_usage` rows of purpose
`job`, a background agent's calls, are no longer written
([decisions/forwarder-keeps-no-count.md](../decisions/forwarder-keeps-no-count.md));
`/status` sums those its window still holds.

## Import

The Haskell version's database was imported once, with message ids,
people and captions carried over, so the `#id`, `[image#id.n]` and
`[mention#N]` handles in old memories still resolve. How, and what became
of each old table, is in [archive/import.md](../archive/import.md).
