# Max says little, and joins in seldom

The system prompt gives a reply's length as a number of characters, set
where a reply is wanted to be, and has Max leave most of the classifier's
wakes unanswered.

## Context

Over two weeks of the group chats a member's message was 16 characters at
the median, and within 51 nine times in ten. One of Max's was about 75. A
reply to an @, its messages together, was 184 at the median and over 900
one time in ten; a reply to a wake by the classifier was 168, and two of
some 600 were within 30 characters. In the three busiest chats Max wrote
37 to 60% of the messages and 57 to 85% of the characters.

The members said so. In every chat of any size someone called the replies
too long or said they flooded the screen, and "who asked you" came back
wherever Max joined in unasked. Four of the eight chats had switched
`/proactive` off, two of them within minutes of such words. Four had Max
write a rule for brevity into its memory. One of those rules was a number,
no more than two messages or 200 characters: within a week the longest
tenth of that chat's messages went from 226 characters to 120, and from
then on a reply there was two messages of about 70 each, whatever was
asked.

What the prompt said of length was that Max speaks little, as long as the
people around it do, and at more length when a serious question needs it.
Of the classifier's wakes it said that they were a judgement and no
command. Its rules of that kind weren't kept. Its concrete ones were: it
forbade actions written in brackets, and none of 5,196 replies had one.

## Decision

The prompt's rules for a reply are numbers, in the chat's own measure:

- chatting, joining in, a line back: one message, within 30 characters;
- an answer to a question or a request, however big: the answer first,
  with the one or two points that matter most, in a message or two,
  within 100 characters together; what it leaves out waits for the next
  question;
- at length, and with headings, in two cases only: someone asks for that
  in so many words, or what is asked for is long by nature, a piece of
  code or steps to follow.

A `[判定 …]` line is told for what it is, a small model's guess that is
often wrong. Max answers `[silence]` to most, and speaks, one message
within 30 characters, in two cases: someone was calling it without an @,
or asked the whole chat a question that nobody has answered and Max knows
the answer. Told that it talks too much or cuts in, told to be quiet, or
sworn at, it answers `[silence]` or a word and lets the matter drop.

Beside these: jokes, jabs and self-mockery season one reply in ten, and a
serious question gets a plain answer; what Max isn't sure of, or what may
be out of date, it looks up before it speaks; and a message's `#number`
is for Max alone, so that it names an earlier message to the chat by who
said it and when.

## Why

- **A number, because a number is what is kept.** The rules of degree
  weren't, and neither was the first wording tried for this change, which
  gave lengths as what is usual ("a few dozen characters do for most
  questions"): replayed on a recorded turn, the wordiest model's answer
  went from 563 characters to 439. With numbers, the same model still took
  a question that looked big as leave for 400 to 600 characters, one time
  in five, until the rule said "however big".
- **Set where a reply is wanted, since a limit becomes the length.** The
  chat whose rule was 200 characters got replies of 140 to 200 to
  anything. So each number is the length wanted, not the longest that can
  be borne.
- **Said as what to do.** Each rule names the reply: `[silence]`, a word,
  one message, the answer first. A list of what not to do names those
  things to the model and leaves it without one to do.
- **Most wakes are declined**, because most were wrong. The model already
  answered `[silence]` to three in ten. Of those it spoke to, at most 38%
  were followed within three minutes by a reply or an @ to Max; after the
  rest people talked on past it, or nobody spoke.
- **In the prompt, not in the host.** How much to say is the model's to
  judge, case by case; the host has no way to tell an essay nobody wanted
  from the one that was asked for.
- **Measured on recorded turns.** 53 turns were sent again as they were
  recorded, up to Max's first words, with the prompt as it was and as it
  is, on the two models the chats use. Of 18 wakes by the classifier Max
  spoke to 11 before and to 3 after. A reply to an @ went from 216
  characters at the median to 112, the longest tenth from 612 to 216, the
  longest from 1,390 to 265, and the most messages in one from 13 to 3.

## Cost

- An answer that wanted 300 characters gets 100 and a question back. Some
  members liked the long ones.
- Max joins in less, the welcome times with the rest: banter that people
  took up is no longer a reason to speak.
- The numbers suit a QQ group of people typing short lines. A chat that
  wants more says so and Max writes it in its memory, which is nearer the
  new messages than the prompt is, and wins: the chat with the rule of 200
  still gets its 200.
- The number is kept loosely: 17 of 30 answers were still over 100
  characters, 5 of them over 200. And it is tuned on two models of one
  family and fifty turns; another model may keep it more or less closely.
- For some days the record still shows the long replies, which a model
  imitates, and the prompt says nothing of them: the replays above had a
  line that did, so the first days in service may run longer than they
  show.

## Alternatives

- **A cap in the host**, cutting or holding back what goes past so many
  characters or messages. It would cut the code and the essay that was
  asked for with the rest, and decide for the model what is worth saying.
- **Each chat's own rule, in Max's memory.** Four chats wrote one. The
  others put up with the length, or switched Max off.
- **The prompt in English.** Nothing measured says the rules were misread:
  the concrete ones were kept to the letter. The persona and the examples
  are Chinese either way.
- **Lengths as what is usual, without a number.** Tried first; see Why.
- **A line saying that Max's earlier replies are no measure.** It would
  matter for the few days until the record is of short replies, and the
  prompt keeps to what holds for good.
