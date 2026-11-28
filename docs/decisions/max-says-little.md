# Max says little, and joins in seldom

The system prompt gives Max a register to speak in and three lengths to
choose among for each reply in a group, with few rules beside, and has
Max leave most of the classifier's wakes unanswered. What the prompt says
is under [How replies are written](../design/ledger.md#how-replies-are-written).

## Context

Left to a prompt that says only that Max speaks little, as long as the
people around it do, and at more length when a serious question needs it,
Max writes far more than anyone else. Measured over two weeks of the
group chats:

- A member's message was 16 characters at the median, and within 51 nine
  times in ten. One of Max's was about 75.
- A reply to an @, its messages together, was 184 at the median and over
  900 one time in ten; a reply to a wake by the classifier was 168, and
  two of some 600 were within 30 characters.
- In the three busiest chats Max wrote 37 to 60% of the messages and 57
  to 85% of the characters.

The members said so. In every chat of any size someone called the replies
too long or said they flooded the screen, and "who asked you" came back
wherever Max joined in unasked. Four of the eight chats switched
`/proactive` off, two of them within minutes of such words. Four had Max
write a rule for brevity into its memory. One of those rules was a
number, no more than two messages or 200 characters: within a week the
longest tenth of that chat's messages went from 226 characters to 120,
and from then on a reply there was two messages of about 70 each,
whatever was asked.

A vague rule isn't kept, and a concrete one is: the prompt forbids
actions written in brackets, and none of 5,196 replies had one.

## Decision

What the prompt says of a reply in a group is short.

- **A register.** Max's style is brief and casual, as replies on Tieba
  are, dropping a subject or turning a sentence about as speech does. It
  takes its turns of phrase from the members, not from its own messages
  in the record.
- **Three lengths, of which Max picks one each time**: a brief one, a
  short sentence or two; an ordinary one, on the topic in hand, in
  everyday speech; a long one, which may comment and explain in some
  detail. When the others are speaking briefly it is the brief or the
  ordinary one, and the long one when a complicated question needs
  explaining.
- **Three lines of manners**: a topic to a reply; everyday and not
  overdone, without hunting for topics; and where someone doesn't like
  Max or doesn't answer it, it doesn't press, and reads the room before
  it speaks.

No reply has a limit in characters. These are a group's rules, in the
prompt's section for groups. A private chat is the other party's alone:
a reply there is as long as the matter needs.

A `[判定 …]` line is told for what it is, a small model's guess that is
often wrong. Max answers `[silence]` to most, and speaks, one message, in
two cases: someone was calling it without an @, or asked the whole chat a
question that nobody has answered and Max knows the answer.

## Why

- **A register the model knows, in place of rules for cases.** Answering
  each complaint with a rule (a limit for chat and one for an answer, a
  share for jokes, the two cases in which to write at length) does what
  each rule is written for and bends something beside it, and the next
  rule is for that. A model knows what a reply on Tieba is like, and
  takes its length and its tone from that together.
- **The length is Max's to pick, by what the others are doing.** A limit
  is filled: with 30 characters for chat and 100 for an answer, the model
  keeps the content and presses it to the limit. Of 28 replies under such
  limits 23 were a single message, the answers one dense sentence each of
  clauses strung on semicolons, and the play was gone from them. Members
  complain of walls of messages, never of a reply that takes two lines to
  be funny.
- **Not from its own messages.** In the busy chats most of the record is
  what Max said, so a model that speaks as the record does speaks as
  itself, and whatever it once did it does more of.
- **The wording is another project's.** The register, the three lengths
  and the lines of manners are those MaiBot, a bot built to be a member
  of a QQ group, ships as its defaults, less one word: "plain", which
  would flatten a persona that is meant to be funny.
- **Most wakes are declined**, because most are wrong. Without being
  told, the model answers `[silence]` to three in ten. Of those it speaks
  to, at most 38% are followed within three minutes by a reply or an @ to
  Max; after the rest people talk on past it, or nobody speaks.
- **In the prompt, not in the host.** How much to say is the model's to
  judge, case by case; the host has no way to tell an essay nobody wanted
  from the one that was asked for.

## Cost

- This wording isn't backed by a replay on recorded turns, as the
  alternatives below are. What it does shows in service.
- Which question is complicated is the model's to say, and the wordiest
  model finds many so: without a limit it writes 400 to 600 characters to
  one question in five that looks big.
- Max joins in less, the welcome times with the rest: banter that people
  take up is no reason to speak.

## Alternatives

- **A cap in the host**, cutting or holding back what goes past so many
  characters or messages. It would cut the code and the essay that was
  asked for with the rest, and decide for the model what is worth saying.
- **Each chat's own rule, in Max's memory.** Four chats wrote one. The
  others put up with the length, or switched Max off.
- **The prompt in English.** Nothing measured says the rules are misread:
  the concrete ones are kept to the letter. The persona and the examples
  are Chinese either way.
- **Limits in characters**: see Why. Replayed on 53 recorded turns they
  took a reply to an @ from 216 characters at the median to 112, and the
  longest from 1,390 to 265.
- **The members' own lengths, described, with the reason**: a member's
  message is mostly a dozen characters, and each of Max's pushes other
  people's up the screen. Replayed on 28 turns it took a reply to an @
  from 232 characters at the median to 90. The register says as much in a
  sentence, and brings the tone with it.
- **A share for jokes**, one reply in ten, a jab only at the message in
  hand, one comparison a reply. It rations what the members like; the
  comparisons are part of what makes Max sound alive.
- **"Look it up first" among the rules for a reply.** The search tool's
  own guide says it, and with the line in the prompt Max still answers a
  question of fact from memory and is corrected.
