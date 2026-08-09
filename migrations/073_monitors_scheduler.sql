-- ADR 006 E2: absorb reminders into the unified monitor scheduler without
-- adding a new trigger capability.  E2 admits only TimeCron + canned fires;
-- later migrations extend the typed vocabulary and continuation class.
CREATE TABLE monitors (
  monitor_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id bigint NOT NULL
    REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  monitor_ordinal bigint NOT NULL CHECK (monitor_ordinal > 0),
  armed_by_principal_id bigint
    REFERENCES principals(principal_id) ON DELETE SET NULL,
  arming_turn_id bigint,
  -- Legacy reminder text was not constrained to non-blank values. Preserve
  -- it byte-for-byte here; the agent-facing writer validates new input.
  goal_text text NOT NULL,
  trigger_kind text NOT NULL
    CHECK (trigger_kind IN ('time_cron', 'ledger_match', 'external_poll')),
  trigger_version integer NOT NULL DEFAULT 1 CHECK (trigger_version > 0),
  trigger_spec jsonb NOT NULL CHECK (jsonb_typeof(trigger_spec) = 'object'),
  continuation_kind text NOT NULL
    CHECK (continuation_kind IN ('canned', 'elaborated')),
  effect_ceiling jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(effect_ceiling) = 'object'),
  status text NOT NULL DEFAULT 'armed'
    CHECK (status IN ('armed', 'fired', 'cancelled', 'expired')),
  fire_count bigint NOT NULL DEFAULT 0 CHECK (fire_count >= 0),
  max_fire_count bigint CHECK (max_fire_count IS NULL OR max_fire_count > 0),
  expires_at timestamptz,
  schedule_cron text,
  next_fire_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz,
  CONSTRAINT monitors_scope_unique UNIQUE (monitor_id, conversation_id),
  CONSTRAINT monitors_ordinal_unique UNIQUE (conversation_id, monitor_ordinal),
  CONSTRAINT monitors_arming_turn_scope_fk
    FOREIGN KEY (arming_turn_id, conversation_id)
    REFERENCES agent_turns(turn_id, conversation_id),
  CONSTRAINT monitors_cancelled_at_check
    CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  CONSTRAINT monitors_time_cron_shape_check
    CHECK (trigger_kind <> 'time_cron'
      OR ((status = 'armed' AND next_fire_at IS NOT NULL)
        OR (status <> 'armed' AND next_fire_at IS NULL)))
);

CREATE INDEX monitors_time_due_idx
  ON monitors (next_fire_at, monitor_id)
  WHERE status = 'armed' AND trigger_kind = 'time_cron';

CREATE TABLE monitor_fires (
  fire_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  monitor_id bigint NOT NULL REFERENCES monitors(monitor_id) ON DELETE CASCADE,
  idempotency_key text NOT NULL,
  scheduled_at timestamptz NOT NULL,
  admission_state text NOT NULL DEFAULT 'pending'
    CHECK (admission_state IN ('pending', 'dispatched')),
  claim_owner text,
  claim_expires_at timestamptz,
  delivery_attempts integer NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0),
  next_attempt_at timestamptz,
  last_error text,
  parked_at timestamptz,
  outbound_canonical_message_id bigint
    REFERENCES messages(canonical_message_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  dispatched_at timestamptz,
  cancelled_at timestamptz,
  UNIQUE (monitor_id, idempotency_key),
  UNIQUE (monitor_id, scheduled_at),
  UNIQUE (outbound_canonical_message_id),
  CONSTRAINT monitor_fires_claim_shape_check
    CHECK ((claim_owner IS NULL) = (claim_expires_at IS NULL)),
  CONSTRAINT monitor_fires_retry_shape_check
    CHECK (next_attempt_at IS NULL OR parked_at IS NULL),
  CONSTRAINT monitor_fires_dispatch_shape_check
    CHECK ((admission_state = 'dispatched') = (dispatched_at IS NOT NULL)),
  CONSTRAINT monitor_fires_cancel_shape_check
    CHECK (cancelled_at IS NULL OR admission_state = 'pending')
);

CREATE INDEX monitor_fires_pending_idx
  ON monitor_fires (COALESCE(next_attempt_at, created_at), fire_id)
  WHERE admission_state = 'pending' AND cancelled_at IS NULL AND parked_at IS NULL;

CREATE UNIQUE INDEX monitor_fires_one_active_idx
  ON monitor_fires (monitor_id)
  WHERE admission_state = 'pending' AND cancelled_at IS NULL;

-- A canonical canned delivery names its fire.  This is the idempotent
-- publication boundary: after a crash the scheduler finds the committed row
-- instead of publishing the same fire a second time.
ALTER TABLE messages ADD COLUMN monitor_fire_id bigint
  REFERENCES monitor_fires(fire_id) ON DELETE SET NULL;

CREATE UNIQUE INDEX messages_monitor_fire_unique
  ON messages (monitor_fire_id) WHERE monitor_fire_id IS NOT NULL;

-- Every reminder created through Max belongs to a canonical conversation.
-- Fail the migration rather than silently losing an orphan from an old manual
-- write or a damaged database.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM reminders r
    LEFT JOIN conversations c ON c.legacy_group_id = r.group_id
    WHERE c.conversation_id IS NULL
  ) THEN
    RAISE EXCEPTION 'cannot migrate reminder without canonical conversation';
  END IF;
END $$;

-- Preserve the legacy id as an internal monitor id so retry rows can be
-- migrated without a temporary mapping table.  The model only sees the new
-- per-conversation m# ordinal allocated deterministically below.
INSERT INTO monitors
  (monitor_id, conversation_id, monitor_ordinal, armed_by_principal_id,
   goal_text, trigger_kind, trigger_version, trigger_spec,
   continuation_kind, effect_ceiling, status, fire_count,
   schedule_cron, next_fire_at, created_at, updated_at)
OVERRIDING SYSTEM VALUE
SELECT
  r.id,
  c.conversation_id,
  row_number() OVER (
    PARTITION BY c.conversation_id ORDER BY r.created_at, r.id
  ),
  r.author_principal_id,
  r.text,
  'time_cron',
  1,
  jsonb_strip_nulls(jsonb_build_object(
    'kind', 'TimeCron', 'version', 1, 'at', r.fire_at, 'cron', r.cron_expr
  )),
  'canned',
  '{}'::jsonb,
  CASE WHEN r.fired_at IS NULL THEN 'armed' ELSE 'fired' END,
  CASE WHEN r.fired_at IS NULL THEN 0 ELSE 1 END,
  r.cron_expr,
  CASE WHEN r.fired_at IS NULL THEN r.fire_at ELSE NULL END,
  r.created_at,
  COALESCE(r.fired_at, r.created_at)
FROM reminders r
JOIN conversations c ON c.legacy_group_id = r.group_id;

SELECT setval(
  pg_get_serial_sequence('monitors', 'monitor_id'),
  GREATEST(COALESCE((SELECT max(monitor_id) FROM monitors), 0), 1),
  EXISTS (SELECT 1 FROM monitors)
);

-- A fired legacy one-shot becomes historical dispatched evidence.  A row
-- already in retry/backoff/parked state becomes a pending fire so boot can
-- resume exactly where the old worker would have.
INSERT INTO monitor_fires
  (monitor_id, idempotency_key, scheduled_at, admission_state,
   delivery_attempts, next_attempt_at, last_error, parked_at,
   created_at, dispatched_at)
SELECT
  r.id,
  'legacy-reminder:' || r.id::text || ':' || extract(epoch FROM r.fire_at)::text,
  r.fire_at,
  CASE WHEN r.fired_at IS NULL THEN 'pending' ELSE 'dispatched' END,
  r.delivery_attempts,
  r.next_attempt_at,
  r.last_error,
  r.parked_at,
  r.created_at,
  r.fired_at
FROM reminders r
WHERE r.fired_at IS NOT NULL
   OR r.delivery_attempts > 0
   OR r.next_attempt_at IS NOT NULL
   OR r.parked_at IS NOT NULL;

DROP TABLE reminders;
