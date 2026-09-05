DO $$
DECLARE acquired jsonb;
BEGIN
  IF EXISTS(SELECT 1 FROM browser_workspaces) THEN RAISE EXCEPTION 'upgrade guessed an old browser identity'; END IF;
  acquired := max_browser_acquire(4,'upgrade-runtime');
  IF acquired->>'task_id'<>'1' OR acquired->>'state'<>'cold' OR acquired->>'revision'<>'2' THEN
    RAISE EXCEPTION 'existing task did not acquire an independent cold workspace: %',acquired;
  END IF;
  IF NOT max_browser_begin(4,(acquired->>'epoch')::bigint) THEN RAISE EXCEPTION 'existing task lease rejected'; END IF;
  IF NOT max_browser_finish(4,(acquired->>'epoch')::bigint,'encrypted-fixture',true) THEN RAISE EXCEPTION 'checkpoint rejected'; END IF;
  IF (SELECT count(*) FROM browser_workspaces)<>1 THEN RAISE EXCEPTION 'task workspace identity changed'; END IF;
  IF EXISTS (SELECT 1 FROM browser_workspaces WHERE task_id=2) THEN RAISE EXCEPTION 'child inherited parent browser'; END IF;
END;
$$;
SELECT '088 -> 089 populated browser workspace upgrade passed' AS result;
