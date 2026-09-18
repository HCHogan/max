BEGIN;
CREATE TEMP TABLE conversation_history_before AS
  SELECT 'requests' AS source, to_jsonb(r) AS row FROM conversation_requests r
  UNION ALL SELECT 'outcomes', to_jsonb(r) FROM request_outcomes r
  UNION ALL SELECT 'frontends', to_jsonb(r) FROM conversation_frontends r
  UNION ALL SELECT 'inputs', to_jsonb(r) FROM frontend_inputs r
  UNION ALL SELECT 'messages', to_jsonb(r) FROM messages r;
\ir ../../migrations/115_local_conversations.sql
DO $$ BEGIN
  IF EXISTS (
    WITH current_history AS (
      SELECT 'requests' AS source, to_jsonb(r) AS row FROM conversation_requests r
      UNION ALL SELECT 'outcomes', to_jsonb(r) FROM request_outcomes r
      UNION ALL SELECT 'frontends', to_jsonb(r) FROM conversation_frontends r
      UNION ALL SELECT 'inputs', to_jsonb(r) FROM frontend_inputs r
      UNION ALL SELECT 'messages', to_jsonb(r) FROM messages r
    )
    (SELECT * FROM conversation_history_before EXCEPT ALL SELECT * FROM current_history)
    UNION ALL
    (SELECT * FROM current_history EXCEPT ALL SELECT * FROM conversation_history_before)
  ) THEN RAISE EXCEPTION 'conversation cutover rewrote historical evidence'; END IF;
END $$;
COMMIT;
