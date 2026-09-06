module Max.DB.Health (operationalChecks) where

import Database.PostgreSQL.Simple (Query)

-- The boolean says whether a non-zero count is a failed health gate.  Pending
-- and retryable work is expected while traffic is flowing; expired ownership,
-- ambiguous effects, parked work, and deterministic poison are not.
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
    ( "dispatch_retryable",
      False,
      "SELECT count(*) FROM message_dispatches WHERE status = 'failed'"
    ),
    ( "dispatch_outcome_unknown",
      True,
      "SELECT count(*) FROM message_dispatches WHERE status = 'outcome_unknown'"
    ),
    ( "dispatch_expired_lease",
      True,
      "SELECT count(*) FROM message_dispatches \
      \WHERE status IN ('reserved', 'claimed') AND lease_expires_at <= now()"
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
    ( "task_expired_attempt",
      True,
      "SELECT count(*) FROM durable_tasks work LEFT JOIN task_attempts execution ON execution.task_id=work.task_id AND execution.attempt=work.attempt AND execution.revision=work.revision WHERE work.status='running' AND (execution.turn_id IS NULL OR execution.lease_until<=now())"
    ),
    ( "task_overdue_deadline",
      True,
      "SELECT count(*) FROM durable_tasks WHERE status IN ('queued','running','waiting','retrying') AND deadline<=now()"
    ),
    ( "task_retrying",
      False,
      "SELECT count(*) FROM durable_tasks WHERE status='retrying'"
    ),
    ( "frontend_expired_lease",
      True,
      "SELECT count(*) FROM conversation_frontends front JOIN agent_turns turn USING(turn_id) WHERE front.lease_until<=now() AND turn.status IN ('starting','running','recovery-pending')"
    ),
    ( "task_notification_exhausted",
      True,
      "SELECT count(*) FROM task_notifications notice JOIN durable_tasks work USING(task_id) WHERE notice.delivered_at IS NULL AND notice.superseded_at IS NULL AND notice.review_decision->>'action' IS DISTINCT FROM 'skip' AND notice.attempts>=15 AND notice.revision=work.revision AND notice.attempt=work.attempt AND notice.body->>'status'=work.status AND work.status<>'cancelled'"
    ),
    ( "request_pending",
      False,
      "SELECT count(*) FROM conversation_requests WHERE disposition IN ('pending','delegated','waiting')"
    ),
    ( "request_failed",
      True,
      "SELECT count(*) FROM conversation_requests WHERE disposition='failed'"
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
