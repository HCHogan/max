BEGIN;
CREATE TEMP TABLE completed_results_before AS
  SELECT to_jsonb(j) AS row FROM execution_journal j WHERE state <> 'started';
INSERT INTO execution_journal (turn_id, execution_ordinal, node_id, event_kind, state, tool_ref)
SELECT turn_id, 1000000, 'unfinished-upgrade-fixture', 'tool_call', 'started', 'send_message'
FROM agent_turns ORDER BY turn_id LIMIT 1;
\ir ../../migrations/117_diagnostic_results.sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM execution_journal WHERE node_id = 'unfinished-upgrade-fixture'
                 AND state = 'outcome-unknown' AND failure_code = 'retired_execution_journal')
    THEN RAISE EXCEPTION 'unfinished historical effect was not retained as unknown'; END IF;
  IF EXISTS (SELECT row FROM completed_results_before
             EXCEPT SELECT to_jsonb(j) FROM execution_journal j)
    THEN RAISE EXCEPTION 'completed result history changed'; END IF;
  BEGIN
    INSERT INTO execution_journal (turn_id, execution_ordinal, node_id, event_kind, state)
    SELECT turn_id, 1000001, 'forbidden-started', 'tool_call', 'started'
    FROM agent_turns ORDER BY turn_id LIMIT 1;
    RAISE EXCEPTION 'pre-effect journal entries still accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
COMMIT;
