# A link lets Max into a VM, and nothing asks across it

A link from A to B lets Max in A enter B's VM, and that is all there is
between two conversations. `ask`, `answer` and the questions that waited
for an answer are gone. The design is in
[Entering another conversation's VM](../design/vm.md#entering-another-conversations-vm).

## Context

A link first carried a question and its answer, each at most 2,000
characters (see
[One conversation's Max can ask another's](asking-another-conversation.md)),
and then also let Max in A into B's VM as root (see
[Max enters a linked conversation's VM by ssh, through max](ssh-along-a-link.md)).

Once Max in A is root in B's VM, `ask` gives it nothing more. Everything in
a VM is one caller, so `maxx` there is B's: `maxx history` reads B's chat,
`maxx say` speaks in it, and `maxx wake` puts words before B's Max. What A
wanted to know of B it could read for itself, without a turn of B's model;
what it wanted B's Max to do it could say with a wake.

What only `ask` and `answer` did was carry an answer back, and that had
grown into the larger half: a table of questions that waited, two lists in
every core's context, a number for each question, a cap on how many wait,
seven days after which one is dropped, and a way to tell the asker when
`/stop` took what waited. All of it stood in for one thing a link doesn't
give: a way from B to A.

## Decision

`ask` and `answer` go, with the `questions` table, the two lists, the
notices and the limits. The prompt says that `maxx` in a linked
conversation's VM is that conversation's, with `history`, `say` and `wake`
as examples, and that Max there has no way back.

A link is named for what it does: `links.from_id` may enter the VM of
`links.to_id`, the block that lists them is `[能进的会话]`, and `/status`
shows `may enter` and `open to`.

## Why

- **One rule.** A link is entry to a VM, and what Max can do across it is
  what it can do in that VM. There is no second thing between
  conversations, with rules of its own, to keep in step with it.
- **The host keeps nothing.** No row waits, nothing is counted or timed,
  and neither actor knows of the other: what one conversation tells
  another's Max is a wake like any program's.
- **Reading needs no model.** Most of what was asked was what the other
  chat had said, and `maxx history` there answers that without a turn of
  the other Max.

## Looked at for the way back

None is built. Each would let B's Max put words before A's:

- **A reply right read from the record**: B may wake A while a wake from A
  is less than some days old. Wakes are rows of the ledger (see
  [What wakes Max from outside the chat is a row](wakes-are-rows.md)); it
  needs them to say where they came from, and a `wake` that names another
  conversation.
- **A token A leaves in B**, which wakes A when `maxx wake` is given it:
  A hands the right over, and anything in B's VM that reads it holds it
  until it runs out.
- **Messages both ways along any link.** The simplest rule, and it lets
  anyone in B have B's Max wake A's at will, with words A's model reads,
  where the link A→B exposed only B.
- **A watcher of A's own**: a unit in A's VM that holds an ssh connection
  into B and wakes Max when a file appears there. It needs nothing of the
  host and can be built today; a connection ends whenever max restarts,
  keeps B's VM from stopping when idle, and is A's Max's to set up and
  keep alive.

## Cost

- **No answer comes by itself.** Max in A can't have B's Max ask its
  people and hear what they said when they say it, hours or days later:
  it has to look again, in B's history or a file B's Max was asked to
  write, or keep a watcher of its own.
- **A wake in B doesn't say whose it is.** B's Max sees a row tagged
  `max-wake` and the words, as from a program of its own; who asked and what for is in
  the words or nowhere, and the host can't vouch for it.
- **Waking B's Max costs B's VM a boot** if it wasn't running, where a
  question went from actor to actor.
