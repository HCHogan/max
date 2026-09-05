-- A deliberate capability/policy suppression is healthy: Max intentionally
-- emitted no native copy.  A deterministic poison is not.  They used to share
-- status='suppressed', which made monitoring unable to tell those two facts
-- apart.  Historical suppressed rows remain unchanged because last_error was
-- free text and cannot be classified losslessly; every new completion is
-- recorded with the distinct terminal state.

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
      'permanent_failure'::text,
      'suppressed'::text
    ]));
