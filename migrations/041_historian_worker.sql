-- Safely activate Historian v2 without automatically spending through the
-- entire legacy transcript on first boot.  Existing raw history stays
-- available for explicit backfill; normal capture starts at this deployment
-- boundary.  New conversations still initialize their historian cursor at 0.

ALTER TABLE episode_capture_runs
    DROP CONSTRAINT episode_capture_runs_status_check;

ALTER TABLE episode_capture_runs
    ADD CONSTRAINT episode_capture_runs_status_check CHECK (
        status IN ('pending', 'leased', 'generated', 'published', 'failed', 'abandoned')
    );

INSERT INTO conversation_cursors (conversation_id, cursor_name, ingest_seq)
SELECT
    s.group_id,
    'historian',
    COALESCE(max(m.ingest_seq), 0)
FROM sessions AS s
LEFT JOIN messages AS m ON m.group_id = s.group_id
GROUP BY s.group_id
ON CONFLICT (conversation_id, cursor_name) DO NOTHING;
