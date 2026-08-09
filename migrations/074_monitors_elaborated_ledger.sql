-- ADR 006 E3: trusted ingest provenance and elaborated monitor admissions.
-- Existing canonical history predates the host-authenticated distinction and
-- is therefore Backfill by construction.  New adapter writes name the class
-- explicitly; monitor evaluation only accepts the exact live_delivery value.
ALTER TABLE platform_events
  ADD COLUMN ingest_class text NOT NULL DEFAULT 'backfill'
    CHECK (ingest_class IN ('live_delivery', 'backfill'));

ALTER TABLE messages
  ADD COLUMN ingest_class text NOT NULL DEFAULT 'backfill'
    CHECK (ingest_class IN ('live_delivery', 'backfill'));

ALTER TABLE monitors
  ADD COLUMN armed_ingest_seq bigint NOT NULL DEFAULT 0
    CHECK (armed_ingest_seq >= 0),
  ADD COLUMN cooldown_seconds integer NOT NULL DEFAULT 60
    CHECK (cooldown_seconds >= 0),
  ADD COLUMN cooldown_until timestamptz,
  ADD COLUMN required_role text NOT NULL DEFAULT 'group_admin'
    CHECK (required_role IN ('group_admin', 'owner')),
  ADD COLUMN status_reason text;

ALTER TABLE monitors
  ADD CONSTRAINT monitors_world_lifetime_check
    CHECK (trigger_kind NOT IN ('ledger_match', 'external_poll')
      OR (expires_at IS NOT NULL AND max_fire_count IS NOT NULL));

ALTER TABLE monitor_fires
  ADD COLUMN conversation_id bigint,
  ADD COLUMN trigger_canonical_message_id bigint,
  ADD COLUMN trigger_evidence text NOT NULL DEFAULT '',
  ADD COLUMN admitted_turn_id bigint,
  ADD COLUMN counted_at_admission boolean NOT NULL DEFAULT false;

UPDATE monitor_fires f
SET conversation_id = m.conversation_id
FROM monitors m
WHERE m.monitor_id = f.monitor_id;

ALTER TABLE messages
  ADD CONSTRAINT messages_canonical_conversation_unique
    UNIQUE (canonical_message_id, conversation_id);

ALTER TABLE monitor_fires
  ALTER COLUMN conversation_id SET NOT NULL,
  ADD CONSTRAINT monitor_fires_fire_conversation_unique
    UNIQUE (fire_id, conversation_id),
  ADD CONSTRAINT monitor_fires_monitor_scope_fk
    FOREIGN KEY (monitor_id, conversation_id)
    REFERENCES monitors(monitor_id, conversation_id) ON DELETE CASCADE,
  ADD CONSTRAINT monitor_fires_trigger_scope_fk
    FOREIGN KEY (trigger_canonical_message_id, conversation_id)
    REFERENCES messages(canonical_message_id, conversation_id)
    ON DELETE SET NULL (trigger_canonical_message_id),
  ADD CONSTRAINT monitor_fires_admitted_turn_scope_fk
    FOREIGN KEY (admitted_turn_id, conversation_id)
    REFERENCES agent_turns(turn_id, conversation_id)
    ON DELETE SET NULL (admitted_turn_id);

-- A canned or elaborated output can name only a fire in its own conversation.
ALTER TABLE messages
  DROP CONSTRAINT messages_monitor_fire_id_fkey,
  ADD CONSTRAINT messages_monitor_fire_scope_fk
    FOREIGN KEY (monitor_fire_id, conversation_id)
    REFERENCES monitor_fires(fire_id, conversation_id)
    ON DELETE SET NULL (monitor_fire_id);

-- Ledger matches may queue independently.  TimeCron admission still guards
-- itself with NOT EXISTS, and idempotency keys remain the universal fallback.
DROP INDEX IF EXISTS monitor_fires_one_active_idx;
ALTER TABLE monitor_fires
  DROP CONSTRAINT IF EXISTS monitor_fires_monitor_id_scheduled_at_key;

CREATE UNIQUE INDEX monitor_fires_ledger_edge_unique
  ON monitor_fires (monitor_id, trigger_canonical_message_id)
  WHERE trigger_canonical_message_id IS NOT NULL;

CREATE UNIQUE INDEX monitor_fires_admitted_turn_unique
  ON monitor_fires (admitted_turn_id)
  WHERE admitted_turn_id IS NOT NULL;

CREATE INDEX monitors_ledger_armed_idx
  ON monitors (conversation_id, armed_ingest_seq, monitor_id)
  WHERE status = 'armed' AND trigger_kind = 'ledger_match';

-- Cross-process wakeups close the gap between an ingest transaction and the
-- scheduler sleeping with no clock deadline.  NOTIFY is delivered only after
-- the row transaction commits, so the worker always observes durable work.
CREATE FUNCTION max_notify_monitor_work() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('max_monitor_work', '1');
  RETURN NEW;
END;
$$;

CREATE TRIGGER monitors_notify_work
  AFTER INSERT OR UPDATE OF status, next_fire_at, expires_at, armed_by_principal_id ON monitors
  FOR EACH ROW EXECUTE FUNCTION max_notify_monitor_work();

CREATE TRIGGER monitor_fires_notify_work
  AFTER INSERT OR UPDATE OF admission_state, next_attempt_at, claim_expires_at,
    cancelled_at, parked_at ON monitor_fires
  FOR EACH ROW EXECUTE FUNCTION max_notify_monitor_work();
