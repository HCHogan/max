-- A publication fence is a database invariant, not a workflow dispatcher.
-- The budget/tool policy has moved to Haskell; this guard retains only the
-- atomic rejection of background or stale foreground writers.
CREATE OR REPLACE FUNCTION max_task_output_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE managed boolean;
BEGIN
  IF NEW.agent_turn_id IS NULL THEN RETURN NEW; END IF;
  PERFORM c.conversation_id FROM conversations c JOIN agent_turns t USING(conversation_id)
    WHERE t.turn_id=NEW.agent_turn_id FOR UPDATE OF c;
  IF EXISTS (SELECT 1 FROM task_attempts WHERE turn_id=NEW.agent_turn_id) THEN
    RAISE EXCEPTION 'background tasks cannot publish conversation output';
  END IF;
  SELECT frontend_managed INTO managed FROM agent_turns WHERE turn_id=NEW.agent_turn_id;
  IF managed AND (
    NOT EXISTS (SELECT 1 FROM agent_turns t JOIN conversation_frontends f USING(turn_id)
      WHERE t.turn_id=NEW.agent_turn_id AND t.status IN ('starting','running','recovery-pending') AND f.lease_until>clock_timestamp())
    OR EXISTS (SELECT 1 FROM task_notifications n JOIN durable_tasks t USING(task_id)
      WHERE n.turn_id=NEW.agent_turn_id AND (n.revision<>t.revision OR n.attempt<>t.attempt
        OR n.body->>'status' IS DISTINCT FROM t.status OR t.status='cancelled' OR n.superseded_at IS NOT NULL))
  ) THEN RAISE EXCEPTION 'conversation output lost its execution fence'; END IF;
  RETURN NEW;
END;
$$;
DROP FUNCTION max_task_admit(bigint,bigint,bigint,text,text,text,jsonb,jsonb);
DROP FUNCTION max_task_resource(bigint,text);
DROP FUNCTION max_browser_acquire(bigint,text);
DROP FUNCTION max_browser_begin(bigint,bigint);
DROP FUNCTION max_browser_finish(bigint,bigint,text,boolean);
DROP FUNCTION max_task_authorize(bigint,text,boolean);
DROP TRIGGER browser_profile_changed ON browser_profiles;
DROP FUNCTION max_browser_profile_changed();
DROP TRIGGER monitor_fire_snapshot ON monitor_fires;
DROP FUNCTION max_monitor_snapshot();
DROP TRIGGER zz_browser_fire_profile ON monitor_fires;
DROP FUNCTION max_browser_fire_profile();
