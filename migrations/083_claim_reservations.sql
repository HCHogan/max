-- A batch claim reserves work before the worker reaches it.  Treating that
-- reservation as an already-started non-idempotent attempt made a process
-- crash quarantine the unstarted tail as outcome_unknown.  Keep reservation
-- and effectful execution as distinct durable phases:
--
--   pending/failed/deferred -> reserved -> claimed/sending -> terminal
--
-- An expired reservation is safe to re-offer.  Only an expired started phase
-- is ambiguous and belongs in outcome_unknown.

ALTER TABLE message_dispatches DROP CONSTRAINT message_dispatches_status_check;

ALTER TABLE message_dispatches
  ADD CONSTRAINT message_dispatches_status_check
    CHECK (status = ANY (ARRAY[
      'pending'::text,
      'reserved'::text,
      'claimed'::text,
      'completed'::text,
      'ignored'::text,
      'failed'::text,
      'outcome_unknown'::text,
      'deferred'::text
    ]));

ALTER TABLE message_deliveries DROP CONSTRAINT message_deliveries_status_check;

ALTER TABLE message_deliveries
  ADD CONSTRAINT message_deliveries_status_check
    CHECK (status = ANY (ARRAY[
      'pending'::text,
      'reserved'::text,
      'sending'::text,
      'accepted_unconfirmed'::text,
      'confirmed'::text,
      'failed'::text,
      'outcome_unknown'::text,
      'suppressed'::text
    ]));

CREATE INDEX message_dispatches_reserved_lease_idx
  ON message_dispatches (lease_expires_at, canonical_message_id)
  WHERE status = 'reserved';

CREATE INDEX message_deliveries_reserved_lease_idx
  ON message_deliveries (lease_expires_at, delivery_id)
  WHERE status = 'reserved';
