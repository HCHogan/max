-- ADR 003 slice 6: canonical meta-events share the durable delivery outbox.
--
-- The event kind belongs to the canonical ledger row, not only to an inbound
-- platform receipt: bot-authored reactions have no source platform_event.
-- Reaction polarity is relation data so add/remove operations remain
-- idempotent and transports can map removal to their native protocol.

ALTER TABLE messages
  ADD COLUMN event_kind text NOT NULL DEFAULT 'message'
    CHECK (event_kind IN ('message', 'edit', 'reaction', 'redaction', 'membership'));

UPDATE messages m
SET event_kind = source.event_kind
FROM (
  SELECT DISTINCT ON (canonical_message_id)
         canonical_message_id, event_kind
  FROM platform_events
  WHERE canonical_message_id IS NOT NULL
  ORDER BY canonical_message_id,
           CASE event_kind WHEN 'message' THEN 1 ELSE 0 END,
           platform_event_id
) source
WHERE source.canonical_message_id = m.canonical_message_id;

ALTER TABLE message_relations
  ADD COLUMN reaction_added boolean NOT NULL DEFAULT true;

ALTER TABLE message_relations
  DROP CONSTRAINT message_relations_canonical_message_id_relation_kind_target_key;

ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_canonical_message_relation_unique
  UNIQUE NULLS NOT DISTINCT
    (canonical_message_id, relation_kind, target_canonical_message_id,
     target_native_event_id, reaction_key, reaction_added);

CREATE INDEX message_relations_meta_target_idx
  ON message_relations
    (target_canonical_message_id, relation_kind, reaction_key, reaction_added,
     canonical_message_id);
