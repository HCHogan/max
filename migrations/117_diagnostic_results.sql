-- Stop the old process before upgrading. Preserve unfinished historical effects
-- as unknown; the running application now only appends completed diagnostics.
UPDATE execution_journal
SET state = 'outcome-unknown', finished_at = now(),
    failure_code = COALESCE(failure_code, 'retired_execution_journal'),
    failure_detail = COALESCE(failure_detail, 'process stopped before its outcome was recorded')
WHERE state = 'started';

ALTER TABLE execution_journal DROP CONSTRAINT execution_journal_state_check;
ALTER TABLE execution_journal ADD CONSTRAINT execution_journal_state_check
  CHECK (state IN ('rejected', 'succeeded', 'failed', 'committed', 'outcome-unknown'));
