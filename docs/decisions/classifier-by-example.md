# The classifier wakes Max in two cases, given by example

The classifier's prompt names the two cases that wake Max, each with a
few examples, calls everything else false, and tells the model nothing of
Max's persona. The design is in
[The small model](../design/intent.md#the-small-model).

## Context

The classifier is a small model, four billion parameters on a GPU of the
fleet's own, and judges every batch of chatter. A hand-typed "@maxx" is
text, and comes this way.

A prompt written as rules does badly with it. One with two cases for
waking Max and seven for not, seventeen negations in under 700
characters, beginning with the first 500 characters of the persona, over
two weeks:

- 36% of the reasons it gave for a wake were ones the prompt ruled out: a
  joke to take up, a remark to agree with. Some cited the persona, a
  shark that likes a joke.
- The model it woke answered `[silence]` to three wakes in ten, and of
  the eight group chats four had switched `/proactive` off.
- Of 48 hand-typed "@maxx", Max answered 31.

Asked again about the batches it had woken Max for, with the same prompt,
it woke Max for a third of them: at the server's sampling its verdict on
a batch near the line is close to a coin's.

## Decision

The prompt says that most messages are members talking to each other,
and false, and that two cases are true:

- the message speaks to Max, calling it or wanting something of it,
  without an @: four examples, a hand-typed "@maxx" among them;
- the message asks the whole chat a question that wants an answer, of
  fact or of how to do something, which nobody has answered: two
  examples.

"The rest is false" is followed by examples of the rest, a line each with
what it is: a short answer to someone, an @ of or a reply to another
member, telling someone to go ask an AI, talk about Max, telling Max off,
small talk, other bots' announcements and pasted code.

A line says what maxx can do, and nothing of the persona. The JSON's
`reason` comes before its `trigger`.

## Why

- **A small model follows a case with examples.** A list of things not to
  do, each a sentence with its exceptions, is what it keeps worst, and
  the list puts the very words into its context: banter, agreeing,
  joining in.
- **A persona is a reason to join in.** "Likes a joke, and takes up a
  topic that interests it" describes how Max talks once it talks. A small
  model asked whether Max should talk reads it as the answer.
- **The reason first, so that the verdict follows it.** With `trigger`
  first, a reason that says a message is no cause to speak comes with
  `trigger: true`: the model has answered before it looks.
- **Replayed on recorded batches**, 308 of them, on the same model, each
  prompt once:

  | batches | n | woke Max, by rules | by example |
  | --- | --- | --- | --- |
  | a hand-typed "@maxx" | 48 | 52% | 95% |
  | ordinary chatter, picked at random | 100 | 16% | 11% |
  | woke Max in service, and the model said `[silence]` | 66 | 31% | 16% |
  | woke Max in service, and someone replied to what it said | 49 | 38% | 22% |

  Of the 308 reasons, 20 named the persona or a joke to take up by rules,
  and 1 by example.

## Cost

- Max is woken less for what people then take up, 22% of those batches
  for 38%: banter that is welcome goes with the banter that isn't.
- An example is matched by its surface. A picture posted with no words is
  taken for a question about it, and a question put to a member by name
  for one put to the chat: 8 of the 11 wakes on ordinary chatter were of
  this kind. The model that is woken declines them, at the price of a
  call.
- A message that names Max wakes it more often, 9 of 17 for 3, and not
  all of them rightly: "calling it without an @" and "speaking of it" are
  near each other for a small model.
- The verdict is still a sample. The same batch can go either way from
  one call to the next.

## Alternatives

- **More examples of the rest**: a follow-up question to whoever spoke
  last, a remark about Max, an announcement, a picture. Replayed on 120
  batches it did no better, and the hand-typed "@maxx" went from 100% to
  83%: each example of what is false pulls at something that is true.
- **A bigger model.** The verdict has to come in the few seconds before
  the chat moves on, for every message of every chat; this one answers in
  three or four.
- **Categories for the model to choose among, and the code deciding on
  them.** It is the same judgement under another name, and a second place
  to keep in step with the prompt.
