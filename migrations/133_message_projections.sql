-- Canonical messages are facts. Consumption policy and its pending work live
-- separately, and hook execution never runs in the canonical ingest transaction.
CREATE TABLE message_projections (
  canonical_message_id bigint PRIMARY KEY REFERENCES messages ON DELETE CASCADE,
  conversation_id bigint NOT NULL REFERENCES conversations ON DELETE CASCADE,
  ingest_seq bigint NOT NULL,
  status text NOT NULL CHECK (status IN ('pending', 'ready', 'error')),
  context_visible boolean NOT NULL DEFAULT false,
  allow_activation boolean NOT NULL DEFAULT false,
  work_pending boolean NOT NULL DEFAULT false,
  dispatch_requested boolean NOT NULL DEFAULT false,
  monitor_requested boolean NOT NULL DEFAULT false,
  last_error text,
  evaluated_at timestamptz,
  CHECK (status = 'ready' OR (NOT context_visible AND NOT allow_activation))
);
CREATE INDEX message_projections_work ON message_projections (ingest_seq) WHERE work_pending;
CREATE INDEX message_projections_pending ON message_projections (conversation_id, ingest_seq) WHERE status = 'pending';
CREATE INDEX message_projections_conversation_work ON message_projections (conversation_id, ingest_seq) WHERE work_pending;

CREATE TABLE message_hook_snapshots (
  canonical_message_id bigint NOT NULL REFERENCES message_projections ON DELETE CASCADE,
  conversation_id bigint NOT NULL,
  name text NOT NULL,
  revision integer NOT NULL,
  PRIMARY KEY (canonical_message_id, name),
  FOREIGN KEY (conversation_id, name, revision) REFERENCES message_hook_versions ON DELETE CASCADE
);

CREATE TABLE message_projection_dispatches (
  canonical_message_id bigint PRIMARY KEY REFERENCES message_projections ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'started', 'finished', 'failed', 'interrupted')),
  started_at timestamptz,
  finished_at timestamptz,
  last_error text
);
CREATE INDEX message_projection_dispatches_pending ON message_projection_dispatches (canonical_message_id) WHERE status = 'pending';

-- Preserve the old decisions, but never enqueue historical side effects during
-- migration. New policy does not retroactively erase existing model memory.
INSERT INTO message_projections
  (canonical_message_id, conversation_id, ingest_seq, status, context_visible, allow_activation, evaluated_at)
SELECT m.canonical_message_id, m.conversation_id, m.ingest_seq,
       CASE WHEN EXISTS (SELECT 1 FROM message_hook_runs r WHERE r.canonical_message_id=m.canonical_message_id AND r.outcome='error') THEN 'error' ELSE 'ready' END,
       NOT m.inbound_ignored, NOT m.inbound_ignored, now()
FROM messages m;
INSERT INTO message_hook_snapshots (canonical_message_id, conversation_id, name, revision)
SELECT canonical_message_id, conversation_id, name, revision FROM message_hook_runs;

-- Readers need the historical population's statistics immediately, otherwise
-- a recent-history query can choose to scan every projection before LIMIT.
ANALYZE message_projections;

CREATE FUNCTION initialize_message_projection() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  inbound_message boolean := NEW.message_origin='inbound' AND NEW.event_kind='message';
  has_hooks boolean;
BEGIN
  SELECT inbound_message AND EXISTS (
    SELECT 1 FROM message_hooks h JOIN message_hook_versions v USING(conversation_id,name,revision)
    WHERE h.conversation_id=NEW.conversation_id AND v.enabled
  ) INTO has_hooks;
  INSERT INTO message_projections
    (canonical_message_id,conversation_id,ingest_seq,status,context_visible,allow_activation,work_pending,monitor_requested,evaluated_at)
  VALUES (NEW.canonical_message_id,NEW.conversation_id,NEW.ingest_seq,
          CASE WHEN has_hooks THEN 'pending' ELSE 'ready' END,
          NOT has_hooks, inbound_message AND NOT has_hooks, inbound_message,
          inbound_message AND NEW.ingest_class='live_delivery',
          CASE WHEN has_hooks THEN NULL ELSE now() END);
  IF has_hooks THEN
    INSERT INTO message_hook_snapshots (canonical_message_id,conversation_id,name,revision)
    SELECT NEW.canonical_message_id,h.conversation_id,h.name,h.revision
    FROM message_hooks h JOIN message_hook_versions v USING(conversation_id,name,revision)
    WHERE h.conversation_id=NEW.conversation_id AND v.enabled;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER messages_initialize_projection AFTER INSERT ON messages
FOR EACH ROW EXECUTE FUNCTION initialize_message_projection();

DROP VIEW agent_messages;
ALTER TABLE messages DROP COLUMN inbound_ignored;
CREATE VIEW agent_messages AS
SELECT m.* FROM messages m JOIN message_projections p USING(canonical_message_id)
WHERE p.status='ready' AND p.context_visible
  -- A reader must not advance its history cursor past an undecided message.
  AND NOT EXISTS (
    SELECT 1 FROM message_projections earlier
    WHERE earlier.conversation_id=p.conversation_id AND earlier.status='pending'
      AND earlier.ingest_seq<p.ingest_seq
  )
  -- Follow all containment/metadata ancestors, with UNION stopping cycles.
  -- Replies themselves remain visible; their quoted source uses this view too.
  AND NOT EXISTS (
    WITH RECURSIVE ancestors(canonical_message_id) AS (
      SELECT r.target_canonical_message_id FROM message_relations r
      WHERE r.canonical_message_id=m.canonical_message_id
        AND r.relation_kind IN ('contained_in','replace','reaction','redacts')
        AND r.target_canonical_message_id IS NOT NULL
      UNION
      SELECT r.target_canonical_message_id FROM message_relations r
      JOIN ancestors a ON a.canonical_message_id=r.canonical_message_id
      WHERE r.relation_kind IN ('contained_in','replace','reaction','redacts')
        AND r.target_canonical_message_id IS NOT NULL
    )
    SELECT 1 FROM ancestors a LEFT JOIN message_projections parent USING(canonical_message_id)
    WHERE parent.status IS DISTINCT FROM 'ready' OR NOT COALESCE(parent.context_visible,false)
  );
