# Identity

The Rust version keeps the three judgements of the Haskell version's
[ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md):

- **The model faces people; the ledger stores accounts.** A person is a
  principal; a platform account is an identity. A message's sender and its
  mention nodes store identities, since the platform vouches for the
  account; the principal is looked up only when rendering for the model, so
  merges never touch the ledger.
- **A principal only asserts "these accounts are one person".** On QQ,
  `/bind` merges the owner's own accounts. Any other link, or fixing a
  wrong one, is the owner editing the database. Identity is never inferred
  from names or avatars
  ([decisions/no-avatar-matching.md](../decisions/no-avatar-matching.md)),
  and users' own claims aren't trusted.
- **A merge is an alias, not a rewrite.** `principals.merged_into` points to
  the principal kept, and the merged row stays as a tombstone. Reads use
  `coalesce(merged_into, id)`; chains are one deep, and a merge can be
  undone.

## Tables

| Table | Columns | What it holds |
| --- | --- | --- |
| `principals` | `display_name`, `merged_into` (nullable) | People. `display_name` is the first name seen, used only for someone with no message on the current endpoint |
| `identities` | `principal_id`, platform, `native_user_id` | Accounts, unique per `(platform, native_user_id)`. Max is a principal too, and its accounts identities; there is no account table |
| `endpoints` | `self_identity_id` | Which of Max's accounts an endpoint uses. "Did Max say this?" is `sender_identity_id = self_identity_id` |
| `messages` | `sender_identity_id`, `sender_name`, `sender_role` | A snapshot at sending: on QQ the event's `username` (`某人` when empty; for imported messages the group card, else the nickname) and `member_role` (owner, admin or member; null in private chats) |

There is no member table: who appeared where is derived from the ledger,
and names and roles are snapshots carried by the messages, never asked of
the platform or cached.

**Writers**: every other table has one writer; `principals` and
`identities` are the exception. An actor entering a message that brings an
account it hasn't seen (the sender, or someone mentioned) creates the
identity and its principal, and a new person speaking in two groups at once
has both actors creating them. Resolving the owners at startup and `/bind`
write them too. The rules:

- Rows are only inserted, never updated, except `merged_into`.
- Look the row up once without a lock and use it if found. Otherwise take
  `pg_advisory_xact_lock` on (platform, account) inside the ledger
  transaction, look again, and create it only if it still isn't there. So a
  new account yields one principal, and accounts already seen need no lock:
  writes in different conversations don't wait for each other.

## What the model sees

- A person's handle is `[mention#12]`, in the syntax of `#123`,
  `[image#123.0]` and `t#42` (see
  [How replies are written](ledger.md#how-replies-are-written)). Numbers
  from different namespaces haven't been seen confused, so there are no
  typed prefixes.
- Each tail line is `[HH:MM name #id]`, the name being the `sender_name`
  snapshot, so a name change leaves old lines, and the prefix, as they
  were. Mentions in the body render as `[mention#12]`.
- The **roster** is projected with the base context into the volatile
  block: the people in the context (senders and those mentioned in the
  tail, and the senders of the first inputs), a line each, such as
  `[mention#12] 名字（管理员）`, with the name and role from the person's latest
  message on this endpoint, or `principals.display_name` for someone who
  never spoke. One `DISTINCT ON` query, on the `messages (endpoint_id,
  sender_identity_id, id)` index.
- Someone who first appears while the core runs gets a roster line in that
  batch's `[新消息]`, and `Input::Messages` carries them; once the model sees
  the batch the core adds them to the roster, so later output can @ them.
- The model never sees platform ids.

## Resolution and sending

- The core keeps the roster's principals and stores them in the snapshot
  with the base context; the model call's segmenter has them too. A
  `[mention#N]` whose principal isn't in it doesn't become a mention, so a
  number the model made up never becomes a real @: with a name
  (`[mention#N: name]`) it is sent as the text `@name`, without one it is
  removed.
- **Quotes**: entering a `Said`, the actor checks its `[reply#id]`, which
  must be a message on this conversation's timeline and not an event row.
  If it isn't (a made-up number, another conversation's message), the
  quote is removed, the body sent as is, and a warning logged. This isn't
  the core's check: the model may rightly quote an old message it found
  with a tool, and only the database knows whose it is. A quoted message
  with no platform id (one that was never sent, say) is sent without the
  quote.
- At send time the adapter resolves a mention's principal to the person's
  identity on the endpoint's platform, the one that last spoke there if
  there are several, and sends a native @; with none, the text `@name`.

## Permissions

- **Owners** are listed in the owners file (from sops), one
  `platform:native_id` a line, resolved to identities at startup (created if
  unseen). Permissions go by principal, so every account merged into an
  owner is an owner. For QQ only the private `user_openid` is listed; the
  owner's group accounts are merged in by `/bind` (see
  [The official QQ bot](qq.md#groups-and-private-chats)).
- **Platform roles** come only from the `sender_role` a message carries: a
  command carries its sender's role at that moment, so the platform is
  never asked.
- **Ranks** (`Rank` in `actor/commands.rs`), lowest first: anyone; the
  group's owner and administrators (`Admin`); the other party of a private
  chat (`ChatOwner`); Max's owners (`Owner`). What each command needs is in
  [Commands](commands.md#who-may-run-what).

## Open

People are per platform account; joining someone's accounts across
platforms would follow principal merges and needs nothing of its own.
Memory is a conversation's file, so it stays when another platform joins
the same conversation.
