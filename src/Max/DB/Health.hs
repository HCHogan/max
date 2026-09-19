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
    ( "delivery_expired_lease",
      True,
      "SELECT count(*) FROM message_deliveries \
      \WHERE status IN ('reserved', 'sending') AND lease_expires_at <= now()"
    ),
    ( "media_parked",
      True,
      "SELECT count(*) FROM fetch_jobs WHERE parked_at IS NOT NULL"
    ),
    ( "monitor_fire_parked",
      True,
      "SELECT count(*) FROM monitor_fires WHERE parked_at IS NOT NULL"
    ),
    ( "monitor_fire_expired_claim",
      True,
      "SELECT count(*) FROM monitor_fires \
      \WHERE admission_state = 'pending' AND cancelled_at IS NULL \
      \  AND parked_at IS NULL AND claim_expires_at <= now()"
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
