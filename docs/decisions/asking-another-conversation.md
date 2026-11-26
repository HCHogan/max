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

## A question waits as a row until it is answered

What an answer most often waits for is a person: someone in one group has
Max ask someone in another, who says hours later. So a question outlasts
the core that read it, and the answer may come in any later turn.

At first a question that waited was a job in the asker's table, `ask#N`,
which `status` listed and `cancel` withdrew. It waited 2 hours (`ASK_WAIT`)
and then woke the asker with `[ask#3 没答成]`; the asked side kept it across
its cores, listed under `[等你回答的问题]`, and could decline it with `cancel`.
Each of those was a lifetime in an actor, to be fitted to `/kill`, `/stop`
and restarts.

Then a question lived only as long as the core that read it
([lifetimes to systemd](lifetimes-to-systemd.md), step 5): when that core
ended unanswered, its actor answered for it. Nothing was left to keep, and
nothing could wait for a person either: a core ends five minutes after
Max's last word, and what the person said after that had no way back.

Now a question is a row of `questions` from when the asked Max is shown it
until `answer` deletes it. Both conversations read the table as a core
starts, one for what it has yet to answer and the other for what it asked,
so neither actor keeps anything and a restart of max loses nothing. No
timer runs: a question older than 7 days is left out by the queries, and
nobody is told. `cancel`, `status` and the job table stay gone; to say it
won't answer, the asked Max answers that, and a Max that wants to hear by
some time sets a timer unit.

Looked at and not taken:

- **An edge back**, so that B's Max could tell A's whenever it knows. It
  would let B wake A's Max at will, with words A's model reads, which the
  edge A→B never gave: B was the side exposed. A row lets B say one thing
  to each question it was asked.
- **A longer idle window in the asked conversation.** It is at most 2
  hours, keeps a core's whole transcript alive for one open question, and
  still loses what a restart interrupts.
- **Telling the asker when the 7 days run out.** That is a timer, in max or
  as a sweep. The asker's list shows what waits and since when, which is
  what Max needs to tell its people.

## Cost

An edge into a conversation is a weaker membership of it: of its VM, as
root, since [Max enters a linked conversation's VM](ssh-along-a-link.md),
if not of its chat. Each side's base context grows by the questions that
wait, at most ten a link of 2,000 characters each. A question nobody
answers goes quietly after a week, and one that arrives in the instant max
is killed, between its wake and its row, is forgotten without the asker
being told.
