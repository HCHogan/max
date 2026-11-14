# One conversation's Max can ask another's

2026-11-10, proposed by the owner and built that day; simplified on
2026-11-12. The design is in
[Asking another conversation](../design/jobs.md#asking-another-conversation).

## Decisions

- **Permission is an edge between conversations, not a person's** (the
  owner). Below a conversation nothing can be enforced: its members share one
  VM as root and one context.
- **The edge has a direction, and the asked side redeems the code.** What an
  edge exposes is the asked conversation: the answering core is the one that
  serves its own chat, with all its tools, and the host can't give it fewer.
  The asker's members see the code, so with the asked side redeeming it, a
  member can expose only a conversation where they may run `/link` themselves.
- **Owners only, for now** (the owner): every question is a turn of the asked
  conversation's model. To be widened after testing.
- **No derived edges**: the first idea, that a person's private chat may ask
  every group the person is in, can't be derived on QQ, where a person's
  openid differs per group and in private chat.
- **Each tool takes the number alone** (`to: 9`), not the handle as well (the
  owner: less code).
- **Groups learn their titles from QQ's `info` once, as their actor starts**:
  at first it was asked whenever a `/link` was handled, a side effect of a
  command that had nothing to do with names.

## Neither is said in a chat

The first version, deployed for a few hours that day, said four lines on
Max's account, two in each chat (`asked`, `asks`, `answered`, and
`answered` or `didn't answer`): the owner had said to reuse the system-notice
mechanism, meaning the notices in the transcript, and it was built with the
lines maxx says, as a command's answer is. On seeing it, the owner had it
changed the same day: a question and its answer are items shown to the
model alone, like an agent's report.

## Simplified on 2026-11-12

Step 5 of [lifetimes to systemd](2026-11-12-lifetimes-to-systemd.md). Until
then a question that waited was a job in the asker's table, `ask#N`, which
`status` listed and `cancel` withdrew; it waited 2 hours (`ASK_WAIT`) and
then woke the asker with `[ask#3 没答成]`; the asked side kept it across its
cores, listed under `[等你回答的问题]`, and could decline it with `cancel`. From
2026-11-11 a background agent called both tools with a session of its own,
and `ask` without `to` asked its own Max.

Now a question lives only as long as the core that read it: when that core
ends unanswered, its actor answers for it as on `/stop` (the owner: a
question that runs out is handled as `/stop` is, with no logic of its own).
The asker keeps nothing, so no later core needs telling (the owner: the list
wasn't needed). `cancel`, `status`, the job table and the handles went; to say
it won't answer, the asked Max answers that.

## Cost

An edge into a conversation is a weaker membership of it. A question asked
just before max restarts is forgotten, and the asker isn't told.
