# The guest calls the host over plain HTTP, as one caller

2026-11-14, the owner, ending a line of changes that began with MCP on
2026-10-29. The design is in [The guest's calls](../design/tools.md#the-guests-calls).

## How it was

- **MCP, stateless** (2026-10-29): protocol version 2026-07-28, JSON
  replies rather than SSE, every request carrying `MCP-Protocol-Version`,
  `Mcp-Method` and `Mcp-Name`, `_meta` with the version and client
  capabilities. The runner built requests itself with fetch. From
  2026-10-30 older protocol versions were accepted too, for pi's MCP
  adapter (pi 1.4 speaks 2025-11-25 and sends `initialize` first).
- **Without rmcp** (2026-11-03, the owner: a pure liability). Only a small
  slice was used, while rmcp needed `legacy_session_mode` and
  `NeverSessionManager` turned off, HTTP headers dug out of extensions, and
  its logs suppressed; it answered pi's `initialize` with 500 by trying to
  make a session. One page of in-house code replaced it (`mcp/service.rs`),
  with async-trait, pastey and uuid gone too. pi's client was checked by
  reading its bundled code: a notification counts as delivered on any 2xx,
  its GET for a push stream gives up on 405, it takes JSON replies, and
  without `Mcp-Session-Id` it sends no DELETE.
- **Sessions and tokens**: each `run_code` run and each `shell` call opened
  a session holding a token, its group and turn, and its calls in flight. It
  counted the program's tool calls for the result's "Max tools called" line,
  kept the pictures it showed, and made what it said the turn's own; a
  background agent had one too, limited to the tools marked `job`. A call
  table (`mcp::Call`, `Caller::route`) decided who might call what.
- **The token names the run, it grants nothing** (2026-11-11, the owner):
  everything in the VM runs as root and could leave the token out, and a call
  without one was a resident program's, with every tool. So a token not open
  counted as none, rather than being refused with -32600, which had kept
  nothing out and refused a command moved to the background. Likewise the
  runner's `tools` got every tool (`tools.say` had been missing while
  `max.raw("say", …)` and `maxx say` worked).
- **One caller** (2026-11-12, step 4 of
  [lifetimes to systemd](2026-11-12-lifetimes-to-systemd.md)): sessions,
  tokens, `Caller::route` and `mcp::Call` went. A call is the VM's, run by the
  actor; pictures travel with the call's line instead of a session; nothing
  tells a turn's program from any other caller. pi's adapter stopped calling,
  as agents call with `maxx`.

## Decision

Drop MCP: `GET /tools` and `POST /tools/<name>`, the answer the call's
outcome with status 200, 400 for arguments that aren't an object, 503
`max-away` when max isn't there, and a closed connection cancelling the
call. The module became `service` (`service/http.rs`), the guest's forwarder
`max-host`, and the URL `MAXX_URL`. Part of contract 5.

## Why

MCP is for calling what somebody else wrote, and both ends here are Max's.
After rmcp and pi's adapter, the only client came from the same build; the
service took one protocol version and refused `initialize`, so no other
client could have joined without work anyway; and what a third party would
need, the tools declared once with their schemas, isn't in the wire. A page
speaking MCP can be put in front of the same table if another client ever
wants one.

## Gone with it

The JSON-RPC envelope and ids, `ping`, notifications (`notifications/cancelled`
had been accepted and ignored), the protocol headers, `_meta`, and
`structuredContent` beside a copy of itself as text.
