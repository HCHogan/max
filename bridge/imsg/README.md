# imsg bridge

This service runs beside [`imsg`](https://github.com/openclaw/imsg) on the Mac
that owns `~/Library/Messages/chat.db`. It exposes only one configured chat to
Max over Tailscale; it is not a general `imsg` RPC proxy.

## Mac setup

1. Install and verify the public, SIP-safe path:

   ```sh
   brew install steipete/tap/imsg
   imsg chats --limit 20 --json
   imsg send --chat-guid 'iMessage;+;chat…' --text 'bridge smoke test'
   ```

   Grant Full Disk Access to the process that will launch the bridge and
   Automation access to Messages.app. This path can send text and attachments,
   but cannot create native inline replies.

2. Optional: enable native inline replies with `imsg`'s IMCore helper:

   - Reboot into macOS Recovery, open Terminal, run `csrutil disable`, and
     reboot. This weakens a host-wide macOS protection; use a dedicated Mac.
   - In the logged-in desktop session, run `imsg launch` and leave
     Messages.app signed in.
   - Run `imsg status --json`. `advanced_features` must be `true` and
     `bridge_version` must be greater than zero.
   - Restart `imsg-bridge` after launching the helper.

   The Homebrew package contains the helper dylib. To remove it, stop the
   bridge/helper and run `csrutil enable` from Recovery. Max detects helper
   availability through `/health`: it advertises native replies only while the
   probe succeeds, and a `reply_to` send probes again and fails closed.

3. Build the bridge:

   ```sh
   cd bridge/imsg
   go build -o imsg-bridge .
   ```

4. Start it on the Mac's Tailscale address, never `0.0.0.0`:

   ```sh
   export IMSG_BRIDGE_LISTEN='100.64.0.25:8787'
   export IMSG_BRIDGE_TOKEN="$(openssl rand -hex 32)"
   export IMSG_ALLOWED_CHAT_GUID='iMessage;+;chat…'
   exec ./imsg-bridge
   ```

   Optional settings are `IMSG_PATH`, `IMSG_DB_PATH`, `IMSG_SQLITE_PATH`,
   `IMSG_ATTACHMENT_ROOT`, `IMSG_OUTBOUND_ROOT` (default
   `~/Library/Caches/max-imsg-bridge/outbound`), and
   `IMSG_MAX_ATTACHMENT_BYTES` (default 64 MiB).

5. Probe from the Max host:

   ```sh
   curl --fail --show-error \
     -H "Authorization: Bearer $IMSG_BRIDGE_TOKEN" \
     http://100.64.0.25:8787/health
   ```

Then copy the URL, token, account key, and exact same chat GUID into Max's
`imessage` configuration.

For a login service, copy `com.hchogan.max-imsg-bridge.plist.example` to
`~/Library/LaunchAgents/com.hchogan.max-imsg-bridge.plist`, replace every
placeholder, lock it down with `chmod 600`, then run:

```sh
launchctl bootstrap "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.hchogan.max-imsg-bridge.plist
launchctl kickstart -k "gui/$(id -u)/com.hchogan.max-imsg-bridge"
```

Because the token is stored in the plist, keep that file user-readable only.

## Security and recovery contract

- Bearer authentication is mandatory and comparisons are constant-time.
- `chats.list` is filtered to the configured GUID. Catch-up, watch, and sends
  reject every other chat. Arbitrary RPC methods are not exposed.
- Attachment paths never cross the bridge. Only files observed in allowlisted
  messages and contained under the Messages attachment root receive an opaque
  handle; downloads are bounded and imported into Max's content-addressed
  BlobStore.
- Outbound attachments accept bounded bytes, return a random one-shot handle,
  and can be consumed only by an allowlisted `send`. The bridge substitutes its
  controlled local path immediately before the RPC, removes it afterwards, and
  removes bridge-named orphan files at startup without touching unrelated
  files or directories. Caller-supplied paths are rejected.
- `messages.after` is authoritative. Watch only wakes Max early; the durable
  ROWID cursor is still reconciled periodically and after reconnects.
- Confirmed mention identities and their attributed UTF-16 ranges are read
  from each allowlisted row's native `attributedBody` metadata. The bridge
  emits the stable handle plus the exact visible substring/range; contact-book
  names never decide identity or whether Max was mentioned.
- A `chat.db` replacement changes the source fingerprint. Max then rescans the
  one allowlisted chat and deduplicates by message GUID.
- Accepted sends are not blindly retried. Echoes or `message.send_status`
  confirm them; only an explicit `failed` status returns a send to the queue.
- `/health` and every allowlisted `reply_to` send probe `imsg status`. A dead or
  missing IMCore helper removes the reply capability and rejects the native
  reply before the send RPC; Max retains it in the durable retry queue.
- Ordinary sends explicitly use AppleScript even while the helper is active.
  Native replies use IMCore, but its immediate `lastSentMessage` GUID is
  best-effort and may be stale; the bridge strips it and Max waits for the
  authoritative `messages.after` echo before assigning native provenance.

Run `go test ./...` after bridge changes.
