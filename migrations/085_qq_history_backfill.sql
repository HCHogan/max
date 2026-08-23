-- NapCat's reverse websocket has no durable cursor.  Record every bounded
-- reconnect recovery attempt without implying that a successful API call
-- proves the offline interval was complete.
CREATE TABLE qq_backfill_runs (
    run_id bigserial PRIMARY KEY,
    connection_generation bigint NOT NULL CHECK (connection_generation > 0),
    endpoint_id bigint NOT NULL REFERENCES conversation_endpoints(endpoint_id) ON DELETE CASCADE,
    connected_at timestamptz NOT NULL,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running'
      CHECK (status = ANY (ARRAY['running'::text, 'succeeded'::text, 'partial'::text,
                                 'failed'::text, 'skipped'::text])),
    coverage text NOT NULL DEFAULT 'best-effort-messages-only'
      CHECK (coverage = 'best-effort-messages-only'),
    anchor_message_seq text,
    requested_count integer NOT NULL CHECK (requested_count > 0),
    fetched_count integer NOT NULL DEFAULT 0 CHECK (fetched_count >= 0),
    inserted_count integer NOT NULL DEFAULT 0 CHECK (inserted_count >= 0),
    duplicate_count integer NOT NULL DEFAULT 0 CHECK (duplicate_count >= 0),
    skipped_after_cutoff integer NOT NULL DEFAULT 0 CHECK (skipped_after_cutoff >= 0),
    parse_failure_count integer NOT NULL DEFAULT 0 CHECK (parse_failure_count >= 0),
    stop_reason text,
    error text,
    CHECK (
      (status = 'running' AND finished_at IS NULL)
      OR (status <> 'running' AND finished_at IS NOT NULL AND stop_reason IS NOT NULL)
    )
);

CREATE INDEX qq_backfill_runs_endpoint_started_idx
  ON qq_backfill_runs (endpoint_id, started_at DESC);
