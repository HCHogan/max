-- Media fetches that exhausted their in-process retries, keyed like the fetch
-- queue. Discovery skips a source until retry_after, so QQ media that expired
-- and forwards NapCat can no longer serve are not refetched, and relogged,
-- after every restart.
CREATE TABLE media_fetch_failures (
  kind text NOT NULL CHECK (kind IN ('image', 'forward', 'file')),
  fetch_key text NOT NULL,
  rounds integer NOT NULL DEFAULT 1 CHECK (rounds > 0),
  last_error text NOT NULL,
  failed_at timestamptz NOT NULL DEFAULT now(),
  retry_after timestamptz NOT NULL,
  PRIMARY KEY (kind, fetch_key)
);
