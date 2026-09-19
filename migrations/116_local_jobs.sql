-- Execution does not survive this cutover. Retain historical facts and IDs.
UPDATE durable_tasks SET status='cancelled',updated_at=now(),last_error='execution retired by process-owned Jobs'
  WHERE status IN ('queued','running','waiting','retrying');
UPDATE task_notifications SET superseded_at=COALESCE(superseded_at,now()) WHERE delivered_at IS NULL;
UPDATE browser_workspaces SET state='revoked',checkpoint=NULL,owner_turn_id=NULL,runtime_id=NULL,epoch=epoch+1;

ALTER SEQUENCE durable_tasks_task_id_seq RENAME TO job_id_seq;
ALTER SEQUENCE job_id_seq OWNED BY NONE;
SELECT setval('job_id_seq', GREATEST((SELECT last_value FROM job_id_seq),
  COALESCE((SELECT max(task_id) FROM durable_tasks),0)), true);

-- These are references to a public handle, not a persistent execution row.
ALTER TABLE monitor_fires DROP CONSTRAINT IF EXISTS monitor_fires_task_id_fkey;
ALTER TABLE browser_command_events DROP CONSTRAINT IF EXISTS browser_command_events_task_id_fkey;
ALTER TABLE monitor_fires ADD COLUMN started_at timestamptz, ADD COLUMN result jsonb, ADD COLUMN finished_at timestamptz, ADD COLUMN notified_at timestamptz;
UPDATE monitor_fires fire SET started_at=work.created_at,result=work.result,finished_at=work.updated_at
  FROM durable_tasks work WHERE work.task_id=fire.task_id AND work.result IS NOT NULL;

CREATE OR REPLACE FUNCTION max_task_output_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.agent_turn_id IS NULL THEN RETURN NEW; END IF;
  PERFORM c.conversation_id FROM conversations c JOIN agent_turns t USING(conversation_id)
    WHERE t.turn_id=NEW.agent_turn_id FOR UPDATE OF c;
  IF NOT EXISTS (SELECT 1 FROM agent_turns t WHERE t.turn_id=NEW.agent_turn_id
      AND t.conversation_id=NEW.conversation_id AND t.status IN ('starting','running'))
  THEN RAISE EXCEPTION 'conversation output lost its execution fence'; END IF;
  RETURN NEW;
END;
$$;
