-- Foreground ownership lives in this process. Retain historical request and
-- inbox rows, but no runtime reads or writes them after this cutover.
CREATE OR REPLACE FUNCTION max_task_output_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.agent_turn_id IS NULL THEN RETURN NEW; END IF;
  PERFORM c.conversation_id FROM conversations c JOIN agent_turns t USING(conversation_id)
    WHERE t.turn_id=NEW.agent_turn_id FOR UPDATE OF c;
  IF EXISTS (SELECT 1 FROM task_attempts WHERE turn_id=NEW.agent_turn_id) THEN
    RAISE EXCEPTION 'background tasks cannot publish conversation output';
  END IF;
  IF (
    NOT EXISTS (SELECT 1 FROM agent_turns t
      WHERE t.turn_id=NEW.agent_turn_id AND t.conversation_id=NEW.conversation_id AND t.status IN ('starting','running'))
    OR EXISTS (SELECT 1 FROM task_notifications n JOIN durable_tasks t USING(task_id)
      LEFT JOIN task_progress p USING(task_id)
      WHERE n.turn_id=NEW.agent_turn_id AND (n.revision<>t.revision OR n.attempt<>t.attempt
        OR n.body->>'status' IS DISTINCT FROM t.status OR t.status='cancelled' OR n.superseded_at IS NOT NULL
        OR (n.kind='progress' AND n.progress_version IS DISTINCT FROM p.version)
        OR (n.delivered_at IS NOT NULL
          OR EXISTS (SELECT 1 FROM messages m WHERE m.agent_turn_id=NEW.agent_turn_id))))
  ) THEN RAISE EXCEPTION 'conversation output lost its execution fence'; END IF;
  RETURN NEW;
END;
$$;
