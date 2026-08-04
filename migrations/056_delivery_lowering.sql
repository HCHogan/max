-- ADR 003 slice 3: delivery is canonical -> lower -> emit.
--
-- Lowering is deterministic for a canonical body, endpoint capabilities,
-- and the resolved identity/reply/media environment.  Persist its audit
-- notes on the delivery row so operators can inspect exactly what was folded
-- or deliberately dropped for each endpoint.

ALTER TABLE message_deliveries
  ADD COLUMN lower_notes jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE message_deliveries
  ADD CONSTRAINT message_deliveries_lower_notes_array
  CHECK (jsonb_typeof(lower_notes) = 'array');

-- Runtime recovery polls expired sending leases before each ordered claim.
-- Keep the hot path proportional to the normally tiny in-flight set instead
-- of scanning the complete durable delivery ledger.
CREATE INDEX message_deliveries_sending_lease_idx
  ON message_deliveries (lease_expires_at, delivery_id)
  WHERE status = 'sending';
