-- Context/memory research. Aggregates and internal identifiers only; no chat bodies.
-- Run as a database reader on h610's current max database.
-- These SELECTs do not run maintenance, replay proposals, or call any model.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

SELECT now() AS snapshot_utc, current_database(),
       current_setting('transaction_read_only') AS read_only;

SELECT 'messages' AS dataset, count(*) AS rows FROM messages
UNION ALL SELECT 'compartments', count(*) FROM conversation_compartments
UNION ALL SELECT 'memories', count(*) FROM memories
UNION ALL SELECT 'capture_runs', count(*) FROM episode_capture_runs;

SELECT state, count(*), sum(source_message_count) AS source_messages,
       count(*) FILTER (WHERE embedding IS NOT NULL) AS embedded
FROM conversation_compartments GROUP BY state;
SELECT status, count(*) FROM episode_capture_runs GROUP BY status;
SELECT count(*) AS uncovered_below_historian_cursor
FROM messages m
JOIN conversation_cursors c ON c.conversation_id=m.group_id AND c.cursor_name='historian'
WHERE m.ingest_seq<=c.ingest_seq AND NOT EXISTS (
  SELECT 1 FROM conversation_compartments e
  WHERE e.conversation_id=m.group_id AND e.state='active'
    AND m.ingest_seq BETWEEN e.start_ingest_seq AND e.end_ingest_seq
);

SELECT lifecycle, count(*), count(*) FILTER (WHERE embedding IS NOT NULL) AS embedded
FROM memories GROUP BY lifecycle ORDER BY lifecycle;
SELECT proposal->>'action' AS action, outcome, count(*)
FROM episode_memory_proposals GROUP BY 1,2 ORDER BY 1,2;

-- Recover the version existing immediately before each rejected proposal.
WITH rejected AS (
  SELECT (p.proposal->>'version')::bigint AS proposed_version,
         v.version AS before_version, v.lifecycle,
         CASE WHEN m.scope='group' THEN m.scope_id=r.conversation_id
              ELSE m.source_group_id=r.conversation_id END AS same_scope
  FROM episode_memory_proposals p
  JOIN episode_capture_runs r ON r.id=p.capture_run_id
  LEFT JOIN memories m ON m.id=(p.proposal->>'id')::bigint
  LEFT JOIN LATERAL (
    SELECT version,lifecycle FROM memory_versions
    WHERE memory_id=m.id AND created_at<p.created_at
    ORDER BY version DESC LIMIT 1
  ) v ON true
  WHERE p.proposal->>'action'='update' AND p.outcome='rejected_store'
)
SELECT proposed_version-before_version AS version_delta, lifecycle, same_scope, count(*)
FROM rejected GROUP BY 1,2,3 ORDER BY 1;

SELECT (p.proposal->>'id')::bigint AS memory_id, count(*) AS rejected_updates,
       min(p.created_at), max(p.created_at), max(m.version) AS current_version
FROM episode_memory_proposals p
JOIN memories m ON m.id=(p.proposal->>'id')::bigint
WHERE p.outcome='rejected_store'
GROUP BY 1 ORDER BY rejected_updates DESC LIMIT 5;

-- Verify a representative request's supplied version, without exporting its text.
SELECT r.id AS capture_run_id, c.id AS call_id,
       substring(c.request::text FROM 'id=579 version=[0-9]+ lifecycle=[a-z]+') AS supplied_version,
       p.proposal->>'version' AS submitted_version
FROM episode_memory_proposals p
JOIN episode_capture_runs r ON r.id=p.capture_run_id
JOIN LATERAL (
  SELECT id,request FROM llm_calls
  WHERE source='historian' AND group_id=r.conversation_id
    AND at<=r.published_at AND at>r.published_at-interval '10 seconds'
  ORDER BY at DESC LIMIT 1
) c ON true
WHERE p.proposal->>'id'='579'
ORDER BY r.published_at DESC LIMIT 3;

SELECT m.id AS memory_id, m.scope_id AS stored_subject,
       i.principal_id AS canonical_subject, m.lifecycle
FROM memories m
LEFT JOIN principal_identities i ON i.native_user_id=m.scope_id::text
WHERE m.scope='user' AND m.lifecycle IN ('active','permanent')
  AND NOT EXISTS(SELECT 1 FROM principals p WHERE p.principal_id=m.scope_id);

WITH ranked AS (
  SELECT lifecycle, row_number() OVER (
    PARTITION BY scope,scope_id,source_group_id ORDER BY updated_at DESC,id DESC
  ) AS rn FROM memories WHERE lifecycle IN ('active','permanent')
)
SELECT count(*) AS live, count(*) FILTER (WHERE rn>12) AS outside_recent12,
       count(*) FILTER (WHERE lifecycle='permanent' AND rn>12) AS permanent_outside_recent12
FROM ranked;

SELECT count(*) AS traces_7d, round(avg(estimated_prompt_tokens)) AS avg_estimated,
       count(*) FILTER (WHERE NOT within_budget) AS over_budget,
       min(max_input_tokens) AS min_input_limit, max(max_input_tokens) AS max_input_limit
FROM context_plan_traces WHERE created_at>=now()-interval '7 days';
SELECT d->>'source' AS source, d->>'decision' AS decision, count(*),
       round(avg((d->>'estimated_tokens')::numeric)) AS avg_tokens,
       percentile_disc(0.95) WITHIN GROUP (ORDER BY (d->>'estimated_tokens')::int) AS p95_tokens
FROM context_plan_traces t CROSS JOIN LATERAL jsonb_array_elements(t.decisions) d
WHERE t.created_at>=now()-interval '7 days'
  AND d->>'source' IN ('history.raw','history.compartment','memory','prompt.total','prompt.system')
GROUP BY 1,2 ORDER BY 1,2;
-- Publication events, not planning traces carrying the last publication reason.
SELECT reason, count(*) AS publications_7d
FROM context_materialization_versions WHERE created_at>=now()-interval '7 days'
GROUP BY reason ORDER BY reason;

SELECT source,profile,count(*) AS calls,round(avg(prompt_tokens)) AS avg_prompt,
       percentile_disc(0.95) WITHIN GROUP (ORDER BY prompt_tokens) AS p95_prompt,
       max(prompt_tokens) AS max_prompt,
       round(100.0*sum(cached_prompt_tokens)/nullif(sum(prompt_tokens),0),1) AS cached_pct
FROM llm_usage WHERE at>=now()-interval '7 days' AND source IN ('turn','task/turn')
GROUP BY source,profile ORDER BY calls DESC;
SELECT source,profile,count(*) AS calls_above_default_input_114688,max(prompt_tokens)
FROM llm_calls WHERE at>=now()-interval '7 days' AND prompt_tokens>114688
GROUP BY source,profile;
SELECT count(*) AS requests_with_old_tool_stubs_7d
FROM llm_calls WHERE at>=now()-interval '7 days' AND source IN ('turn','task/turn')
  AND request::text LIKE '%older tool results truncated%';
SELECT count(*) AS context_length_errors_7d, max(at) AS latest
FROM llm_calls WHERE at>=now()-interval '7 days'
  AND error ~* '(context_length_exceeded|maximum context length)';

SELECT count(*) AS search_calls_7d, count(DISTINCT turn_id) AS turns,
       count(*) FILTER (WHERE result_inline->>'semantic_used'='true') AS semantic,
       count(*) FILTER (WHERE jsonb_array_length(result_inline->'results')=0) AS empty
FROM execution_journal WHERE tool_ref='context_search' AND started_at>=now()-interval '7 days';
SELECT h->>'source' AS source, count(*) AS hits,
       count(*) FILTER (WHERE h->'match'->>'lexical' IS NOT NULL) AS lexical,
       count(*) FILTER (WHERE h->'match'->>'lexical' IS NULL
                       AND (h->'match'->>'semantic')::numeric<0.6) AS semantic_only_below_06
FROM execution_journal j CROSS JOIN LATERAL jsonb_array_elements(j.result_inline->'results') h
WHERE j.tool_ref='context_search' AND j.started_at>=now()-interval '7 days'
GROUP BY 1 ORDER BY 1;

SELECT count(*) AS active_namespaces,
       count(*) FILTER (WHERE n<15) AS below_dream_size,
       count(*) FILTER (WHERE n<15 OR updated<now()-interval '49 hours') AS excluded_from_dream_now
FROM (
  SELECT count(*) AS n,max(updated_at) AS updated FROM memories WHERE lifecycle='active'
  GROUP BY scope,scope_id,source_group_id
) s;
SELECT actor_kind,operation,count(*) FROM memory_mutations
GROUP BY actor_kind,operation ORDER BY actor_kind,operation;
SELECT count(*) AS database_skills FROM skills;
SELECT count(*) AS use_skill_calls_7d FROM execution_journal
WHERE tool_ref='use_skill' AND started_at>=now()-interval '7 days';
COMMIT;
