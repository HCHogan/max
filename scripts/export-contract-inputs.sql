-- Read-only export to a private file, never a fixture checked into Git. Preserve
-- the production request and profile, including unsuccessful model responses.
BEGIN READ ONLY;
WITH ranked AS (
  SELECT *, row_number() OVER (PARTITION BY CASE WHEN source IN
      ('task-notice-review','task-progress-review') THEN 'task-notice' ELSE source END
      ORDER BY id DESC) AS ordinal
  FROM llm_calls
  WHERE source IN ('historian','task-experience','memory-maintenance','intent',
                   'task-notice-review','task-progress-review')
    AND at > now() - interval '7 days'
)
SELECT jsonb_build_object('source',source,'profile',profile,'model',model,
  'source_call_id',id,'source_at',at,'request',request,'response',response)
FROM ranked WHERE ordinal <= 20 ORDER BY source,ordinal;
COMMIT;
