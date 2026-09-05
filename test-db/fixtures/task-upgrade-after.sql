DO $$
BEGIN
  IF to_regclass('plans') IS NOT NULL OR to_regclass('plan_revisions') IS NOT NULL THEN
    RAISE EXCEPTION 'legacy Plan tables survived';
  END IF;
  IF (SELECT count(*) FROM retired_runtime_records)<>5 THEN
    RAISE EXCEPTION 'legacy audit records were lost';
  END IF;
  IF (SELECT count(*) FROM turn_edges WHERE edge_kind='fork-from')<>1 THEN
    RAISE EXCEPTION 'shared turn provenance was removed';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM durable_tasks WHERE task_id=1 AND revision=2 AND status='running'
    AND attempt=1 AND calls_reserved=17 AND rounds_reserved=20 AND max_calls=200 AND max_rounds=400
    AND deadline-created_at=interval '50 minutes') THEN
    RAISE EXCEPTION 'live Task identity, state or quota upgrade changed incorrectly';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM durable_tasks child JOIN durable_tasks root ON root.task_id=child.root_task_id
    WHERE child.task_id=2 AND child.parent_task_id=1 AND child.parent_revision=2
    AND child.deadline=root.deadline AND child.status='queued') THEN
    RAISE EXCEPTION 'child contract or shared deadline was lost';
  END IF;
  IF (SELECT count(*) FROM task_revisions)<>3 OR (SELECT count(*) FROM task_events)<>1
    OR (SELECT owner FROM task_attempts WHERE turn_id=4)<>'existing-worker' THEN
    RAISE EXCEPTION 'Task history or ownership was changed';
  END IF;
  IF (SELECT count(*) FROM agent_turns WHERE turn_id IN(1,4) AND status='running')<>2
    OR (SELECT count(*) FROM execution_journal WHERE turn_id IN(1,4) AND state='started')<>2 THEN
    RAISE EXCEPTION 'active Task execution was retired with Plan';
  END IF;
  IF (SELECT count(*) FROM agent_turns WHERE turn_id IN(2,3) AND status='aborted')<>2
    OR (SELECT state FROM execution_journal WHERE turn_id=3)<>'outcome-unknown' THEN
    RAISE EXCEPTION 'legacy effects were left replayable';
  END IF;
END;
$$;
SELECT '087 -> 088 populated Task and Plan upgrade passed' AS result;
