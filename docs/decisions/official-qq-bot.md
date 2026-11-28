# QQ through the official bot API

Max reaches QQ through Tencent's official bot API, with a client of its
own. The design is in [The official QQ bot](../design/qq.md).

## Context

There are two ways onto QQ. One is a real QQ account, logged in by QR
code and driven through NapCat and OneBot; Tencent bans accounts used
so, as it did Max's. The other is the QQ Open Platform's bot API, which
gives a bot an identity of its own and far less to do.

## Decision

- Tencent's official bot API (individually verified; the bot is maxx),
  with an in-house client, `qqbot`: official SDKs exist only for Go,
  Python and Node.
- **Every message is proactive.** None is sent as a passive reply to the
  message it answers.
- **Always Markdown**, with plain text only as a fallback.
- **The fallback only on an explicit rejection.** A timeout after
  sending, or an answer that can't be parsed, is `unknown` and isn't
  sent again.
- **The gateway's session is stored at shutdown and resumed at startup.**

## Why

- A ban falls on the bot, not on a person's account, and there is no
  NapCat or QR login to maintain.
- The gateway is a WebSocket Max connects out to, so the host needs no
  public ingress.
- **Proactive, because passive replies have windows to count.** A reply
  to a message less than 5 minutes old with fewer than 5 replies may be
  passive; the 6th is refused (40034128), and the window counts from the
  message's own send time, so a message delivered again after downtime is
  refused too (40034005). In a group without proactive speaking the 6th
  segment of an answer couldn't be sent at all. Counting windows and
  replies only duplicates the premise that every group allows proactive
  speaking.
- **Markdown renders everything Max writes**, so there is nothing to
  decide per message.
- **Resending on any error can send two copies**: a message that went out
  and whose answer was lost goes out again as plain text.
- **A new session delivers nothing that was missed**, so a restart
  without resuming loses the messages sent meanwhile.

## Cost

What the official API can't do: reactions and nudges, sending QQ face
emoticons, group cards, edits, other people's retractions, and
recognising a person across groups (openids differ per group). QQ numbers
can't be matched to openids, so the records of a group from before join
the new one only through `/bind`, and its members count as new people
([no-avatar-matching.md](no-avatar-matching.md)). See
[features removed](features-removed.md).
