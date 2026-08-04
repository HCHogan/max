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
