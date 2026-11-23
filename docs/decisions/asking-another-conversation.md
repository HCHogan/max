# One conversation's Max can ask another's

Max in one conversation can put a question to Max in another, over a link
made with `/link` by the people the two conversations belong to. The design is in
[Asking another conversation](../design/jobs.md#asking-another-conversation).

## Decisions

- **Permission is an edge between conversations, not a person's.** Below a
  conversation nothing can be enforced: its members share one VM as root and
  one context (see
  [The conversation is the finest grain of permission](permission-by-conversation.md)).
- **The edge has a direction, and the asked side redeems the code.** What an
  edge exposes is the asked conversation: the answering core is the one that
  serves its own chat, with all its tools, and the host can't give it fewer.
  The asker's members see the code, so with the asked side redeeming it, a
  member can expose only a conversation where they may run `/link` themselves.
- **A group's owner and the other party of a private chat may link**, as
  well as Max's owners: they are the people a conversation belongs to. A
  group's administrators may not: they keep order in the chat, and a link
  exposes the whole conversation to another one. Max's owners alone was
  looked at, since every question is a turn of the asked conversation's
  model, which they pay for; but so is every message that wakes Max in a
  group, and anyone may send one.
- **No derived edges**: the first idea, that a person's private chat may ask
  every group the person is in, can't be derived on QQ, where a person's
  openid differs per group and in private chat.
- **Each tool takes the number alone** (`to: 9`), not the handle as well:
  less code.
- **Groups learn their titles from QQ's `info` once, as their actor starts**,
  not whenever a `/link` is handled, which would be a side effect of a
  command that has nothing to do with names.

## A question and its answer aren't said in a chat

They are items shown to the two models alone, like an agent's report. The
first version said four lines on Max's account, two in each chat (`asked`,
`asks`, `answered`, and `answered` or `didn't answer`), the way a command's
answer is said. The chats had no use for them, and they went within hours.

## A question lives as long as the core that read it

At first a question that waited was a job in the asker's table, `ask#N`,
which `status` listed and `cancel` withdrew. It waited 2 hours (`ASK_WAIT`)
and then woke the asker with `[ask#3 没答成]`; the asked side kept it across
its cores, listed under `[等你回答的问题]`, and could decline it with `cancel`.
A background agent called both tools with a session of its own, and `ask`
without `to` asked its own Max.

Now a question lives only as long as the core that read it. When that core
ends unanswered, its actor answers for it as on `/stop`: a question that
runs out has no logic of its own. The asker keeps nothing, so no later core
needs telling. `cancel`, `status`, the job table and the handles went; to
say it won't answer, the asked Max answers that. This was step 5 of
[lifetimes to systemd](lifetimes-to-systemd.md).

## Cost

An edge into a conversation is a weaker membership of it. A question asked
just before max restarts is forgotten, and the asker isn't told.
