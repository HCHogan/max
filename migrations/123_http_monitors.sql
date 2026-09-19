ALTER TABLE monitors DROP CONSTRAINT monitors_trigger_kind_check;
ALTER TABLE monitors ADD CONSTRAINT monitors_trigger_kind_check
  CHECK (trigger_kind IN ('time_cron', 'ledger_match', 'external_poll', 'http'));

CREATE TABLE monitor_http_hooks (
  monitor_id bigint PRIMARY KEY REFERENCES monitors(monitor_id) ON DELETE CASCADE,
  hook_id text NOT NULL UNIQUE,
  token_sha256 text NOT NULL CHECK (length(token_sha256) = 64)
);

ALTER TABLE monitor_fires ADD COLUMN trigger_payload jsonb;
