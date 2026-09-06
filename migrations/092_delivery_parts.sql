-- Every wire event keeps its own durable identity, even after partial failure.
CREATE TABLE message_delivery_parts (
  delivery_id bigint NOT NULL REFERENCES message_deliveries(delivery_id) ON DELETE CASCADE,
  part_index integer NOT NULL CHECK (part_index >= 0),
  fingerprint text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN
    ('pending','sending','confirmed','accepted_unconfirmed','retry','outcome_unknown','permanent_failure','suppressed')),
  attempt_count integer NOT NULL DEFAULT 0,
  native_event_id text,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(delivery_id,part_index)
);
CREATE INDEX message_delivery_parts_native ON message_delivery_parts(native_event_id) WHERE native_event_id IS NOT NULL;

-- Read-only native-copy index, shared by echo, reply and relation resolution.
-- Historical single-part receipts remain readable without synthesizing a plan.
CREATE VIEW message_delivery_copies AS
SELECT d.delivery_id,d.canonical_message_id,d.endpoint_id,p.native_event_id,
       d.idempotency_key,d.status,p.status AS part_status,d.created_at,p.updated_at
FROM message_deliveries d JOIN message_delivery_parts p USING(delivery_id)
WHERE p.native_event_id IS NOT NULL
UNION ALL
SELECT d.delivery_id,d.canonical_message_id,d.endpoint_id,d.native_event_id,
       d.idempotency_key,d.status,d.status AS part_status,d.created_at,d.updated_at
FROM message_deliveries d
WHERE d.native_event_id IS NOT NULL AND NOT EXISTS
  (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id AND p.native_event_id=d.native_event_id);
