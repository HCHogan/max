# Bungie / Destiny 2 setup

The `destiny` skill lets players ask Max about their own Destiny 2 accounts
(vault, characters, activity history, vendors) and move or equip their gear.
The operator registers one Bungie application; players only click a login link.

## 1. Register the application (once)

At <https://www.bungie.net/en/Application> create an application:

- **OAuth Client Type: Confidential.** Public clients get no refresh token and
  would force a new login every hour; Max refuses their token responses.
- **Redirect URL:** `<admin.webhook_base_url>/oauth/bungie/callback`, e.g.
  `https://max.example.com:8443/oauth/bungie/callback`. Bungie requires HTTPS;
  any port works. It must match exactly (scheme, host, port, case).
- **Scope:** Read your Destiny 2 information (vault, inventory, vendors), Move
  or equip Destiny gear and other items. `AdvancedWriteActions` is not needed:
  free socket plugs, transfers, equips, locks and loadouts work without it.
- **Origin Header:** leave empty; Max calls from the server and sends no Origin.

Copy the API key, OAuth client_id and client_secret.

## 2. Configure Max

```yaml
admin:
  port: 7700
  webhook_base_url: https://max.example.com:8443   # must be https://
bungie:
  client_id: "12345"
```

Put the secrets in the environment file: `MAX_BUNGIE_API_KEY`,
`MAX_BUNGIE_CLIENT_SECRET`. Startup fails if any of the three values is missing
or the webhook base is not HTTPS.

The reverse proxy in front of the admin listener must forward
`GET /oauth/bungie/callback` **without SSO**, like `/hooks/`. Only players'
browsers visit it; Bungie's servers never call it, so it needs to be reachable
from phones and PCs, with a certificate browsers trust.

Tokens are sealed with `browser.state_key_file`. Rotating that key invalidates
every link; players then run `!destiny login` again.

## 3. Use

- A group admin sends `!destiny on` (and `!destiny off` to remove it). Groups
  that never enable it see no change in their prompt.
- A player sends `!destiny login`. Max replies privately with a link valid for
  15 minutes, usable once. In a QQ group the link goes to their DMs; if the DM
  fails (not friends) the group only gets a notice, never the link.
- The callback page names the chat identity the account was bound to.
- `!destiny` shows the link and its expiry; `!destiny logout` deletes it.

The manifest syncs in the background at startup and every six hours (about
twenty tables, a few hundred MB of JSON streamed through a temporary file).
Until the first sync finishes, name search is unavailable but hash lookups
fall back to Bungie's per-entity endpoint.

## Guide snapshots

After loading the destiny skill, `destiny_guide` reads the four community guide
workbooks packaged in `data/destiny-guides/`. It needs neither a player's linked
account nor a command sandbox. It follows the existing Bungie configuration and
conversation opt-in gates.

- `action=index` lists sources, worksheet IDs, raw-grid schemas, previews and
  source status; filter with `source` or `sheet` and continue with `next_offset`.
- `action=read` reads CSV records by zero-based `offset`, returning one-based
  spreadsheet row numbers and cells keyed by A/B/AA. Its metadata includes the
  complete text of relevant merged cells, even when their anchor is outside
  the requested page.
- `action=find` uses a POSIX extended regex per nonempty cell, case-insensitive
  by default. `columns` can restrict the search. Legacy/ignore/hidden sheets are
  excluded unless a sheet is explicitly selected or `include_legacy=true`.

Cells are strings and retain author notes and test conditions. A response budget
shortens a page rather than truncating a cell; an oversized single record returns
`too_large`. Fetch dates are not game-patch certification. Figures and charts
are not transcribed into CSV text. For fuzzy recommendations, inspect relevant
worksheets and their conditions rather than treating regex as semantic search.

Chinese copies live under `data/destiny-guides/zh-chs`; original English files
are retained. Official names are matched by Manifest definition hash. The
translation index reports `status=terms-only` for a terminology draft whose
community prose remains English, or `status=complete` after prose translation.
The tool defaults to Chinese with `original_cells`
for review; `language=en` returns English. Regex search always checks both
languages and counts each matching spreadsheet row once. Original metadata
details remain English, while merged cell values follow the selected language.

Refresh with `scripts/fetch-destiny-guides.py`, then
`scripts/translate-destiny-guides.py` and its `--check`, then rebuild and deploy Max.
The host checks that each Chinese CSV is bound to the current English SHA-256;
stale translations are rejected. Translation services are only used by the
offline generator, never by the running bot.
The running process keeps its immutable snapshot and reports a bundle hash.

## API shapes

`destiny_shape` answers from `data/bungie-shapes.json`, generated from Bungie's
OpenAPI specification pinned in `scripts/bungie-shapes.py`. When Bungie
publishes a new spec, bump the pinned commit and run
`python3 scripts/bungie-shapes.py`; the build embeds the regenerated file.

## Troubleshooting

- `bungie: login failed` in the log with `invalid_grant`: the code was already
  used or the redirect URL in the portal differs from the one Max serves.
- A player's link disappears on its own: Bungie rejected the refresh token
  (revoked in the Bungie.net settings, or 90 days without use). They log in again.
- `destiny manifest: table failed`: the old rows stay; the next six-hour pass retries.
