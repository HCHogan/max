# The ledger

## The ledger

The ledger is the record of conversations: every message said by anyone (Max included) on any platform, unified into the same message format (see [Message format](#message-format)), append-only. A conversation's messages, in the order in which the conversation actor entered them, form that conversation's timeline (see [The timeline](#the-timeline)). The ledger answers the question "what happened in the group".

- Each message holds: conversation, sender, content, raw payload, platform id, sequence number and time. The platform ids of messages that Max sends are not stored here but in `deliveries`; see [Outbound](#outbound).
- Each segment of a message that Max sends additionally carries a turn id and a segment number.

What Max does behind the scenes (how the model thinks, which tools it calls) does not go into the ledger. There are only three references between the ledger and turns: a message that Max sends points to the turn that produced it; a turn points to the message that triggered it; and follow-up input references the corresponding messages. The base context of a later turn is projected from the ledger (plus memory) and does not read other turns' transcripts; see [Context projection](context.md#context-projection-1).

## The timeline

Decided 2026-10-28. All of a conversation's rows in the ledger, ordered by id, form that conversation's timeline. Every ordering question in the execution model is settled by a single rule: **the conversation actor is the only writer of the timeline, and everything else reads at some position on it.**

- The actor enters messages one at a time, and each is committed before the next event is processed. Within one conversation, therefore, the order of ids, the order of commits and the order in which the actor processes them are the same, and a position is simply a message id.
- What is written to the timeline: other people's messages and events (edits, retractions), command messages, and every segment Max says aloud and every action Max takes. All of it goes through the actor: platform connections only normalise, and platform senders only send; when another conversation, a Max tool or the scheduler wants to send something to this conversation, it sends a request to this conversation's actor.
- What does not go into the timeline: platform receipts (in `deliveries`; see [Outbound](#outbound)) and Max's behind-the-scenes process (in the turn records; see [Turn records](#turn-records)).

The actor keeps track of three positions:

| Position | Meaning | Used for |
| --- | --- | --- |
| `head` | The last entry on the timeline | Taken as the snapshot position when a core starts |
| `from` | The current core's snapshot position | The base context projects only `id <= from`; every entry after it is fed to the core |
| `seen` | The last entry that went into a model request | Deciding whether an intent `Wake` is void |

The following results follow directly:

- **The core's input has neither duplicates nor gaps.** When a core starts, `from = head`; after that, every time an entry is entered in the ledger, the actor feeds it to the core, except for what the current turn itself has said and done, which is already in the transcript. What the core sees is "the snapshot at position `from`, plus every entry after it"; this is guaranteed by definition, not by timing.
- **`seen` is easy to maintain.** The actor feeds each entry as soon as it is entered, and the core includes all accumulated input when it sends a request, so at the moment a model request is sent, the request contains exactly `..=head`; `seen = head` is set at that moment. `/kill` and startup also set `seen = head`. For how it is used, see "Where a `Wake` goes" in [Intent](intent.md#intent-1).
- **Derived workers keep a cursor per conversation.** Within a conversation the order of ids is the order of commits, so a cursor that moves forward cannot miss a smaller id that was committed late. There is no such guarantee across conversations, so no global cursor is used.

## Message format

Decided 2026-10-27: keep the core idea of [ADR 003](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/003-message-ir-capability-rendering.md) and drop its type machinery. Context projection, search, memory and future mirroring all read the same format, with no branching by platform.

Each message stores two things:

- **Nodes**: text, mention, emote, media, card, forward and unsupported. Every non-text node carries its text fallback from the moment it is stored, such as a mention's display name, a media item's caption or a card's summary, so wherever it is downgraded later, no database lookup is needed.
- **Raw payload**: the data exactly as the platform sent it. It is the source of truth: mirroring needs it for native round trips, such as sending QQ emotes or forwards back to QQ unchanged; and if the normalizer changes, the nodes can be rebuilt from it. The nodes amount to a cache shared by all readers.

Nothing is downgraded on storage.

The Haskell version indexes a single type tree by 5 phases. Here this becomes several concrete types, each responsible for one boundary:

```rust
// The adapter's output: carries platform-native ids, does not access the database
struct Inbound { /* ... */ }

// The unified stored format, converted from Inbound by the conversation actor inside the ledger-entry transaction
struct Message { nodes: Vec<Node>, raw: serde_json::Value, /* conversation, sender, etc. */ }

enum Node {
    Text(String),
    Mention { target: MentionTarget, display: String }, // an account (identity), or everyone
    Emote(Emote),                                       // a platform emote, with its name as the fallback
    Media { media: Option<MediaRef>, meta: MediaMeta },
    Card(Card),
    Forward(ForwardRef),
    Unsupported(Unsupported),
}

// The part the model can write: text and mentions (emotes and media removed 2026-10-29)
struct Draft { reply_to: Option<MessageId>, nodes: Vec<DraftNode> }

enum DraftNode {
    Text(String),
    Mention(PrincipalId),
}
```

- For sending, each adapter writes its own `fn lower(&Draft) -> <native message>`; there is no general-purpose downgraded type.
- The text shown to the model is generated from a `Message` by a rendering function; it is not a separate type.
- The model mentions people by principal handle, which is resolved to an account on the target platform at send time, following [ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md); see [Identity](identity.md#identity-1).

**Mirroring** is deferred: it was meant to operate between QQ groups and Matrix rooms, and Matrix has been deferred (2026-10-29); see [Matrix](../decisions/2026-10-29-matrix-deferred.md#matrix). The following will all be added when mirroring is built:

- A capability table: for each endpoint and each kind of node, whether the node is native, converted to text or dropped.
- Downgrade records.

The v1 ledger already stores the raw payload and the text fallbacks; delivery receipts (`deliveries`) and the practice of dropping echoes already exist in v1, and mirroring will use them as they are, one row per endpoint; see [Outbound](#outbound). No data migration will be needed at that point.

The model side's entries (see [Entries](#entries)) follow the same approach: the `kind` of an `Item` corresponds to a node, `opaque` corresponds to the raw payload, and downgrading in the protocol adapter layer corresponds to `lower` at send time.

## How replies are written

Decided 2026-10-28, carried over from the Haskell version (see Replies in features.md). The model's text output is cut into a sequence of `Draft`s by the segmenter (in `max-core`):

- Blank lines separate segments, and each segment becomes one message; blank lines inside code blocks do not cut; `[split]` forces a cut, with no limit on the number of messages.
- Once a Markdown heading (`#` to `######` followed by a space) appears, cutting is by section (added 2026-10-30): each heading starts a message, blank lines no longer cut, and a section is sent whole, together with its tables and lists; text before the first heading is still cut at blank lines. A thematic break (`---`, `***`, `___`) is a cut point wherever it appears and is not itself sent. The reason: group members asked Max to write answers to serious questions in Markdown, and one long answer was cut into a lone heading, a lone table and a message holding a `---` that looked empty.
- A `[reply#id]` at the start of a line (indentation not counted) also starts a new message, and it ends cutting by section, returning to cutting at blank lines (added 2026-11-04); one in the middle of a line does not cut. The reason: three times between 2026-11-02 and 2026-11-04, Max finished writing a document, left a blank line and wrote `[reply#id]` to turn and make a jab at someone; the remark stayed in the last section, and the whole section, remark included, became a single message replying to that person.
- A message can begin in the middle of a line (added 2026-11-06): what follows `[split]` or an image handle is judged as a new line; what follows a `[reply#id]` at the start of a line is what QQ displays as the beginning of the message, so fences, headings and thematic breaks are judged by it. Previously only the start of a line was examined, and a fence such as the one in ````看代码：[split]```bash```` ("look at the code:") was treated as body text: the code was cut at blank lines, a `# 注释` ("# comment") in the code became a heading, and the closing fence was taken for an opening one, so everything after it became a single message.
- When a quote has nothing after it, it applies to the next message (decided by the owner 2026-11-07): in `[reply#3] ---`, or with a `[reply#3]` alone on a line followed by a blank line, the quote is kept and sent with the next message that has content, whether a blank line or a thematic break lies in between; if the next message itself begins with a quote, it uses its own, and if nothing follows at all, the quote is dropped. Images can carry a quote as well. Previously a thematic break was dropped together with the quote before it, and a quote alone on a line became a message of its own from which `parse` could produce no message; in both cases the next message quoted nothing, and it was no longer apparent whom Max was replying to. The splitter's `cut` does not cut a segment that holds only a quote; lines that begin with a quote use `cut_for_quote`, which cuts even such a segment, and the new quote replaces the old one.
- A `<think>` in code is sent as it is (changed 2026-11-07): a `<think>` inside a fence or inline code is Max showing the tag and does not count as the start of a reasoning segment. Previously a `<think>` anywhere started a reasoning segment that ran to the end if no `</think>` followed, so when Max wrote a `<think>` in code, the rest of the reply was lost. A fence inside a reasoning segment is part of the reasoning and opens nothing.
- Placeholders have a single form, `[type#id]`, optionally followed by `: description` and an immediately following `(attributes)`; in every case only the id is significant (changed 2026-10-28, carrying over the form the Haskell version unified on in 2026-08). The earlier `[↩#id]` and `[@#N]` were symbols, and forms such as `[撤回了 #id]` ("retracted #id") were sentences, which the model would repeat aloud; it does not do so with `[unsend#id]`.
- A `[reply#id]` at the start of a segment: the segment replies to that message; when a segment contains several, the first is used and all of them are removed. For what happens when the number is invalid, see [Resolution and sending](identity.md#resolution-and-sending).
- `[mention#N]`: mentions a person; for the resolution rules, see [Resolution and sending](identity.md#resolution-and-sending).
- Max writes text, mentions, and handles for images and stickers (decided 2026-10-29, changed the same day). The official QQ API cannot send QQ face emoticons (see [The official QQ bot](qq.md#the-official-qq-bot-1)): a `[face#id]` that the model writes by imitating the history, or a read-only display form such as `[face: name]`, is recognised by the segmenter and removed, so that it does not leak into the group verbatim. Face emoticons received are shown to the model as `[face: name]`. `[sticker#id.index]` and `[image#id.index]` each form a message of their own, and what is sent is that image; see [Sending images](media.md#sending-images).
- While the core is awake, every message in the group goes into its `[新消息]` ("new messages"), so the prompt tells it to reply only to what is addressed to it: messages that @ it, reply to it or call it by name, and the messages that a `[判定 …]` ("verdict …") line points to. It is not to cut into conversations between other people or answer questions put to others, and when told to be quiet it outputs `[silence]` (added 2026-10-29: after one classification woke it, it replied both to a question put to someone else and to an exchange between two group members in the same block, and when told to be quiet it talked back).
- If the whole output is empty, or consists only of `[silence]`, nothing is sent. A quote at the start of a segment does not affect this judgement. When a segment has other content as well, `[silence]` is simply removed. The `[silence:emote-name]` form taught by the old prompt (reacting to a message with an emote) is treated as `[silence]`: reactions are no longer implemented; see [Features deliberately removed](../decisions/2026-10-28-features-removed.md#features-deliberately-removed-1).
- The model occasionally writes a tool call into its body text, for example `[find_stickers query="无语"]` ("speechless"): a bracketed span consisting of an English identifier and whitespace, followed by `=` or a quotation mark, is removed. Such spans inside code blocks are left alone.
- The segmenter is the only place where model text becomes messages; progress narration goes through it as well. The lesson from the Haskell version: every send path that wrote its own text-to-message conversion eventually leaked `[split]` or `[reply#id]` into the group verbatim.
- Cutting looks only at the text, not at when streamed text arrives: the same output yields exactly the same messages whether it is streamed or given all at once. When streaming, the Haskell version also released part of a long paragraph early at the end of a sentence, which made the result depend on timing; that is not done here.

## Outbound

Decided 2026-10-28. What Max says is **entered in the ledger as soon as it is said**: the segmenter in the model-call task cuts out a segment and hands it to the conversation actor as `Said`; the actor enters it in the ledger and then hands it to the platform sender, without waiting for the platform's receipt. Images and files sent by tools, and actions such as retractions, work the same way: they are entered first and sent afterwards. Mutes are not entered; see the group management part of [The official QQ bot](qq.md#the-official-qq-bot-1). On the timeline, therefore, the order of Max's words relative to other people's messages follows Max's point of view, and the order in which they land on the platform may be the reverse; but a new core's tail is guaranteed to include what the old core said.

- **Platform sender**: one resident task per platform. Items for the same conversation are sent serially in ledger order; different conversations are served concurrently. Retracting one of Max's own messages, or replying to something Max has just said, is always queued after that message is sent, so when its turn comes the platform id is already available.
- **The `deliveries` table**: one row for the result of each send: message, endpoint, platform id or error, and time. The sender is its only writer, and it only appends. With mirroring, a message gets one row per endpoint, in this same table. Actions such as retractions have no platform id of their own; when one succeeds, it is recorded as sent without a platform id (2026-10-29, migration 0012).
- **Looking up a `#id` from a platform id**: the platform ids of inbound messages are in `messages`, and those of messages Max sends are in `deliveries`. When someone replies to or retracts one of Max's messages, the actor looks in both places as it enters the event; if nothing is found, it falls back to the text.
- **Failed sends**: a row with the error is recorded in `deliveries`, and in projection the message is followed by the mark "（没发出去）" ("(not sent)"), which the next core's model can see. The failure is not reported to the running core: repeated failures within one turn usually mean the platform connection is down, and the model could do nothing about it even if it knew.
- **Crashes**: for messages that were entered in the ledger but have no receipt, the sender first records them retroactively at startup as "result unknown", and projection marks them "（可能没发出去）" ("(may not have been sent)"). They are not resent, to avoid sending them twice.
- **Echoes**: when a platform pushes back something Max itself sent, the adapter simply drops it. The QQ gateway does not push the bot's own messages, so there are no echoes; if a platform connected later does push them back, an id such as `max-<message id>` is attached when sending, and the adapter recognises echoes by it. If platform notifications of Max's own actions are also pushed back, the actor checks, before entering one, whether the timeline already contains that action, and if it does, records nothing. Anything not sent by this process (for example, someone sending manually from Max's account) is entered as usual, with Max as the sender.
- **Sending via `Post`**: every send that is not the model's text output is a `Post` to the target conversation's actor, which enters it in the ledger: messages sent or retracted by tools called from programs (in this group or another one), and future automations. The text output of commands does not go through `Post`: the actor enters it itself, in the conversation where the command was issued, without quoting the command (changed 2026-10-29: the original proposal was to send it to the issuer's private chat, and a later one was to quote the command, which the owner found superfluous). QQ offers no way to find a person's private-chat `user_openid` from their group `member_openid`, and only trial users can enter private chats in any case. Where the caller needs to know whether the send succeeded (a tool, for example), the `Post` carries a reply channel; the actor hands it to the sender, which replies after recording the `deliveries` row; the actor itself does not wait. A `Post` of `Act::Queue` (added 2026-11-08, for `send_file`) is answered by the actor as soon as the row is entered in the ledger, and the sender is given no reply channel: an upload can take minutes, longer than a call may wait, and whether it went out shows in the records like any other message.
  - A `Post` carries its originating turn, `origin: Option<TurnId>` (decided 2026-10-28). The MCP service takes it from the MCP session; for command output and the scheduler it is empty. When entering the message, the actor records it as the message's `turn_id`. If `origin` is the turn of the actor's own current core, the message is not fed to the core: the summary of internal calls in the `run_code` result already covers it, and feeding it again would show it to the model twice. A `Post` from another turn, for example a turn in group A saying something in group B, is fed to B's core as usual. On 2026-10-29, `Post`s sent by tools of the conversation's own core (`send_image`, `recall_message`) were implemented first, with the reply channel carrying the message id or the error once the sender has recorded the `deliveries` row; `Post`s from other conversations or from the scheduler, and feeding them to the core, will be built when they are needed. When the originating turn has already ended (through `/kill` or otherwise), both the `Post` and the tool's job requests (which also carry the originating turn) are refused with the reply "这一轮已经结束了" ("this turn has already ended") (added 2026-10-30, found in review: when a turn was killed while a call was in flight, a `send_image` queued behind it was still sent). Since 2026-11-12 a `Post` names no turn (step 4 of [Lifetimes move to systemd](../decisions/2026-11-12-lifetimes-to-systemd.md#lifetimes-move-to-systemd-1)): every tool is called from the VM, where the host doesn't tell a turn's program from any other, so the row has no `turn_id` and is marked as a program's, `程序发的`, and nothing is refused for coming from a turn that has ended. A turn killed while its program runs may see one more thing said, in the moment before the program's unit is stopped.

## Turn records

One continuous run is a turn: it starts when a trigger starts a core and lasts until the idle window expires, a `/kill`, a failure or a restart; the triggers absorbed along the way are all its input (changed 2026-10-27 to a single core instance; see [The conversation actor](actor.md#the-conversation-actor-1)). A turn has two kinds of records in the database, both append-only (decided 2026-10-27; `TurnResumed`, which served recovery, was removed on 2026-10-29; on 2026-10-30 the snapshot was merged into the outcome, since the former `turn_snapshots` corresponded one-to-one with outcomes and were written in the same transaction):

```rust
// When a trigger starts a core. Identity, trigger and first start in a single record (the former TurnAccepted was merged in 2026-10-27)
struct TurnStarted { turn, conversation, ordinal /* t#, for the model to reference */, trigger /* an intent Wake; later also job results and automations */, from /* snapshot position, see "The timeline" */, started_at }
// The outcome, stored together with the whole core; a turn lost in a crash (Lost) has no run
struct TurnFinished { turn, outcome: Outcome, run: Option<RunRecord>, finished_at }

// What a run leaves behind: what the model was shown and what it said. Rows from before 2026-10-29 have the shape of the input log (core_version, first, inputs); no code reads them
struct RunRecord { spec: RunSpec, base: Context, transcript: Vec<Item> }

// Model output, tool results, interruptions and failures are separate methods of the core, not inputs (changed 2026-10-29, see "The core")
enum Input {
    Messages { ids: Vec<MessageId>, item: Item, people: Vec<PrincipalId> }, // new messages and events on the timeline: references the ledger and also stores what the core saw; people are those appearing for the first time
    Wake(Wake),
    // Later: AutomationFire { fire, item }. Job results have no input of their own; they are a kind of Wake, see below
}

struct Wake {
    ids: Vec<MessageId>,          // the messages it concerns, with voided ones already filtered out by the actor; empty for job results
    reason: Reason,               // Direct, Judged { note }, Job { job } (added 2026-10-30)
    item: Option<Item>,           // the verdict line or job report shown to the model; empty for direct triggers, which are already marked on the message line
}

enum Outcome { Answered, Silent, Interrupted, Failed(FailReason), Lost }
enum FailReason { Model { error: String }, ContextExhausted }
```

When each record is written:

| Situation | What is written |
| --- | --- |
| A trigger starts a core | `TurnStarted` |
| The turn ends, including being interrupted at a restart | `TurnFinished`, with the run |
| A crash | Nothing is written; a `Lost` outcome is added at startup |

- **The trigger is recorded in `TurnStarted`**: a direct trigger could be re-derived from the message itself, but a classification, the set of messages a debounce merged, and an automation trigger could not. With a single core instance, a core starts as soon as a trigger arrives, and an "accepted but not started" state does not exist, so it is no longer recorded separately.
- **One snapshot per turn**: it is written at the end, in the same row as the outcome. The core does not write to the database midway through a run, so the problem of "one copy in the database and another in memory" does not arise either.
- **Status**: a turn with a `TurnFinished` has ended; a turn without one is running in the current process, and such a turn seen at startup was running at the time of a crash.
- **Outcome**: the only derived result that is stored. `Answered` and `Silent` say only whether the run said anything. Finding "which turns have not ended" depends on it, so it is written down. `Lost` is the exception: it is written directly by the startup procedure and means that the turn was running at the time of a crash and has no snapshot.
- The text of Max's reply is in the ledger, not in the outcome.

## Entries

The base context, the transcript and requests all consist of entries:

```rust
struct Item {
    kind: ItemKind,
    source: Option<ModelTag>,          // for entries produced by a model, records the protocol and the model
    opaque: Option<serde_json::Value>, // opaque fields supplied by the provider; the core only carries them and never interprets them
    tokens: u32,                       // estimated by max and passed in; for model-output entries, taken from the provider's usage
}

enum ItemKind {
    Text(String),
    ToolCall(ToolCall),
    ToolResult(ToolResult),
    Reasoning { text: Option<String> }, // the readable part: a summary or plaintext reasoning
    // ...
}

struct ModelOutput {
    items: Vec<Item>,
    usage: Usage, // includes the reasoning token count
}
```

Reasoning content is handled as follows:

- **Responses**: requests carry `store: false` and `include: ["reasoning.encrypted_content"]` and do not rely on the provider-side `previous_response_id`. Each `reasoning` item corresponds to one `Reasoning`: `opaque` stores the entire raw item (including `encrypted_content`), and `text` stores the summary.
- **Chat**: `reasoning_content` (or `reasoning`) corresponds to one `Reasoning`. Signatures attached to tool calls (for example from Gemini forwarded through cliproxy) go into the `opaque` of that `ToolCall`.
- **Reasoning written into the body text**: a `<think>…</think>` at the start of the body is split off into a `Reasoning`. If the body begins with a heading on a line of its own, such as "Thinking Process:", "**Thought Process**" or "思考过程：" ("thought process:"), not a word of it is said: the call counts as an `Error::Aloud` failure, which is retryable, and the model-call task resends it. On 2026-10-29 Gemini 4 Argon did this three times in a row in a group: those three calls had 0 reasoning tokens, and it wrote numbered analysis steps out as its reply, which were segmented and sent into the group; after the first one leaked out, "its own previous message" in the context looked like that, and the next two followed the pattern. Whether a real reply follows the heading cannot be determined, so nothing is split off and the whole call is redone.
- **Reasoning belongs only to its own turn**: it is in the core's transcript and goes into the snapshot with the transcript; it does not go into the ledger or into the base context of later turns, is not sent to the group, and cannot be read by tools such as `history`.
- Reasoning interrupted midway through streaming is not stored; an incomplete blob is of no use.

## Schema

Decided 2026-10-27: the Rust version does not carry over the Haskell version's schema. The schema is redesigned, and at go-live an import program migrates the data in a single pass. After 135 migrations, the Haskell version was left with two conversation keys (`conversation_id` and the QQ group number `legacy_group_id`; the latter has no foreign key, yet about 25 modules use it as a primary key), three kinds of message id, four copies of the message body, 31 tables that no code reads, and migrations that undo one another. The only option is to start from scratch.

### Conventions

- **One key per entity.** A conversation has only `conversation_id`; the QQ group number appears only in `endpoints.native_id`. A message has only `id`, which within a conversation is the order in which messages were entered in the ledger (see [The timeline](#the-timeline)); the model's handle `#id` uses it. The platform's native id is an attribute, unique per `(endpoint_id, native_id)`: those of inbound messages are in `messages`, and those of messages Max sends are in `deliveries`. A person has only `principal_id`; platform accounts are in `identities`.
- **JSONB holds only three kinds of data**: `nodes`, `raw`, and blobs that are by design stored and loaded as a whole (turn snapshots, `opaque`, tool output). Every other structure is made of columns.
- The ledger and the turn records are append-only ([Principles](../architecture.md#principles), item 1).
- Naming: the primary key is called `id`, foreign keys are `<table>_id`, and time columns use `timestamptz` and are named `*_at`.
- Migrations start at number 1. Before go-live they may be merged freely; after go-live they are append-only.
- There is no source hash and no CAS cursor. The Haskell version's `conversation_source_hash` took a sha256 of the IR, so every change to the IR format required rehashing the entire database.
- All id columns are `generated by default as identity`, so that the import program can write the old ids.
- All queries live in `max-db` and take a `&mut PgConnection`; the caller decides which writes share a transaction. A query that needs several statements to be consistent opens its own transaction, which becomes a savepoint when the caller is already inside a transaction.
- The `.sqlx` offline metadata is in `crates/max-db/.sqlx`, and the Nix build sets `SQLX_OFFLINE=true`. After changing a migration or a query, run `scripts/prepare-queries`: it rebuilds the development database from the migrations and regenerates this metadata.
- Vectors use pgvector. It is not a trusted extension and `maxx` is not a superuser, so a migration cannot create it: the NixOS module creates it as postgres in `postgresql-setup`, and the migration's `create extension if not exists vector` then does nothing (tested on 2026-10-29 on the development database with a non-superuser role). If the database is dropped and recreated, the extension must be created again; restarting `postgresql-setup` is enough.

### The v1 tables

| Area | Table | Description |
| --- | --- | --- |
| Platform | `conversations` | Kind (group, direct), title: a group's is its name on QQ, asked for when its actor starts; a private chat's is the other party's name where the platform gives one, which QQ doesn't |
|  | `endpoints` | Conversation, platform, `self_identity_id` (which account Max uses), `native_id`. In v1 a conversation has one endpoint; with mirroring, a conversation has several. The two are separated now (decided 2026-10-27) to avoid another migration later. `native_id` is the adapter's own string: for QQ it is `group:<group_openid>` or `c2c:<user_openid>`; imported old QQ endpoints (platform `qq_legacy`) are `group:<group number>` or `private:<QQ number>` |
|  | `principals`, `identities` | People, and their accounts on each platform. There are several writers: each conversation actor creates them when it enters messages in the ledger; see "Writers" under [Identity](identity.md#identity-1) |
|  | `conversation_settings` | `/model`, `/effort`, `/persona`, `/proactive`, and the message-id watermark of `/clear --all`. Mutable |
|  | `links` | Which conversation's Max may ask which other's: asker, asked, time. `/link` adds a row and `/unlink` deletes rows. See [Asking another conversation](jobs.md#asking-another-conversation) |
| Ledger | `messages` | Conversation, endpoint, `sender_identity_id` and snapshots of the sender's name and role (see [Identity](identity.md#identity-1)), `native_id`, `sent_at`, `received_at`, kind (chat, command, event), `reply_to`, `nodes`, `raw`, and `text` (the rendered text, for search and the full-text index; there is a trigram index on `lower(text)`, see [Recall](context.md#recall)). Max's own messages carry `turn_id` and a segment number. `raw` is the platform's original payload, kept only for the record: rows read back carry only its `said_by` (who spoke on behalf of Max's account; see below), and the same holds for the in-memory message at the time it is entered in the ledger (2026-11-05). Retractions and edits are rows with `kind = event`; the `event` column says which kind (edit, unsend), and such rows carry `target_id` and a text fallback. The new content of an edit is in `nodes`. Only the conversation actor writes this table |
|  | `deliveries` | Outbound receipts: message, endpoint, platform id or error, status (sent, failed, unknown), time. The platform sender is the only writer, and it only appends. With mirroring there is one row per endpoint; see [Outbound](#outbound) |
| Media | `media` | Addressed by sha256: MIME type, size, width and height, the time it was first seen, and the sha256 of the version for the model. The kind is recorded in the message's node, because the same bytes may be an image in one message and a sticker in another. See [Media](media.md#media-1) |
| Caption | `media_captions` | One row per sha256, written only once: which prompt was used (image or sticker), the text (empty when the model gave up), `skip` (for images that do not look like stickers, which stay out of the sticker library), and which model wrote it (empty for imported captions). The caption worker is the only writer. The queries that read rows fill the caption into media nodes that have no description, so rows read anywhere carry the caption. See [Media](media.md#media-1) |
|  | `media_captions` | sha256, caption (empty if the model gave up), the model that wrote it, time. The caption worker is the only writer |
|  | `caption_embeddings` | One row per sha256: the vector of a sticker caption (`vector(1024)`), which model computed it, time. The embedding worker is the only writer. When the model changes, the worker's scan recomputes everything with the new model, and search compares only vectors from the same model. See [Sending images](media.md#sending-images) |
|  | `message_embeddings` | One row per message id: conversation, a `halfvec(1024)` vector, which model computed it, time. The recall vector worker is the only writer, and everything is recomputed when the model changes. See [Recall](context.md#recall). `summary_embeddings` holds the vectors of summaries and has been neither read nor written since 2026-10-30 |
|  | `message_media` | Message, ordinal, sha256. An inbound node holds a download URL, and the media is recorded here once downloaded; for images handed over by a program (`tools.show()`), the node holds the sha256 directly |
| Turn | `turns`, `turn_outcomes` | See [Turn records](#turn-records). `t#N` is `turns.ordinal`, counted from 1 in each conversation |
|  | `llm_usage` | Turn (nullable), purpose (turn, intent, caption, job, dreamer; historian appears only in rows from before 2026-11-02), provider, model, effort, tokens (including the number of cache hits, used to see each provider's hit rate and to tune the idle window, and the reasoning tokens among them), cost. Tokens use bigint. The cost, `cost_micros`, is in millionths of a US dollar and stored as an integer, not a decimal; it is null when the price is unknown, and so far it always is: `/status` works the cost out from the tokens and the configured `price` when it shows it, which covers calls from before the prices were set. There are also three millisecond figures (added 2026-10-30): `first_ms` is the time from sending the request to the model's first output (body text, reasoning or a tool call all count), `took_ms` is the time until the answer ends, and `quiet_ms` is the longest stretch of the stream during which nothing arrived, which is exactly what `stream_idle_timeout_secs` cuts off. Turns and calls that go through `complete` (intent, historian, dreamer, caption) are all recorded. Job calls were previously missing; since 2026-11-07 they are measured by the `/llm` forwarder (see **Usage** under [Background agents](jobs.md#background-agents)). Before lowering the idle timeout, first check how long `quiet_ms` normally is |
| Context | `summaries` | Summaries written by the historian: first and last message ids, time, title, kind, importance, p1, p2, p3, status (active, superseded). Active ranges do not overlap, which an exclusion constraint enforces. Neither read nor written since 2026-11-02; the data is kept. See [Summaries](context.md#summaries) |
|  | `summary_runs` | Each model call made by the historian: range, reason (quiet, pressure, compact), model, raw output, error. Not written since 2026-11-02 |

Further tables are added later together with their features: `automations`, `lingo_*`, `bungie_*`, `destiny_*`.

### What became of the old tables

- `platform_events`: the raw payload goes into `messages.raw`.
- `message_deliveries`, `message_delivery_parts`: replaced by `deliveries`.
- `message_projections`, `message_hook_*`, the `agent_messages` view: hooks are no longer implemented.
- `execution_journal`, `llm_calls`: the turn snapshot already is the model's complete input and output.
- `platform_ids`: there are no compatibility ids.
- `conversation_cursors`: there is no cursor; the tail starts after `conversations.tail_after`. See [Rules for a stable prefix](context.md#rules-for-a-stable-prefix).
- `compartment_evidence`: search searches message bodies directly.
- `memories` and its `memory_*` and `episode_memory_*` tables: memory has been replaced by files, and the old memories were migrated to files by hand on 2026-10-30. See [Memory](context.md#memory).
- `skills`, `skill_versions`: a skill is a document and lives in a file.
- `sandboxes`: the VM's lifecycle is held in the process.
- `admin_timeline_revisions` and its NOTIFY triggers: admin is deferred.
- 31 dead tables (durable task, plan, workflow, browser workspace and so on): not imported.

### Import

- **Message ids carry over the old `canonical_message_id`** (decided 2026-10-27); new messages are numbered on from the maximum plus one. The `#123` and `[image#123.0]` handles in the bodies of old summaries and memories therefore remain valid. The import checks that this order agrees with `ingest_seq`; if it does not, a separate column is added to record the order.
- **All messages are imported** (decided 2026-10-27), including those the hook ignored (`message_projections.context_visible = false`). The database faithfully keeps every fact of the group.
- The v2 nodes of `canonical_content` are converted into the new `Node`; `raw` is taken from QQ's `segments` column, and for Matrix from `platform_events.raw_payload`; `text` is re-rendered. Which platform the old Matrix messages are imported as is **TBD**: Matrix is not implemented yet, the code's `Platform` does not include it for now, and the database's constraint still accepts `matrix`.
- Old QQ accounts and endpoints are imported as platform `qq_legacy`: the official API provides openids, which are not in the same namespace as QQ numbers and group numbers and cannot be matched to them. A new group is joined to its old conversation with `/bind <old group number>`, which keeps the timeline continuous; see [The official QQ bot](qq.md#the-official-qq-bot-1).
- For how people with old QQ numbers are linked, see [Identity](identity.md#identity-1). The old database stores people by QQ number: 583 QQ identities, one per person, whose `native_user_id` is the QQ number. The official API provides only openids: the same person has a different openid in each group and in private chat, and `union_openid` is empty, so a person who is in several groups has to be linked once in each group. There is no nickname matching: in the old data, 4 people share their latest nickname with someone else in the same group, and 45 nicknames are a single character, so automatic identification would inevitably get some people wrong. People who are not linked count as new people; a merge is an alias, and earlier rows render accordingly.
- Old reaction and nudge events are not imported. Max's `debug` rows (tool echoes, 4.7k of them) are not imported. Rows from WeChat, iMessage and Matrix (about 2.6k; those groups cannot be connected to the new bot) are not imported.
- Max's own messages are not written to `deliveries`: on startup the sender only backfills those on the `qq` endpoint whose outcome is unknown, and ignores `qq_legacy`. The old `agent_turns` are not imported; only 3 summaries reference a `t#`, and `turn_id` is left empty.
- Only the `active` entries of `conversation_compartments` are imported (3,249 of them). They are attached by group number (`legacy_group_id`), not by `conversation_id`, so the import finds the conversation through the group number. Ranges are converted from `ingest_seq` to first and last message ids; importance is converted from 0..1 to 1..100; the 40 entries from the single-summary period have only `summary`, which goes into p1, with the other levels left empty. Old summaries have no title, so the title is left empty, and rendering leaves no extra space for it. Handles change from `episode:<uuid>` to `summary#<id>`.
- `principals` and `principal_identities` are moved over directly with unchanged ids, so the `[mention#N]` references in old summaries and memories remain valid; `[@#N]`, written before the rename, is rewritten to `[mention#N]` during import. The old table distinguished identities by Max's account (`platform_account_id`), with one account per platform, so each account maps directly to a platform: the QQ one becomes `qq_legacy`. `sender_name` is taken from `sender_card` and `sender_nickname` in the old `messages`, preferring the group card: since 2026-08-04, `sender_nickname` has stored the group card whenever there is one (`QQ.hs:94`). `sender_role` is taken from `sender.role` in the raw payload in `platform_events`, and is null before 2026-08-04. The 611 empty principals with no identity and no messages are not imported. `endpoint_known_identities` is not imported.
- From `sessions`, only the persona, `/proactive` and `/clear --all` are imported; the model and effort are not (see [Configuration](config.md#configuration-1)). Old memories do not go through the import tool; see [Memory](context.md#memory).
- Media: the content store's files and the old database are on the same bcachefs, so the files are copied to `/var/lib/maxx/media` with `cp --reflink` and their owner is changed to `maxx`. `media` and `message_media` are built from `message_images`, `message_videos` and `group_files`. The old `seg_index` is the node's position, not the media's position, so ordinals have to be recomputed by node; media that no table records are filled in from the blobs written in the nodes (mostly images Max sent). The files must be copied first, because each of them must be present at import time. The versions for the model and the image dimensions are generated by `max-import pictures`, the same way as at download. Captions are imported in substep 3, once `media_captions` exists: the descriptions of 21,519 images in the old database, and the sticker library (3,397 stickers; 3,328 with descriptions and bge-m3 vectors, and the 94 banned ones recorded as SKIP). They are imported by `max-import captions`, which can also run while maxx is running as usual. It runs the migrations first, so it must be run before a maxx that includes the caption worker starts; otherwise the worker's startup scan would rewrite the images imported in the last 14 days. It imports only files that maxx has, prefers the sticker description for the same file, and leaves alone captions that maxx has already written, so it can be rerun. Sticker vectors are imported by `max-import vectors` (substep 5): the bge-m3 vectors of the old `stickers` table. It imports only those whose text hash recorded in the old table (`embedding_content_hash`, the sha256 of the description) matches maxx's caption text; the model name is copied as is (`bge-m3`, so `[embedding] model` must be set to that), and existing vectors are left alone, so it can be rerun and can also run while maxx is running. It too runs the migrations first. On 2026-10-29 this was checked read-only on tank: maxx had 3,334 sticker captions that should have vectors, of which 3,319 could be imported. 8 old descriptions contained line breaks or leading or trailing whitespace and were normalised to a single line when the captions were imported, so their text differs; 7 are captions maxx wrote itself, for which the old database has no vectors. These 15 are filled in by the embedding worker. The same tool also imports the vectors of messages and summaries, by id: those that maxx's recall vector worker would compute (chat messages of at least 4 characters, and active summaries) and that have no vector yet are taken as 1024-dimensional vectors from the old `messages` (`canonical_message_id`) and `conversation_compartments`, with the model name copied as is. The old vectors were computed from the old rendered text; the handles are written differently, but the meaning is the same. It works in batches of 2000 and leaves existing vectors alone. It must be run before a maxx that includes the recall vector worker starts; otherwise the worker would first spend several hours recomputing.
- Forwards: the old database stores each message inside a forward as a separate row. The import folds them into the nodes of the forwarding message, one line per message (nested ones indented), in the same form as the forwards the official API now provides; the images inside count toward that message.
- Max is a single principal: the Max of the old QQ number, plus the bot's openid as a `qq` identity. Old rows render as "（你）" ("(you)"). Max's old rows have no platform id; those ids belong in `deliveries`, which is not imported.
- The owner's old private chat is joined to the owner's new c2c private chat; other people's old private chats are not. The owner's openid is attached to the principal of the owner's old QQ number.
- The `/work` of each group VM is migrated as well (decided 2026-10-27): the import finds the corresponding conversation by group number, copies `work` from that group's current sandbox volume to the new volume, and changes its owner to `maxx` (see [VM processes](vm.md#vm-processes)). The proposal is not to migrate `nix.img` (the writable Nix store in the guest, which holds the installed packages); packages are reinstalled when they are needed. The old volumes are in a directory owned by root, so reading them requires root.
- Automations, lingo, Destiny and the like are each imported when their feature is built; stickers are imported together with captions.
- For the tables into which the import writes old ids, the identity sequences must be advanced past the maximum at the end (`setval`); otherwise new rows collide with old ids.
- Scale: on 2026-10-28 there were 293,848 messages and 605 people with identities; the database was 3.3 GB, and the content store held 34,000 files totalling 26 GB. The import takes minutes. All vectors are imported; see the media item above.
- maxx's own database (113 messages and 3 summaries from the test group) is rebuilt entirely on import and not kept (decided by the owner 2026-10-29), because its ids collide with the old ids that must be kept. After the import, the test group runs `/bind` again, and people who ran `/link` before the import send it again.
- The tool is a separate crate, `max-import`: `import` imports into an empty database in a single transaction and connects to the old database read-only; `pictures` then fills in the images for the model, skipping those already processed. A rehearsal is simply an import into a temporary database. The crate is deleted once the Rust version has been live for a while: it was deleted on 2026-11-05, after `import`, `pictures`, `captions` and `vectors` had all been run; matching people by avatar does not need it. To look at it, see commit `7b5d83d8` and earlier. Importing automations, lingo and Destiny later will be written separately. The old database and `/var/lib/max` will be deleted when the owner says so. The `qq_legacy` rows and the merges are data and are kept.
- Go-live steps (decided 2026-10-29):
  1. Note the bot's openid (the `self_identity_id` of Max's endpoint in the current database), and stop maxx.
  2. As root, copy the files used by the old tables and nodes from `/var/lib/max/media/objects` into `/var/lib/maxx/media/objects` with `cp --reflink`, owned by `maxx` and read-only.
  3. Drop the `maxx` database and create an empty one owned by `maxx`. As the `maxx` user, run `max-import import` (connecting to the old database read-only with the postgres role), then run `max-import pictures`.
  4. Start maxx. In private chat, the owner sends `/bind <old group number>` for each old group, and sends the resulting code to the new group.
