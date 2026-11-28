# The conversation is the finest grain of permission

What Max can do in a conversation, anyone in it can have Max do. The host
tells people apart only in the commands that change the conversation
itself; inside a turn nothing checks who asked. A person's own permission
is their private chat's.

## Context

A conversation is a group or a private chat. Each has one VM, where Max's
commands run as root with `/work` as its home, one context, built from the
whole chat, and one memory file. Whatever Max is given in a conversation
ends up in these: a login in the browser's profile, a key in a file, a
tailnet's node, a program that keeps running. A group's members trust each
other to different degrees, and some of what Max can do (muting, recalling,
acting on someone's machines) looks as if it wants a check of who asked.

## Decision

- **Nothing below a conversation is enforced.** Max's tools, the keyed
  APIs, the VM and everything in it, and the conversations it may enter are
  the conversation's. A turn answers the conversation, not a person, and no
  tool checks who started it.
- **Max's judgement, not a gate.** Max sees who said what and can decline,
  as a person would: whether to mute, recall or change a setting is its call
  (see [Group management](../design/platforms.md#group-management)). What
  mustn't be done at anyone's asking isn't a tool at all: there is no
  kicking, no banning a whole group, no making someone an administrator.
- **A person's own is their private chat.** Access meant for one person,
  to their machines or their accounts, is given to the VM of their private
  chat with Max, a conversation of one.
- **Ranks are for commands.** The people a conversation belongs to (a
  group's owner, with its administrators for keeping order; the other party
  of a private chat; Max's owners) decide its settings and its links,
  through commands that check the sender's rank (see
  [Who may run what](../design/commands.md#who-may-run-what)).
- **Between conversations, an edge.** One conversation reaches another only
  by a link that the entered side makes, and the link exposes all of it (see
  [A link lets Max into another conversation's VM, and that is all](links-enter-only.md)).

## Why

- **It couldn't be enforced anyway.** The members share one VM as root, so
  a file one of them had Max write, a login, a key or a tailnet's node is
  something any of them can have Max read or use. They share one context, so
  what one has Max look at, another can ask about. A program written at one
  person's asking runs on for the conversation, and its calls carry no
  name. A per-person check in the host would stop the direct request and
  none of the ways around it.
- **People can reason about it.** "Letting Max into something lets this
  conversation in" is one rule, and the private chat answers anything
  personal.
- **The host stays simple.** Tool calls, programs, units and background
  agents carry no requester; permissions are ranks on commands and edges
  between conversations.

## Cost

- A group is as trusted as its least trusted member, for whatever Max has
  been given there. Nothing can be shared with a group but one member.
- Anyone in a group can ask Max to mute someone or recall a message, and
  Max's judgement is all that decides.
- Personal access lives in a private chat, so a group gets at it only
  through a link, which exposes the whole private chat.

## Alternatives

- **A check of who started the turn**, on the moderation tools first, with
  ranks like the commands': it would gate the direct request, but a turn may
  answer several people's messages, Max's programs and units call the same
  tools later on nobody's behalf, and the model can be asked indirectly.
- **Per-person secrets in a shared VM**: nothing in a VM is out of root's
  reach, and every command runs as root.

## Built on it

- [A link lets Max into another conversation's VM](links-enter-only.md):
  `/link` and the edges between conversations.
- [Max joins tailnets itself](max-joins-tailnets-itself.md): a tailnet Max
  joins is its conversation's.
- The group management tools, gated by Max's rules and judgement only.
- A VM per conversation: see [VMs](../design/vm.md).
