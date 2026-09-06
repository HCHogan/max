BEGIN;
-- Existing populated fixtures include a running root, a queued child,
-- historical revisions/events and an in-flight journal entry.
UPDATE task_attempts SET lease_until=now()-interval '1 second' WHERE turn_id=4;
UPDATE conversation_frontends SET lease_until=now()-interval '1 second' WHERE turn_id=92;
CREATE TEMP TABLE before_task_settlement AS SELECT * FROM durable_tasks;
CREATE TEMP TABLE before_attempt_settlement AS SELECT * FROM task_attempts;
CREATE TEMP TABLE before_frontend_settlement AS SELECT * FROM conversation_frontends;
\ir ../../migrations/093_haskell_task_settlement.sql
DO $$
BEGIN
  IF EXISTS((SELECT * FROM durable_tasks EXCEPT SELECT * FROM before_task_settlement)
    UNION ALL (SELECT * FROM before_task_settlement EXCEPT SELECT * FROM durable_tasks)) THEN
    RAISE EXCEPTION 'task state changed during business trigger removal';
  END IF;
  IF EXISTS((SELECT * FROM task_attempts EXCEPT SELECT * FROM before_attempt_settlement)
    UNION ALL (SELECT * FROM before_attempt_settlement EXCEPT SELECT * FROM task_attempts)) THEN
    RAISE EXCEPTION 'attempt ownership/history changed during upgrade';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgname IN ('task_attempt_settle','task_completion','browser_task_changed')) THEN
    RAISE EXCEPTION 'implicit task business cascade survived';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM conversation_frontends current JOIN before_frontend_settlement previous USING(turn_id)
    WHERE current.turn_id=92 AND current.lease_until=previous.lease_until AND current.lease_until<clock_timestamp()) THEN
    RAISE EXCEPTION 'expired frontend was resurrected';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM conversation_frontends WHERE turn_id=91 AND lease_until>clock_timestamp()+interval '3740 seconds') THEN
    RAISE EXCEPTION 'valid frontend lost its activation budget';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM execution_journal WHERE turn_id=4 AND state='started') THEN
    RAISE EXCEPTION 'migration silently classified an unknown external effect';
  END IF;
END;
$$;
COMMIT;
SELECT '093 retained populated tasks, expired owners and recovery evidence' AS result;
