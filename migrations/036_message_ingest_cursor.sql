-- A database-owned total order for durable message ingestion.
--
-- Platform message ids are not monotonic, and received_at is not unique.  A
-- generated sequence gives background consumers an exact oldest-first cursor
-- that cannot jump over a large backlog.  Existing rows have no recoverable
-- ingest order, so backfill them deterministically by (received_at,
-- message_id); all rows inserted after this migration receive the real
-- database ingestion order.
CREATE SEQUENCE messages_ingest_seq_seq AS bigint;

ALTER TABLE messages ADD COLUMN ingest_seq bigint;

WITH ranked AS (
  SELECT
    message_id,
    row_number() OVER (ORDER BY received_at, message_id) AS ingest_seq
  FROM messages
)
UPDATE messages AS m
SET ingest_seq = ranked.ingest_seq
FROM ranked
WHERE ranked.message_id = m.message_id;

SELECT setval(
  'messages_ingest_seq_seq',
  COALESCE((SELECT max(ingest_seq) + 1 FROM messages), 1),
  false
);

ALTER TABLE messages
  ALTER COLUMN ingest_seq SET DEFAULT nextval('messages_ingest_seq_seq'),
  ALTER COLUMN ingest_seq SET NOT NULL;

ALTER SEQUENCE messages_ingest_seq_seq OWNED BY messages.ingest_seq;

ALTER TABLE messages
  ADD CONSTRAINT messages_ingest_seq_key UNIQUE (ingest_seq);

CREATE INDEX messages_group_ingest_idx
  ON messages (group_id, ingest_seq);

-- Cursor state is deliberately separate from sessions.  A full-row session
-- upsert must never overwrite background processing progress.
CREATE TABLE conversation_cursors (
  conversation_id bigint      NOT NULL,
  cursor_name     text        NOT NULL,
  ingest_seq      bigint      NOT NULL DEFAULT 0 CHECK (ingest_seq >= 0),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, cursor_name)
);

-- Existing memx_anchor timestamps cannot prove lossless coverage: the old
-- newest-120 query may already have jumped a backlog.  Treat the deployment
-- boundary as a legacy baseline rather than pretending it is exact coverage.
-- Raw messages remain available for the future compartment backfill/rebuild.
INSERT INTO conversation_cursors (conversation_id, cursor_name, ingest_seq)
SELECT
  s.group_id,
  'memory_extract',
  COALESCE(max(m.ingest_seq), 0)
FROM sessions AS s
LEFT JOIN messages AS m ON m.group_id = s.group_id
GROUP BY s.group_id;
