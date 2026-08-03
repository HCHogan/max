-- On the observed macOS 15 Messages schema, message.reply_to_guid is populated
-- as a rolling predecessor chain for ordinary top-level iMessages. Explicit
-- inline replies are identified by thread_originator_guid instead. Earlier Max
-- builds treated the predecessor pointer as reply authority, which could turn
-- every message following a bot reply into a direct trigger.
--
-- Raw platform payloads remain untouched. Repair only the canonical reply
-- projection, rebuilding real inline replies from their authoritative field.

CREATE TEMP TABLE imessage_reply_repair ON COMMIT DROP AS
SELECT
  pe.canonical_message_id,
  pe.endpoint_id,
  NULLIF(pe.raw_payload->>'thread_originator_guid', '') AS target_native_event_id,
  target.canonical_message_id AS target_canonical_message_id,
  target.message_id AS target_message_id
FROM platform_events pe
JOIN conversation_endpoints endpoint USING (endpoint_id)
JOIN platform_accounts account USING (platform_account_id)
LEFT JOIN LATERAL (
  SELECT candidate.canonical_message_id, candidate.message_id
  FROM (
    SELECT target_event.canonical_message_id, target_message.message_id
    FROM platform_events target_event
    JOIN messages target_message USING (canonical_message_id)
    WHERE target_event.endpoint_id = pe.endpoint_id
      AND target_event.native_event_id = NULLIF(pe.raw_payload->>'thread_originator_guid', '')

    UNION ALL

    SELECT delivery.canonical_message_id, target_message.message_id
    FROM message_deliveries delivery
    JOIN messages target_message USING (canonical_message_id)
    WHERE delivery.endpoint_id = pe.endpoint_id
      AND delivery.native_event_id = NULLIF(pe.raw_payload->>'thread_originator_guid', '')
  ) candidate
  LIMIT 1
) target ON true
WHERE account.platform = 'imessage'
  AND pe.canonical_message_id IS NOT NULL;

DELETE FROM message_relations relation
USING imessage_reply_repair repair
WHERE relation.canonical_message_id = repair.canonical_message_id
  AND relation.relation_kind = 'reply';

UPDATE messages message
SET
  reply_to_message_id = repair.target_message_id,
  reply_to_canonical_message_id = repair.target_canonical_message_id,
  segments =
    CASE
      WHEN repair.target_message_id IS NULL THEN '[]'::jsonb
      ELSE jsonb_build_array(
        jsonb_build_object(
          'type', 'reply',
          'data', jsonb_build_object('id', repair.target_message_id::text)))
    END
    || COALESCE(
      (
        SELECT jsonb_agg(part.value ORDER BY part.ordinality)
        FROM jsonb_array_elements(message.segments) WITH ORDINALITY AS part(value, ordinality)
        WHERE part.value->>'type' <> 'reply'
      ),
      '[]'::jsonb)
FROM imessage_reply_repair repair
WHERE message.canonical_message_id = repair.canonical_message_id;

INSERT INTO message_relations
  (canonical_message_id, relation_kind, target_canonical_message_id, target_native_event_id)
SELECT
  canonical_message_id,
  'reply',
  target_canonical_message_id,
  target_native_event_id
FROM imessage_reply_repair
WHERE target_native_event_id IS NOT NULL
ON CONFLICT DO NOTHING;
