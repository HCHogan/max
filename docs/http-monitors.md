# Webhook automations

Set `admin.webhook_base_url` to the HTTP(S) base reachable by event senders.
The existing admin listener serves `POST /hooks/<id>`; reverse proxies must
forward that path and its Authorization header. Without this setting the
endpoint and webhook automations are disabled. No external service is
configured automatically.

`create_automation` accepts `trigger: "webhook"` and an instruction; only group
administrators may create one. It returns the m# handle, URL and independent
bearer token. Only the token hash is stored in the
hook table; the original credential is also present in the normal tool result.
Keep it out of public replies and use a restricted sender credential file.
Listing/history do not return it. Cancel and create a replacement to rotate it.

Send a JSON body of at most 64 KiB with `Authorization: Bearer <token>`.
An optional `Idempotency-Key` identifies retries within this monitor; reuse it
only for the same event. Without it, equal JSON is deduplicated for five minutes.
The token only triggers its existing automation: request data cannot select the
conversation, instruction or permissions. Each fire runs as a foreground turn
under its creator's current authority, with the payload shown as bounded
external data, not as instructions.

| Response | Meaning |
|---|---|
| 202 | Accepted or already received; does not promise task completion. |
| 400 / 413 | Invalid JSON/headers or an oversized request. |
| 401 | Missing or invalid monitor credential. The admin token is not accepted. |
| 410 | Cancelled, expired or exhausted monitor. |
| 429 | Cooldown or bounded capacity; retry later with the same event key. |

Webhook automations default to no expiry/fire cap and no cooldown. Optional
`ttl_days`, `max_fires` and `cooldown_seconds` apply; normal automation
permissions and conversation limits still apply. Pending events use the
existing overlap policy. Coalescing preserves each accepted payload and rejects
additional work once its count or input budget is full, or once the pending
fire's inputs have already been captured. `update_automation` can select a
bounded queue instead.

`automation_history` exposes each fire's outcome. Restart interrupts queued
triggers and admitted fires; it never replays their effects. Definitions and
credentials persist; 202 is an admission acknowledgement, not a crash-durable
delivery contract. Fleet-specific addresses and Alertmanager instructions live
in the operations skill.
