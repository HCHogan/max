-- Crash-safe runtime state for canonical platform dispatch and delivery.
--
-- outcome_unknown is deliberately absent from the automatic claim index: a
-- non-idempotent transport may have accepted the send.  Those rows require an
-- echo/status reconciliation decision before another attempt is allowed.

DROP INDEX message_deliveries_claim_idx;
CREATE INDEX message_deliveries_claim_idx
  ON message_deliveries (next_attempt_at, delivery_id)
  WHERE status IN ('pending', 'failed');

ALTER TABLE messages
  ADD COLUMN message_origin text NOT NULL DEFAULT 'legacy'
    CHECK (message_origin IN ('legacy', 'inbound', 'outbound', 'internal')),
  ADD COLUMN source_platform text NOT NULL DEFAULT 'qq' CHECK (source_platform <> '');

UPDATE messages m
SET source_platform = a.platform
FROM conversation_endpoints e
JOIN platform_accounts a USING (platform_account_id)
WHERE e.endpoint_id = m.origin_endpoint_id;

-- Legacy writers still rely on the compatibility trigger from migration 049.
-- That trigger resolves origin_endpoint_id, after which this alphabetically
-- later BEFORE trigger records the actual platform rather than inheriting the
-- QQ default. Canonical writers already supply source_platform explicitly.
CREATE FUNCTION messages_set_source_platform() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.origin_endpoint_id IS NOT NULL THEN
    SELECT a.platform
      INTO NEW.source_platform
      FROM conversation_endpoints e
      JOIN platform_accounts a USING (platform_account_id)
     WHERE e.endpoint_id = NEW.origin_endpoint_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER zz_messages_set_source_platform_before
BEFORE INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION messages_set_source_platform();

-- Canonical bot-authored rows are published by Platform.Store directly; they
-- have no inbound source event for the legacy compatibility trigger to invent.
DROP TRIGGER messages_publish_legacy_source_after ON messages;
CREATE TRIGGER messages_publish_legacy_source_after
AFTER INSERT ON messages
FOR EACH ROW
WHEN (NEW.message_origin NOT IN ('outbound', 'internal'))
EXECUTE FUNCTION messages_publish_legacy_source();

CREATE UNIQUE INDEX message_deliveries_native_event_idx
  ON message_deliveries (endpoint_id, native_event_id)
  WHERE native_event_id IS NOT NULL;

ALTER TABLE message_dispatches
  ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN last_attempt_at timestamptz,
  ADD COLUMN completed_at timestamptz;

CREATE INDEX message_dispatches_claim_idx
  ON message_dispatches (next_attempt_at, canonical_message_id)
  WHERE status IN ('pending', 'failed');
