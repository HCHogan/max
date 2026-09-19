BEGIN;
INSERT INTO episode_capture_runs(conversation_id,expected_cursor_seq,start_ingest_seq,end_ingest_seq,
  source_hash,source_message_count,scheduling_reason,historian_profile,prompt_version,schema_version,
  idempotency_key,status,lease_owner,lease_expires_at,next_retry_at,raw_output,last_error)
SELECT conversation_id,0,min(ingest_seq),max(ingest_seq),repeat('a',64),count(*)::integer,
  'idle','fixture','historian/test',1,md5(state||conversation_id::text)||md5(state||conversation_id::text),state,
  CASE WHEN state IN ('leased','generated') THEN 'old worker' END,
  CASE WHEN state IN ('leased','generated') THEN now()+interval '1 minute' END,
  CASE WHEN state='failed' THEN now()+interval '1 minute' END,
  'retained response','retained diagnostic'
FROM messages CROSS JOIN (VALUES ('pending'),('leased'),('generated'),('failed'),('published')) states(state)
GROUP BY conversation_id,state;
CREATE TEMP TABLE captures_before AS
  SELECT id,status,raw_output,last_error,source_hash,start_ingest_seq,end_ingest_seq FROM episode_capture_runs;
CREATE TEMP TABLE historian_messages_before AS SELECT to_jsonb(m) AS row FROM messages m;
\ir ../../migrations/121_local_historian.sql
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM episode_capture_runs WHERE status IN ('pending','leased','generated')
    OR lease_owner IS NOT NULL OR lease_expires_at IS NOT NULL OR next_retry_at IS NOT NULL)
    THEN RAISE EXCEPTION 'historian execution state survived cutover'; END IF;
  IF EXISTS (SELECT 1 FROM captures_before old JOIN episode_capture_runs current USING(id)
    WHERE current.status<>CASE WHEN old.status IN ('pending','leased','generated') THEN 'abandoned' ELSE old.status END)
    THEN RAISE EXCEPTION 'capture history was incorrectly reclassified'; END IF;
  IF EXISTS (SELECT id,raw_output,last_error,source_hash,start_ingest_seq,end_ingest_seq FROM captures_before
    EXCEPT SELECT id,raw_output,last_error,source_hash,start_ingest_seq,end_ingest_seq FROM episode_capture_runs)
    THEN RAISE EXCEPTION 'capture evidence was changed'; END IF;
  IF EXISTS (SELECT row FROM historian_messages_before EXCEPT SELECT to_jsonb(m) FROM messages m)
    THEN RAISE EXCEPTION 'historian migration changed raw history'; END IF;
END $$;
COMMIT;
