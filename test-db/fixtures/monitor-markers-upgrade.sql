BEGIN;
CREATE TEMP TABLE monitor_definitions_before AS SELECT to_jsonb(m) AS row FROM monitors m;
CREATE TEMP TABLE monitor_history_before AS
  SELECT to_jsonb(f) - ARRAY['claim_owner','claim_expires_at','delivery_attempts','next_attempt_at','parked_at'] AS row
  FROM monitor_fires f;
CREATE TEMP TABLE monitor_messages_before AS SELECT to_jsonb(m) AS row FROM messages m;
\ir ../../migrations/124_monitor_trigger_markers.sql
DO $$ BEGIN
  IF EXISTS (SELECT row FROM monitor_definitions_before EXCEPT SELECT to_jsonb(m) FROM monitors m)
    THEN RAISE EXCEPTION 'monitor definitions changed'; END IF;
  IF EXISTS (SELECT row FROM monitor_history_before EXCEPT SELECT to_jsonb(f) FROM monitor_fires f)
    THEN RAISE EXCEPTION 'trigger facts or publication history changed'; END IF;
  IF EXISTS (SELECT row FROM monitor_messages_before EXCEPT SELECT to_jsonb(m) FROM messages m)
    THEN RAISE EXCEPTION 'monitor migration changed raw messages'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('max_lease_free','max_lease_until'))
    THEN RAISE EXCEPTION 'worker lease helpers survived'; END IF;
END $$;
COMMIT;
