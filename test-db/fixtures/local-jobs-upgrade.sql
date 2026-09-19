BEGIN;
CREATE TEMP TABLE jobs_history_before AS
  SELECT 'messages' AS source, to_jsonb(r) AS row FROM messages r
  UNION ALL SELECT 'memories', to_jsonb(r) FROM memories r
  UNION ALL SELECT 'monitors', to_jsonb(r) FROM monitors r
  UNION ALL SELECT 'profiles', to_jsonb(r) FROM browser_profiles r;
CREATE TEMP TABLE job_ids_before AS SELECT COALESCE(max(task_id),0) AS maximum FROM durable_tasks;
\ir ../../migrations/116_local_jobs.sql
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM durable_tasks WHERE status IN ('queued','running','waiting','retrying'))
    THEN RAISE EXCEPTION 'live durable execution survived cutover'; END IF;
  IF EXISTS (SELECT 1 FROM browser_workspaces WHERE state<>'revoked' OR checkpoint IS NOT NULL OR owner_turn_id IS NOT NULL)
    THEN RAISE EXCEPTION 'automatic browser continuation survived cutover'; END IF;
  IF nextval('job_id_seq') <= (SELECT maximum FROM job_ids_before)
    THEN RAISE EXCEPTION 'job identity sequence aliases historical handles'; END IF;
  IF EXISTS (
    WITH current_history AS (
      SELECT 'messages' AS source, to_jsonb(r) AS row FROM messages r
      UNION ALL SELECT 'memories', to_jsonb(r) FROM memories r
      UNION ALL SELECT 'monitors', to_jsonb(r) FROM monitors r
      UNION ALL SELECT 'profiles', to_jsonb(r) FROM browser_profiles r
    )
    (SELECT * FROM jobs_history_before EXCEPT ALL SELECT * FROM current_history)
    UNION ALL
    (SELECT * FROM current_history EXCEPT ALL SELECT * FROM jobs_history_before)
  ) THEN RAISE EXCEPTION 'job cutover rewrote retained user data'; END IF;
END $$;
COMMIT;
