module Max.DB.Health (operationalChecks) where

import Database.PostgreSQL.Simple (Query)

-- A non-zero failing count needs investigation. Terminal failures remain facts;
-- operator acknowledgements no longer alter the health result.
operationalChecks :: [(String, Bool, Query)]
operationalChecks =
  [ ( "delivery_retryable",
      False,
      "SELECT count(*) FROM message_deliveries WHERE status = 'failed'"
    ),
    ( "delivery_permanent_failure",
      True,
      "SELECT count(*) FROM message_deliveries WHERE status = 'permanent_failure'"
    ),
    ( "delivery_outcome_unknown",
      True,
      "SELECT count(*) FROM message_deliveries WHERE status = 'outcome_unknown'"
    ),
    ( "monitor_publication_failure",
      True,
      "SELECT count(*) FROM monitor_fires f JOIN monitors m USING(monitor_id) WHERE m.continuation_kind='canned' AND f.finished_at IS NOT NULL AND f.cancelled_at IS NULL AND f.last_error IS NOT NULL"
    ),
    ( "journal_unresolved_outcome_unknown",
      True,
      "SELECT count(*) FROM execution_journal journal \
      \JOIN agent_turns turn USING (turn_id) \
      \WHERE journal.state = 'outcome-unknown' \
      \  AND turn.status IN ('starting', 'running', 'recovery-pending')"
    ),
    ( "sandbox_outcome_unknown",
      True,
      "SELECT count(*) FROM sandboxes WHERE status = 'outcome-unknown'"
    )
  ]
