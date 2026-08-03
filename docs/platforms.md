# Platform operations

Max stores one canonical message per semantic event and treats QQ, Matrix, and
iMessage copies as endpoint deliveries. A QQ group and Matrix room are one
conversation only when `matrix.mirror_qq_group` explicitly names that QQ
group. The configured iMessage chat is always a separate conversation.

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

## Matrix mirror

Create a dedicated Matrix account, join it to the target room, and obtain a
long-lived access token. Configure `matrix` as shown in `max.yaml.example`.
`mirror_qq_group` is the only linking operation; room names and member display
names are never used to merge conversations or principals.

On first start Max records the current `/sync` page without dispatching or
mirroring historical traffic. Later limited timelines are repaired through
`/messages` until the last durable event boundary is found, then `next_batch`
is published with revision CAS. Inbound authenticated MXC media is bounded at
64 MiB and imported into BlobStore. Outbound canonical media is resolved from
BlobStore, inline bytes, or a bounded HTTP source, uploaded through Matrix's
authenticated media API, and sent as the matching `m.image`, `m.video`,
`m.audio`, or `m.file` event. Resolution or upload failure degrades to the
message's canonical text rather than losing the whole delivery.

## Standalone iMessage

Install the companion service using [bridge/imsg/README.md](../bridge/imsg/README.md),
then configure the same exact chat GUID under `imessage`. The bridge binds only
to the Mac's Tailscale address and independently enforces the chat allowlist.

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
rejected. The adapter uses public `imsg send`, so SIP remains enabled. Native
reply/edit/unsend are not claimed as capabilities; replies use a bounded
textual fallback.

Group wakeups use the confirmed mention handle embedded in Messages'
`attributedBody`, matched against `imessage.mention_handles`. Contact names are
local presentation and never establish identity, so a member may see the bot
as `Maxwell` (or any other alias) without changing trigger semantics.
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
