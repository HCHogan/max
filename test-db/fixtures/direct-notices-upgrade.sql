CREATE TEMP TABLE notice_retirement_fixture AS
WITH inserted AS (
  INSERT INTO task_notifications(task_id,revision,attempt,body,kind,review_decision,reviewed_at,delivered_at)
  SELECT t.task_id,t.revision,t.attempt,'{"status":"running","summary":"retirement fixture"}'::jsonb,
    'progress',v.decision,CASE WHEN v.decision IS NOT NULL THEN now() END,v.delivered
  FROM (SELECT task_id,revision,attempt FROM durable_tasks ORDER BY task_id LIMIT 1) t
  CROSS JOIN (VALUES
    ('skipped','{"action":"skip","reason":"already reported"}'::jsonb,NULL::timestamptz),
    ('pending',NULL::jsonb,NULL::timestamptz),
    ('published','{"action":"publish","reply":"retained","reason":"result"}'::jsonb,now())
  ) v(label,decision,delivered)
  RETURNING notification_id,review_decision,delivered_at
) SELECT * FROM inserted;
\ir ../../migrations/114_direct_task_notices.sql
DO $$ BEGIN
  IF (SELECT count(*) FROM notice_retirement_fixture)<>3 THEN RAISE EXCEPTION 'missing retirement fixture'; END IF;
  IF EXISTS(SELECT 1 FROM task_notifications n JOIN notice_retirement_fixture f USING(notification_id)
    WHERE n.review_decision IS DISTINCT FROM f.review_decision OR n.delivered_at IS DISTINCT FROM f.delivered_at)
  THEN RAISE EXCEPTION 'historical evidence changed'; END IF;
  IF EXISTS(SELECT 1 FROM task_notifications n JOIN notice_retirement_fixture f USING(notification_id)
    WHERE (n.review_decision->>'action'='skip' AND n.superseded_at IS NULL)
      OR (n.review_decision->>'action' IS DISTINCT FROM 'skip' AND n.superseded_at IS NOT NULL))
  THEN RAISE EXCEPTION 'incorrect notification eligibility'; END IF;
END $$;
