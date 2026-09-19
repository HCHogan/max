# Simplification deployment: h610, 2026-09-19

Max `db80b66156e1797161de3d4395d4def6dcd4a408` was built and activated on
h610 itself. Database backup, restoration and migration rehearsal were completed
on h610, following the user's instruction to avoid cross-border artifact transfers.
This report distinguishes functional observations from historical health failures.

## Release and preservation

- All release CI jobs passed for [db80b66](https://github.com/HCHogan/max/actions/runs/35425957321).
  The final code regression passed 1,056 unit and 256 PostgreSQL examples,
  populated upgrade checks, architecture checks and offline context checks.
- A verified custom-format production snapshot was restored into the separate
  `max_release_db80b66` database. The candidate maintenance executable applied
  migrations 114–122 there before production was stopped.
- All 79 existing tables retained matching row counts and multiset fingerprints
  after excluding only the fields/rows explicitly changed by those migrations.
  Full fingerprints also recorded the expected physical changes. The only added
  table was `forward_expansions`.
- The snapshot included 193,031 messages, 625 memories, 20 reminder definitions,
  193 group files and 1,776 context compartments. Its browser-profile table was
  empty; nonempty authentication-state preservation was covered by browser fixtures.
- Thirteen post-migration invariants passed, including terminal old execution
  records, merged summary text, summary evidence and public Job ID separation.
- Old Max, browser and sandbox writers were stopped. A second, final local
  snapshot was created and verified before `nixos-rebuild switch` on h610.
  Production reached migration 122 with 59 ledger entries; admin reported `db80b66`.

The first activated system was
`/nix/store/f1jq1vaydislxa96pi1g5isgcgdiqcqr-nixos-system-h610-26.05.20260911.21a67dc`.
Its Max package is
`/nix/store/nfwa1ii4nnyjaayc55b5136xllj77pa8-max-0.18.0`.
The Nix configuration also fixes the store context of Gaoji's existing SSH
known-hosts credential, so that file is retained in the system closure.

## Functional observations

The main traffic window ran from 07:08:27 to 07:24:57 UTC, before the separately
requested integration pause.

- Real QQ input triggered a streamed `qwen3.8-27b` answer without a finish tool.
  Turn 9652 succeeded in one model round and produced five answer chunks with
  native QQ message IDs. Its first receipt was recorded at 07:10:15.125389 UTC;
  the model-completion log was at 07:10:17.042082193 UTC, about 1.92 seconds later.
  Four receipts preceded that log. These are server-side receipt and completion
  timestamps, not client screen-render timings or an exact provider-EOS timestamp.
- Two real foreground turns succeeded across five streamed model calls. The
  observation window recorded 16 confirmed QQ and 11 confirmed Matrix deliveries
  linked to those turns, plus successful static-skill, web-search and browser
  tool execution. A separate Matrix identity probe returned the configured account.
- Nine real Camoufox workspace scenarios passed on h610, including authentication
  state isolation/restoration, cancellation, transport closure and child reaping.
  Browser logs did not expose the authentication fixture state.
- A separate public HTTPS navigation to `https://example.com` read the expected
  document with the production launch options and without localhost exceptions.
  The first harness attempt omitted a required production launch option; the
  corrected probe passed.
- The deployed broker started a disposable native sandbox. Its command ran as
  uid 1000 in `/work`, could not write the Nix store or read host Max configuration.
  The disposable instance and work volume were removed afterward.
- Live image fetching, caption generation and embedding batches completed.
  Historical expired QQ URLs and unavailable forwarded messages also produced
  bounded fetch failures; those are not evidence of successful media recovery.
- Seven Historian calls completed without provider errors and six new context
  compartments were published. One intent call received HTTP 503, "Loading model";
  the five foreground and five caption calls had no recorded provider error.
- Jobs, cancellation, child joins, reminder admission and scoped memory behavior
  have unit/integration/VM coverage. This observation window did not exercise
  every one of those behaviors through a real user conversation.

## Health and operational scope

Both rehearsal and production `verify` passed schema, canonical-message and
projection checks, then exited nonzero on retained historical health facts:
4 permanently failed deliveries, 3,058 unknown delivery outcomes and 2 unknown
sandbox outcomes. These records were not rewritten or replayed to make a gate pass.

Context integrity separately found 18 source-range mismatches in five
conversations. The restored snapshot contained the same 18 IDs; no new mismatch
was introduced. Current memory/version projections matched.

QQ backfill refreshed old receipt timestamps. For records present in the restored
snapshot, native IDs were unchanged and the old states were already confirmed or
accepted. Receipt reconciliation must not be confused with replaying a send.

iMessage health timed out; the pre-cutover journal also contained iMessage
timeouts. The WeChat bridge/hook was unreachable. The user subsequently requested
that both integrations be disabled. Their historical messages and encrypted
credentials are retained; their runtime configuration and enabled routing are
removed separately from the code simplification.

The pause was committed as nix-config `a5fe08b` and built/switched on h610 to
`/nix/store/bj8i6w9y2kclykz2bj9jl5hp6iwfylhz-nixos-system-h610-26.05.20260911.21a67dc`.
The running Max revision remains `db80b66`; this report is a later documentation
commit, not another application release. Effective configuration contains neither
integration, both accounts and endpoints are disabled, and the WeChat callback
port has no listener. QQ and Matrix remain enabled. Max, NapCat and the broker
reported zero automatic restarts; a final read-only verify reported the same
three historical health counts above. Sixteen existing sandbox volumes remain.
After this restart, new confirmed QQ and Matrix receipts were observed, with no
new delivery rows for either disabled platform.

Backups and private evidence remain in
`/var/lib/max/backups/simplification-db80b66` on h610. The temporary build swapfile
was deactivated and removed. Existing zram and unrelated checkout changes were
preserved. Public reports contain measurements, not production message bodies.

The measured core remains 31,785 effective Haskell lines, or 33,540 including
active SQL; see [the responsibility manifest and counts](../code-size.md).
Major features were not removed to meet the exploratory 10,000-line aspiration.
