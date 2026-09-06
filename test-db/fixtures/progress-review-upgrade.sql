-- Exercise migration of both the current progress and an older queued notice.
-- No LLM, task execution, publication or replay is performed by the migration.
SELECT setval('task_notifications_notification_id_seq',GREATEST(COALESCE(max(notification_id),0),1),max(notification_id) IS NOT NULL) FROM task_notifications;
CREATE TEMP TABLE progress_review_fixture_task AS SELECT task_id,revision,attempt FROM durable_tasks ORDER BY task_id LIMIT 1;
INSERT INTO task_progress(task_id,revision,attempt,version,body)
SELECT task_id,revision,attempt,44,'{"status":"running","summary":"review-current"}'::jsonb FROM progress_review_fixture_task
ON CONFLICT(task_id) DO UPDATE SET revision=excluded.revision,attempt=excluded.attempt,version=excluded.version,body=excluded.body;
CREATE TEMP TABLE progress_review_fixture AS
WITH inserted AS (
  INSERT INTO task_notifications(task_id,revision,attempt,body,kind,delivered_at)
  SELECT task_id,revision,attempt,jsonb_build_object('status','running','summary',value.summary),value.kind,value.delivered
  FROM progress_review_fixture_task CROSS JOIN (VALUES
    ('review-current','progress',NULL::timestamptz),
    ('review-older','progress',NULL::timestamptz),
    ('review-delivered','progress',now()),
    ('review-result','result',NULL::timestamptz)
  ) value(summary,kind,delivered)
  RETURNING notification_id,body->>'summary' AS summary
) SELECT * FROM inserted;
\ir ../../migrations/099_progress_review.sql
DO $$ BEGIN
  IF (SELECT count(*) FROM progress_review_fixture)<>4 THEN RAISE EXCEPTION 'missing upgrade fixture'; END IF;
  IF NOT EXISTS(SELECT 1 FROM task_notifications JOIN progress_review_fixture USING(notification_id)
    WHERE summary='review-current' AND progress_version=44 AND review_decision IS NULL AND superseded_at IS NULL)
  THEN RAISE EXCEPTION 'current progress was lost'; END IF;
  IF NOT EXISTS(SELECT 1 FROM task_notifications JOIN progress_review_fixture USING(notification_id)
    WHERE summary='review-older' AND progress_version IS NULL AND superseded_at IS NOT NULL)
  THEN RAISE EXCEPTION 'obsolete progress remained eligible'; END IF;
  IF NOT EXISTS(SELECT 1 FROM task_notifications JOIN progress_review_fixture USING(notification_id)
    WHERE summary='review-delivered' AND delivered_at IS NOT NULL AND superseded_at IS NULL)
  THEN RAISE EXCEPTION 'historical delivery changed'; END IF;
  IF NOT EXISTS(SELECT 1 FROM task_notifications JOIN progress_review_fixture USING(notification_id)
    WHERE summary='review-result' AND kind='result' AND progress_version IS NULL AND review_decision IS NULL AND superseded_at IS NULL)
  THEN RAISE EXCEPTION 'result notification changed'; END IF;
END $$;
