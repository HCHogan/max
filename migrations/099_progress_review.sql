-- Decisions are durable facts about one version. A skipped progress update is
-- handled without inventing a conversation message or a delivery receipt.
ALTER TABLE task_notifications
  ADD COLUMN progress_version bigint CHECK (progress_version > 0),
  ADD COLUMN review_decision jsonb,
  ADD COLUMN reviewed_at timestamptz,
  ADD CONSTRAINT task_notifications_review_check CHECK (
    (review_decision IS NULL) = (reviewed_at IS NULL)
    AND (review_decision IS NULL OR (kind='progress'
      AND jsonb_typeof(review_decision)='object'
      AND COALESCE(review_decision->>'action' IN ('publish','skip'),false))));

UPDATE task_notifications notice SET progress_version=progress.version
FROM task_progress progress WHERE notice.task_id=progress.task_id AND notice.kind='progress'
  AND notice.revision=progress.revision AND notice.attempt=progress.attempt AND notice.body=progress.body;
UPDATE task_notifications SET superseded_at=COALESCE(superseded_at,now())
WHERE kind='progress' AND progress_version IS NULL AND delivered_at IS NULL;

-- This remains an atomic publication invariant. Review/coalescing/retry policy
-- lives in Haskell; even a stale caller cannot bypass the version/decision fence.
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
  IF (managed OR EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=NEW.agent_turn_id)) AND (
    NOT EXISTS (SELECT 1 FROM agent_turns t JOIN conversation_frontends f USING(turn_id)
      WHERE t.turn_id=NEW.agent_turn_id AND t.status IN ('starting','running','recovery-pending') AND f.lease_until>clock_timestamp())
    OR EXISTS (SELECT 1 FROM task_notifications n JOIN durable_tasks t USING(task_id)
      LEFT JOIN task_progress p USING(task_id)
      WHERE n.turn_id=NEW.agent_turn_id AND (n.revision<>t.revision OR n.attempt<>t.attempt
        OR n.body->>'status' IS DISTINCT FROM t.status OR t.status='cancelled' OR n.superseded_at IS NOT NULL
        OR (n.kind='progress' AND (n.progress_version IS DISTINCT FROM p.version
          OR n.review_decision->>'action' IS DISTINCT FROM 'publish'
          OR n.delivered_at IS NOT NULL
          OR EXISTS (SELECT 1 FROM messages m WHERE m.agent_turn_id=NEW.agent_turn_id)))))
  ) THEN RAISE EXCEPTION 'conversation output lost its execution fence'; END IF;
  RETURN NEW;
END;
$$;
