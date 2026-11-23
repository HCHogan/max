# A platform is an adapter crate behind max's trait

Each chat platform Max is on is a crate of its own that implements
`max::adapter::Adapter`; `max` itself knows no platform. The design is in
[Crate layout](../architecture.md#crate-layout) and
[The official QQ bot](../design/qq.md).

## Context

QQ was a module of `max` (`max/src/qq`), and more of it had spread
through the rest: the tools for recalling and muting applied QQ's rules
and called its client, the conversation actor asked QQ for a group's name,
`/bind` named QQ's old groups, the configuration had `[platforms.qq]`,
`send_image` turned WebP into PNG because QQ won't take WebP, and the
system prompt and the tools' descriptions spoke of QQ. The rule had been
that adapters stay in `max` until it grows uncomfortably large, and that
mapping QQ's events to nodes is `max`'s, not `qqbot`'s. A second platform
is planned (WeChat, through iLink), and with the rule as it was it would
have meant edits all over `max` again.

## Decision

- What a platform writes and expects is its protocol crate's: `qqbot`
  reads and writes QQ's markup (mentions, faces, the transcripts of
  forwards, Markdown as QQ renders it) and says what its errors mean.
- `max::adapter::Adapter` is what Max needs of a platform: who Max is
  there; sending what conversations say, recording each delivery; handing
  what people say to the conversation table; a chat's title; whether a
  message may be recalled; muting; which old chat `/bind` continues; and
  notes for the system prompt, where the platform's own rules and limits
  are told to the model.
- Each platform's adapter is a crate, `max-qq` first, which depends on
  `max`, `max-core`, `max-db` and its protocol crate. `max` depends on no
  platform crate and names none outside `max_core::message::Platform`,
  which records where a row came from.
- The binary is `max-cli`: it reads `[platforms.*]`, starts each adapter
  and hands them to `max`.

## Why

- The compiler keeps platform code out of `max`: there is no import to
  reach for.
- A platform's rules are in one place and told to the model from there:
  the tools' descriptions are the same everywhere, and a refusal says why
  in the platform's words.
- A second platform is a crate and a line in `max-cli`, and its tests
  live with it.

## Cost

- Two more crates. `max-cli` exists only because `max-qq` depends on
  `max` for what it maps to (`Inbound`, `Outgoing`, `Place`, the ledger's
  writes), so `max` can't depend on it.
- The trait is shaped by one platform; the next may bend it.
- `max` exposes its test helpers behind a `testing` feature, for the
  adapters' tests.

## Alternatives

- **Adapters as modules of `max`**, kept apart by convention or a grep:
  nothing stops an import, and the binary and configuration still mix
  platforms into `max`.
- **The trait and its types in a crate below `max`**, so that `max` could
  depend on the adapters and keep the binary: `Inbound`, `Outgoing`,
  `Place` and the receipts would leave the conversation code they belong
  to, for a crate that exists only to hold them.
- **Adapters in their protocol crates**: `qqbot` knows nothing of Max by
  design, and is worth reusing as it is.
