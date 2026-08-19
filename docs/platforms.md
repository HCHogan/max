# Platform operations

Max stores one canonical message per semantic event and treats QQ, Matrix, and
iMessage copies as endpoint deliveries. Two endpoints are one conversation
only when the non-QQ side's `mirror_qq_group` explicitly names that QQ group —
`matrix.mirror_qq_group` and `imessage.mirror_qq_group` are the same operation.
Omit it and the endpoint stands alone.

## Runtime invariants

- Native inbound events deduplicate on `(endpoint_id, native_event_id)`.
- Source event, canonical message, source delivery, mirror deliveries, and
  dispatch eligibility commit in one transaction.
- Context, Historian, memory, `!clear`, and turn coordination read the
  canonical conversation ledger. Transport echoes never become a second row.
- Agent dispatch and outbound deliveries use durable leases. A process crash
  between commit and in-memory work is recovered by the required workers.
- Matrix retries reuse the delivery idempotency key as the transaction ID.
- QQ and iMessage park ambiguous sends. They resume only after an echo or
  authoritative status proves the prior attempt's outcome.
- Platform roles and native IDs are provenance, never Max authorization.
- The live prompt generally advertises the intersection of every enabled
  endpoint's output capabilities. Semantic mentions are the deliberate
  exception when a conversation has a QQ endpoint: canonical content retains
  the target and display label, QQ lowers it to a native at-segment, and
  text-only mirrors lower it to readable `@username` text. Native faces and
  other actions without a faithful fallback remain QQ-only; numeric
  compatibility IDs never imply a protocol.
- Outbound replies publish a canonical `message_relations` edge in the same
  transaction as the message. Each delivery resolves that edge to its own
  native event ID or deliberately degrades when its endpoint cannot preserve
  the relation; model action markers are never transport fallbacks.
- At the temporary OneBot compatibility boundary, QQ direct-chat pseudo ids
  occupy `(-10^12, 0)` while foreign opaque ids occupy `<= -10^12`; the latter
  remain groups. Canonical `conversation_kind` is still the stored authority.

Since migration 055, `canonical_content` stores the ADR 003 v2 IR body
(`{"v":2,"nodes":[...]}`): faces, cards, files and videos keep their
structure, mentions carry a resolved principal identity plus a captured
display label, and media sources are validated reference strings
(`blob:<sha256>`, `http(s)://…`, or `mxc://…`) — inline bytes are imported
into BlobStore before canonical publication and never rest in the ledger.
`rendered_text` is the prompt projection produced by `Max.IR.Prompt`, whose
vocabulary reproduces the segment renderer token for token.

QQ image segments survive the durable-dispatch JSON round trip: inbound
`data.url` and the outbound-compatible `data.file` encoding decode to the same
media source. Blank NapCat summaries become explicit `[image]` or `[sticker]`
markers, never empty transcript rows. Migration 053 repairs affected canonical
projections and recreates missing image-fetch obligations from their persisted
source URLs.

QQ mentions keep their structural `[@#qq]` transcript projection even though
canonical content stores a platform-neutral mention plus its known group-card
or nickname. Outbound QQ delivery uses a native mention while Matrix mirrors
render the same part as `@username` (or `@native-id` when no label is known).
Matrix replies do not
treat the reply-generated `m.mentions` entry for the relay account as an
explicit @Max: the canonical target's semantic authorship decides whether a
reply wakes Max. A real Matrix mention outside the reply fallback still does.

## Matrix mirror

Create a dedicated Matrix account, join it to the target room, and obtain a
long-lived access token. Configure `matrix` as shown in `max.yaml.example`.
`mirror_qq_group` is the only linking operation; room names and member display
names are never used to merge conversations or principals.

On first start Max records the current `/sync` page without dispatching or
mirroring historical traffic. Later limited timelines are repaired through
`/messages` until the last durable event boundary is found, then `next_batch`
is published with revision CAS. Inbound authenticated MXC media is bounded at
64 MiB and imported into BlobStore. Matrix event `info.size` is advisory: a
homeserver may return a valid file with different container metadata, so Max
records the bounded response's actual size instead of abandoning it as an
opaque `mxc://` URI. Outbound canonical media is resolved from
BlobStore or a bounded HTTP source, uploaded through Matrix's
authenticated media API, and sent as the matching `m.image`, `m.video`,
`m.audio`, or `m.file` event. Resolution or upload failure degrades to the
message's canonical text rather than losing the whole delivery. The current
adapter sends the first attachment from one canonical delivery;
multi-attachment fan-out is not implemented yet.

## iMessage

Install the companion service using [bridge/imsg/README.md](../bridge/imsg/README.md),
then configure the same exact chat GUID under `imessage`. The bridge binds only
to the Mac's Tailscale address and independently enforces the chat allowlist.

`imessage.mirror_qq_group` links the chat to a QQ group on the same terms as
the Matrix mirror. Adding it to an endpoint that has been running standalone
rebinds that endpoint to the named conversation on the next start; messages
already received keep the conversation they arrived in, so the chat's own past
does not move into the QQ group's history and the QQ group's past does not
appear in iMessage. Only traffic from the rebind onward is shared.

Max pages `messages.after` in batches of 500 and persists the authoritative
`next_rowid`, even for a page whose visible events were filtered. Watch is only
a latency hint. A stable device/inode/birthtime fingerprint detects replacement
of `chat.db`; reset recovery rescans only the configured chat and GUID dedupe
prevents duplicate semantic messages. Attachments cross as opaque handles and
are imported into BlobStore after size verification; Mac paths are never stored
in canonical content.

Outbound attachments first enter a bounded, authenticated bridge staging
endpoint. Max receives only a random one-shot handle; the bridge substitutes
the Mac path for the allowlisted `send` call, removes the file afterwards, and
cleans bridge-owned orphan files on restart. Arbitrary caller paths are
rejected. The baseline public `imsg send` path keeps SIP enabled and does not
claim native reply/edit/unsend capabilities; replies then become ordinary text
without a fake quote prefix or leaked internal marker. A dedicated Mac may run
the optional SIP-disabled IMCore helper. The bridge probes `imsg status` on
every health check and native reply, and Max writes a changed reply capability
back to the endpoint. With the helper live, canonical reply relations are sent
as `reply_to`; if it disappears, the bridge fails closed and the delivery stays
on Max's durable retry path. Ordinary sends explicitly remain on AppleScript.
For a native reply, IMCore's immediate `lastSentMessage` GUID is non-authoritative
and discarded; the later `messages.after` echo supplies the real GUID and
confirms the delivery. Like Matrix, one outbound delivery currently sends only
its first attachment. Installation and SIP recovery steps are in the bridge
README.

Group wakeups use the confirmed mention handle embedded in Messages'
`attributedBody`, matched against `imessage.mention_handles`. Contact names are
local presentation and never establish identity, so a member may see the bot
as `Maxwell` (or any other alias) without changing trigger semantics. The
bridge also emits the attributed UTF-16 range so canonical content preserves
the ordered semantic mention and its exact visible label.
`imessage.bot_name` is only a compatibility fallback for a manually typed
literal such as `@Maxwell`.

## Diagnostics

With the admin server enabled:

```text
GET /api/platforms/status
```

The response lists every endpoint's canonical conversation, native address,
declared capabilities, ingest cursors/fingerprint/revision, last inbound event,
delivery backlog, accepted-unconfirmed count, outcome-unknown count, suppressed
count, and oldest pending timestamp.

Useful direct checks during cutover:

```sql
SELECT conversation_id, conversation_seq, message_origin, rendered_text
FROM messages ORDER BY ingest_seq DESC LIMIT 50;

SELECT d.delivery_id, a.platform, d.status, d.attempt_count,
       d.native_event_id, d.last_error, d.updated_at
FROM message_deliveries d
JOIN conversation_endpoints e USING (endpoint_id)
JOIN platform_accounts a USING (platform_account_id)
WHERE d.status NOT IN ('confirmed', 'suppressed')
ORDER BY d.updated_at;

SELECT a.platform, c.stream_key, c.cursor, c.source_fingerprint,
       c.revision, c.updated_at
FROM platform_ingest_cursors c
JOIN platform_accounts a USING (platform_account_id)
ORDER BY a.platform, c.stream_key;
```

## Production cutover and rollback

Before restart, take a database backup, run both test suites against a cold
database, and complete the Matrix and iMessage connectivity probes without Max
running. Deploy the binary, migration directory, and fully enabled config as
one release, then start Max once. QQ, Matrix, and iMessage enter through the
canonical ledger immediately; there is no compatibility phase or dual-write
window.

Disabling an adapter means removing its config section and restarting. Durable
endpoint rows, cursors, source events, and delivery evidence remain intact;
do not delete them to clear a transport incident. Pending work resumes when the
same endpoint is enabled again. An older Max binary must not be started after
migrations 049/050; normal migration-version fencing rejects that downgrade.
