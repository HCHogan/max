-- Reports and progress are validated and routed by the host's current-attempt
-- transaction. No database text/JSON API remains for these policies.
DROP FUNCTION max_task_report(bigint,jsonb);
DROP FUNCTION max_task_progress(bigint,jsonb);
DROP FUNCTION max_task_failure(bigint,text,boolean);
DROP FUNCTION max_request_finish(bigint,text,text);
