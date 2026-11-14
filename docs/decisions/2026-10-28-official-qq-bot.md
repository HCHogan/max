# QQ through the official bot API

2026-10-28, with adjustments to sending on 2026-10-29 and 2026-10-30. The
design is in [The official QQ bot](../design/qq.md).

## Context

The Haskell version reached QQ through NapCat and OneBot, logged into a
real QQ account by QR code. Tencent banned that account on 2026-10-28.

## Decision

Use Tencent's official bot API (the QQ Open Platform, individually
verified; the bot is maxx), with an in-house client, `qqbot`: official
SDKs exist only for Go, Python and Node. NapCat and OneBot go.

## Why

- A ban falls on the bot, not on a person's account, and there is no
  NapCat or QR login to maintain.
- The gateway is a WebSocket Max connects out to, so the host needs no
  public ingress.

## Cost

What the official API can't do went with it: reactions and nudges, sending
QQ face emoticons, group cards, edits, other people's retractions, and
recognising a person across groups (openids differ per group). Old QQ
numbers can't be matched to openids, so the old records join a new group
only through `/bind`, and old members count as new people
([2026-11-06-no-avatar-matching.md](2026-11-06-no-avatar-matching.md)).
See [features removed](2026-10-28-features-removed.md).

## Adjustments

- **Every message proactive** (2026-10-29). At first passive replies came
  first: a reply to a message less than 5 minutes old with fewer than 5
  replies was sent passively with its `id` and an increasing `msg_seq`,
  otherwise proactively. The 6th reply answered 40034128, and the window
  counts from the message's own send time, so a message delivered again
  after downtime, counted from its arrival, gave 40034005 "回复消息msg_id已过期".
  In a group without proactive speaking the 6th segment of an answer
  couldn't be sent at all. Counting windows and replies only duplicated the
  premise that every group allows proactive speaking, so passive replies
  went.
- **Always Markdown** (2026-10-29): it renders everything Max writes, so
  there is nothing to decide per message; plain text only as a fallback.
- **Fallback only on an explicit rejection** (2026-10-30, found in review):
  every error used to lead to a plain-text resend, and the message was then
  recorded as failed anyway, which could send two copies. A timeout after
  sending, or an unparsable answer, is now `unknown` and isn't resent.
- **Resume across restarts** (2026-10-29): a new session delivers nothing
  missed (one message was lost in testing), so the session is stored at
  shutdown and resumed at startup.
