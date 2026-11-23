# Platforms

Max is on chat platforms through adapters: QQ's is the only one, in
`crates/max/src/qq` (see [The official QQ bot](qq.md)). An adapter
implements `max::adapter::Adapter`, and the rest of max uses a platform only
through it; a row records its platform (`max_core::message::Platform`) and
nothing more of it. Why the line is drawn here is in
[decisions/platform-adapters.md](../decisions/platform-adapters.md).

What a platform writes and expects (its markup, its errors' meanings) is its
protocol crate's, such as `qqbot`; the adapter maps between that and Max's
types.

## What an adapter does

- **Who Max is there**: its account's id and name, which the platform
  confirms as the adapter starts, so bad credentials stop max at once.
- **Listening**: what is said on the platform goes to the conversation
  table as `Inbound`s, until max stops. An adapter that is shut out for
  good fails, and max stops.
- **Sending**: each platform has a sender, which takes what conversations
  say (`Outgoing`, routed by the place's platform) in the order each was
  committed, says it, and records how each went: it is the only writer of
  the platform's deliveries. Before it starts, what the last run committed
  and never heard back about is marked unknown, and isn't said again. When
  max stops, the sender says what was queued, within the drain.
- **A chat's title**: asked once as a conversation's actor starts, and kept
  as the conversation's title, by which other conversations name it.
- **The platform's rules** for recalling and muting, below.
- **The chats of an old platform**, which `/bind <old>` goes on with: QQ's
  are the groups of the QQ before this one, by number.
- **Notes for the model**: a paragraph of the system prompt, after the
  tools, in each conversation on the platform. It tells the platform's
  rules for the tools, which the tools' descriptions leave to it.

`max-cli` starts an adapter for each `[platforms.*]` section of the
configuration and hands them to max.

## Group management

The tools `recall_message` and `mute_member` are the same on every
platform. Each checks Max's own rules, then asks the adapter for the
platform's, and what either refuses is refused with the reason, before
anything is asked of the platform.

- **`recall_message({ id })`**: Max's rules are that it is a message of this
  chat, not recalled already; Max's own only if it was sent; and someone
  else's only in a group. It counts from when the message went out or came
  in (Max's, still on its way, from now), and the adapter says whether its
  platform still lets it be recalled, and whose. A recall is an unsend row of
  Max's, which the sender carries out in ledger order, so recalling what Max
  just said waits behind its sending.
- **`mute_member({ member, seconds })`**: Max's rules are no muting in a
  private chat, nor of Max, nor of someone who hasn't spoken in the group:
  the platform's id for them is the account they last spoke with there.
  The actor is asked whether a mute may go ahead (it refuses while the
  conversation is stopped). The adapter checks the platform's own rules,
  such as whom and for how long, and mutes. A mute isn't a message: it
  leaves a log line, no row.
