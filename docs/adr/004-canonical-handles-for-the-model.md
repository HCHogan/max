# ADR 004: Canonical Handles and the Identity the Model Addresses

- Status: Implemented
- Date: 2026-08-05 (implemented 2026-08-05, migration `066`)

## Context

ADR 003 made one canonical IR the sole content authority and named the LLM
the N+1th platform: its prompt is a lowering of the IR, like any other
endpoint's. Content went through. **Identity did not.** The prompt lowers
canonical nodes into canonical text, then frames that text with identifiers
borrowed from the pre-ADR-003 compatibility layer, and hands the model a
vocabulary that no other consumer uses.

### One row, four unique keys, and the model is shown the wrong one

```
messages_pkey                      PRIMARY KEY (message_id)               ← the model sees this
messages_canonical_message_id_key  UNIQUE      (canonical_message_id)     ← nobody sees this
messages_ingest_seq_key            UNIQUE      (ingest_seq)               ← the model sees this too
messages_conversation_seq_key      UNIQUE      (conversation_id, conversation_seq)
```

`canonical_message_id` is the identity ADR 003 introduced. It is also the
only one of the four that never reaches a human or a model: the prompt's own
query does not even `SELECT` it. What the model gets is `message_id` — the
legacy primary key — in line prefixes, in every tool argument, and inside
media handles; plus `ingest_seq` as `context_expand`'s pagination cursors.

### The id the model sees is minted by three different rules

| case | rule | shape in production |
| --- | --- | --- |
| QQ, numeric native id | passed through unchanged | `843665085` |
| bot-authored | `-nextval('synthetic_message_id_seq')` | `-5780` |
| everything else | `platform_ids.mapped_id` (`-1000000000000 - nextval`) | `-1000000001164` |

The third case is not "foreign platforms": QQ's own non-numeric natives
(recall/reaction notices keyed `notice:<sha>:…`, forward children keyed
`forward:…`) mint there too — 205 rows of `platform=qq` in `platform_ids`.

The consequence is that **the numeric shape of an id tells the model which
transport a message arrived on.** The 2026-08-05 work removed the platform
label from speaker names on exactly this reasoning — a platform label made
one platform the transcript's implicit home, and split one principal into
two speakers. The ids still say it.

The contract has already drifted into a falsehood: `get_message_by_id`
advertises `"QQ message_id (positive integer)"`. For every non-QQ message
both halves are wrong.

### Media cannot be addressed at all

`[image#<id>]` names the *message*, not the picture. QQ carries several
images per message (production: 119 such messages, up to 20 media rows on
one message), and the model has no way to say "the second one". The handle
is synthesized at render time by `tagMediaMarkers`, which rewrites a bare
`[image]` marker using the line's own message id.

Meanwhile the identity the model needs already exists in the schema:

```
message_images_pkey  PRIMARY KEY (message_id, seg_index)
message_videos_pkey  PRIMARY KEY (message_id, seg_index)
```

Media is already keyed by (message, position). It is only keyed off the
*wrong* message id.

### People are addressed by a platform number the model can invent

The roster reads `成员对照（[@#QQ号] 即 @某人）：[@#2107570581]=好吧`. It is
QQ-shaped on every platform, and a plausible-looking number the model made
up is accepted, minting a fake identity on the destination account (recorded
in issue #13's lower-priority list).

Underneath, the IR has already made the right choice —
`NMention (MentionIdentity PrincipalIdentityId)` — and delivery already
lowers that identity to each endpoint's native id. Only the model's
vocabulary and `parseModelChunk`'s parse direction are platform-shaped.

### What "one person" can mean here

`principal_identities` is an account on a platform account; `principals` is
a person. Production holds 239 principals and every one has exactly one
identity: `ensurePrincipalIdentity` mints a fresh principal per new account
and nothing ever merges them.

That is the honest state, because **the physical human is not something the
system can observe.** Nothing proves that `@hank:imdomestic.com` and QQ
`843665085` are one person. The system can know accounts, plus assertions
someone made about them.

Two mechanisms are nevertheless written as if merging happened:
`deliveryMentionNatives` resolves a destination native id through
`destination.principal_id = source.principal_id`, so cross-platform mention
translation only works for merged principals and today always falls back to
folding the mention to text; and `principals.display_name` is a person-level
field that never differs from its single identity's.

## Decision

### 1. Everything the model can point at is named by its canonical key, verbatim

No mapping table, no minting, no translation layer for the LLM. The name the
model utters is the key in the database, so an id in a prompt, a log line,
the admin panel, and `psql` are the same value.

| entity | model handle | backing key |
| --- | --- | --- |
| message | `#<canonical_message_id>` | `messages.canonical_message_id` |
| media | `[image#<canonical_message_id>.<seg_index>]` | `message_images` / `message_videos` PK |
| person | `[@#<principal_id>]` | `principals.principal_id` |
| episode | `[episode#<uuid>]` — unchanged | `conversation_compartments.expand_handle` |

`seg_index` is rendered **verbatim, 0-based**, as stored. A `+1` for
readability would be a mapping, and the invariant this ADR exists to
establish is that there is none: any handle in a prompt can be pasted into a
query. Handles are machine tokens the model copies, not prose it counts.

Episode handles stay opaque UUIDs. Their opacity is not what makes them
safe — `expandEpisode` re-applies the recall policy on every call — but they
are not row identities either; they name a *published summary*, and an
unguessable handle keeps possession from reading as authority.

Pagination cursors (`context_expand`'s `after_cursor` / `start_cursor` /
`end_cursor`, carrying `ingest_seq`) stay internal and are renamed so they
do not read as handles. A cursor is a position, not a name.

### 2. Dense sequential ids are accepted, with scope checks as the guard

`#76368` is a guessable neighbour of `#76367`, and it probably exists. That
is tolerable because every consumption point already re-checks scope —
`fetchMessageInScope`, `fetchMessageImagesInScope`,
`currentConversationRecall`, `expandEpisode` — so a guessed id resolves at
worst to another message *in the same conversation*, and never across a
conversation boundary. Opacity would buy no safety that scope checking does
not already provide.

Canonical ids are also **shorter than what they replace**: five digits today
against ten for a QQ native and fourteen for a minted negative. The switch
costs no tokens; it saves them.

Type-tagged handles (`#m47`, `[@#p12]`) are deferred. They would make a
cross-namespace mistake — a principal id inside `[↩#…]` — unrepresentable
rather than silently valid, but they break the prompt's documented "one
construction law" (`[类型#id: 描述]`), and the observed hallucination in
production was invented QQ numbers, which a roster membership check catches
and an id shape does not. It is a pure rendering change; adopt it if
cross-namespace confusion is ever observed.

### 3. The model addresses people; the ledger stores accounts

`principal_identity` is **an account**: authenticated by its platform,
unambiguous, and the unit of delivery and of permission. `principal` is **an
assertion that two accounts are the same human** — created only by an
explicit human declaration (`!link`, deferred below), never inferred from
display names or anything else. Inference here is a privacy boundary, not a
convenience: it would make memories about one account readable when another
speaks, and owner rights granted to a QQ number extend to whatever account
was merged in.

One identity per principal remains the invariant until someone links two.

**The model is given `principal_id`.** A mention means "I am addressing this
person"; which account carried it is transport. Handing the model per-account
ids would reintroduce, at the id level, exactly the split this project just
removed from speaker names — one human appearing twice, and after a merge
appearing twice under the same name in the roster, with the model free to
conclude they are two people.

That works only because the *stored* node keeps naming the account:

| layer | names | why |
| --- | --- | --- |
| IR node | identity (`MentionIdentity PrincipalIdentityId`, unchanged) | the platform authenticated *that account*; a merge leaves it valid, so no stored node ever dangles |
| model vocabulary | principal | the model addresses people |
| render IR→model | identity → principal | one join, always defined |
| parse model→IR | principal → identity: prefer the origin endpoint's account, else any | stores an authenticated account either way |
| lower IR→platform | unchanged | `deliveryMentionNatives` already resolves identity → principal → identity-on-destination |

The "else any" in the parse rule is not a fudge. In a mirrored room the model
may address someone who has no account on the origin platform: the node then
names their Matrix identity, lowering to Matrix produces a native mention,
and lowering to QQ finds no identity on that account and folds to `@name` —
which is the honest rendering.

The objection that a merge destroys principal ids and dangles stored handles
does not survive contact with the rest of this ADR: handles persist only in
`rendered_text`, which is a projection. A merge is followed by the same
`reproject` every other change here uses, and every handle comes back
pointing at the surviving principal.

### 4. `messages` primary key moves to `canonical_message_id`

The reference graph has already moved; only the declaration lags:

```
→ canonical_message_id  platform_events, message_relations ×2,
                        message_deliveries, message_dispatches,
                        messages.reply_to_canonical_message_id
→ message_id            message_images, message_videos, compartment_evidence
(no FK at all)          memory_evidence.source_message_id
```

The three stragglers are exactly the tables this ADR has to touch anyway. So
the primary key flips **after** they move, when nothing references
`message_id` and the change is two statements instead of dropping and
recreating three foreign keys twice.

`message_id` then degrades to an alternate key — still unique, still
indexed — serving the session/command/admin plumbing ADR 003 deliberately
left alone (`group_id`, `user_id`, `self_id` are compatibility ids too). It
stops being the identity. A later `REFERENCES messages` with no column list
then binds to the canonical id, so a new table cannot pick the wrong one by
default.

## Migration

Smaller than it looks, because the handles the model sees are mostly
rendered, not stored.

1. **Foreign keys and evidence columns** move from `message_id` to
   `canonical_message_id`: `message_images` (9794 rows), `message_videos`
   (214), `compartment_evidence` (5524), `memory_evidence` (2 rows carry a
   message id; it also gains the foreign key it never had). Each is a join
   against `messages` on the same row — the two id spaces are 1:1, so there
   is no ambiguity.

   Implementation found a fourth: `group_files.message_id`. It has no foreign
   key, which is exactly why walking the FK graph missed it.
2. **Stored media handles**: `raw.source_message_id` inside canonical media
   nodes exists on **2 rows** in the whole ledger (bot-authored image
   resends via `messageImageNodes`). Inbound media never stored one —
   `tagMediaMarkers` synthesizes the handle at render time — so this is a
   two-row `UPDATE`, not a table sweep.
3. **Reproject**: `rendered_text` is a projection. After (2),
   `max-adr003-maintenance reproject` rebuilds every transcript line from
   canonical content.
4. **Primary key flip**, once nothing references `message_id`.
5. **Vocabulary cutover** in one deploy: prompt frame ids; the roster, which
   becomes one row per principal; `XMention 'ModelParsed` (`NativeUserId` →
   `PrincipalId`) with `parseModelChunk` resolving a principal to an
   identity, which deletes ReplySend's native→identity conversion and its
   roster membership check along with it — an unknown principal id simply
   does not resolve, so a hallucinated number can no longer mint an identity
   on the destination account; and every tool schema, including the
   `get_message_by_id` description that currently says "QQ".

Stored summaries and memories are **not** invalidated: their prose carries
no ids (checked — 193 compartments and 348 memories, zero real matches). The
one exception is a memory whose text records `群内用户 好吧（QQ 2107570581）`,
written by the extractor as a person's identity; that is a separate defect
in the extractor's prompt, not a consequence of this change.

## What implementation added

Two things this ADR did not anticipate, both the same defect it exists to end.

**`group_files`** was a fourth straggler, invisible to an FK-graph audit
because it has no FK.

**Four columns already claimed to hold principals and did not.**
`compartment_evidence.source_principal_id`, `memory_evidence`'s and
`memory_mutations`' equivalents, and `memories.scope_id` under user scope had
been storing compatibility *user* ids since they were written — the writers
passed `messages.user_id` into a column named for a principal, and nothing
broke because nothing ever joined them to `principals`.

Decision 3 makes that untenable rather than merely untidy: once the historian
cites principals, a memory proposal's subject and a summary's evidence are in
different id spaces, and every user-scope proposal is rejected. So they moved
too, and gained the foreign keys that would have caught it. Seven memories
named an account the ledger had never seen speak; those accounts got the
identity they should always have had rather than losing the memory.

## Consequences

- One identifier vocabulary end to end. The class of bug this ADR removes is
  the one the 2026-08-05 work kept hitting: the same entity under two names,
  with something comparing the wrong pair — `verify` disagreeing with ingest,
  dispatch comparing a native id against a compatibility bigint, three
  minting rules for one column.
- The model can address an individual picture for the first time.
- Handles get shorter, and stop encoding the transport.
- Cross-platform `@` remains unavailable until someone links two accounts;
  `deliveryMentionNatives`'s principal join stays dormant, and a mention of
  someone with no identity on the destination endpoint continues to fold to
  text. This is the honest behaviour, not a regression — and the day a link
  is made, the *same* handle starts lowering to a native mention on both
  sides, with no change to what the model writes or to what is stored.
- Memories and permissions still do not follow a human across platforms. For
  a bot serving one mirrored room this is accepted; changing it means
  building the explicit merge, not weakening the identity rule.
- The roster gains a property it lacks today: one row per person. A linked
  human stops appearing twice under one name.
- One model-facing cutover: for a while the model reads history rendered in
  the new vocabulary while any pre-cutover reasoning it recalls used the old
  one. Bounded by reproject, which leaves no line in the old spelling.

## Deferred

- **Explicit principal merge** (`!link` or an admin action), with an audit
  record of who asserted the link. Wanted the day cross-platform memory,
  permission, or a single native `@` on both sides of a mirror is wanted, and
  not before. This ADR's job is to leave the seam clean: the model already
  addresses the person, the ledger already stores the account, and linking is
  a row in `principals` plus one `reproject`.

  Its shape is not free to choose, because three of the five tables holding a
  `principal_id` — `compartment_evidence.source_principal_id`,
  `memory_evidence.source_principal_id`,
  `memory_mutations.actor_principal_id` — carry `BEFORE DELETE OR UPDATE`
  append-only triggers. A merge that rewrote the absorbed principal's
  references would be rejected by the database, and rightly: an audit row
  saying *that* principal performed *that* mutation was true when it was
  written, and a later assertion about who is whom does not retract it.

  So a merge is an **alias, never a rewrite**: `principals.merged_into` names
  the survivor, the absorbed row stays as a tombstone so append-only history
  keeps resolving, and readers that need the person resolve through
  `coalesce(merged_into, principal_id)`. Normalising the chain at link time —
  pointing at the survivor's own survivor — keeps depth at one, so reads stay
  a single join rather than a recursion.

  Which id survives then costs almost nothing, so take the lower one: it is
  the id most history already names, which minimises the rows needing
  indirection, and it is mechanical, so two operators performing the same
  link agree. Minting a third id is worse only mildly, but for no gain: it
  sends *both* sides through the alias. The display name is the one thing a
  human must choose, since neither is authoritative.

  Aliasing also makes the link reversible — clear the column, reproject —
  which a rewrite could not be, having destroyed the evidence it would need.

  The price of an alias is a join wherever a read groups by person. Measured
  against production (2026-08-05), it is not a consideration:

  | query | without the join | with it |
  | --- | --- | --- |
  | every message (76 496 rows) grouped by person | 45.3 ms | 50.9 ms |
  | one conversation's roster | — | 21.1 ms |
  | resolving a message's mentions (a few identities) | — | 0.111 ms |

  `principals` is 239 rows in 128 kB; the plan reads seven buffers to build
  the hash and then lives in `shared_buffers` permanently. Its row count is
  bounded by *people who have ever spoken*, not by message volume, so the
  join does not grow with the ledger. The two queries that actually run per
  dispatch are the last two, and the mention path already joins
  `principal_identities` today — the alias adds a smaller table to a join
  that exists. The 5 ms appears only on a full-ledger aggregate, which is not
  a hot path, and only once a link exists at all: until then `merged_into` is
  NULL everywhere and `coalesce` is the identity function.
- **Type-tagged handles**, if cross-namespace confusion is observed.
- **The extractor writing platform numbers into memory prose** — the same
  leak this ADR closes elsewhere, in durable content, and fixable on its own.
