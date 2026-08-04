-- Forward chains are canonical messages linked by semantic containment.
-- The legacy self-referential message columns were a second content graph;
-- backfill their information once, then make that graph unrepresentable.

ALTER TABLE message_relations
  DROP CONSTRAINT message_relations_relation_kind_check;
ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_relation_kind_check
  CHECK (relation_kind IN ('reply', 'replace', 'redacts', 'reaction', 'contained_in'));

ALTER TABLE message_relations
  ADD COLUMN relation_position integer;

ALTER TABLE message_relations
  DROP CONSTRAINT message_relations_canonical_message_relation_unique;
ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_canonical_message_relation_unique
  UNIQUE NULLS NOT DISTINCT
    (canonical_message_id, relation_kind, target_canonical_message_id,
     target_native_event_id, reaction_key, reaction_added, relation_position);

INSERT INTO message_relations
  (canonical_message_id, relation_kind, target_canonical_message_id,
   target_native_event_id, relation_position)
SELECT child.canonical_message_id,
       'contained_in',
       parent.canonical_message_id,
       parent.source_native_event_id,
       child.forward_position
FROM messages child
JOIN messages parent ON parent.message_id = child.forwarded_in_message_id
WHERE child.forwarded_in_message_id IS NOT NULL
ON CONFLICT DO NOTHING;

UPDATE messages
SET occurred_at = original_sent_at
WHERE original_sent_at IS NOT NULL;

DROP INDEX messages_forward_in_idx;
DROP INDEX messages_original_id_idx;
ALTER TABLE messages
  DROP COLUMN forwarded_in_message_id,
  DROP COLUMN forward_position,
  DROP COLUMN original_message_id,
  DROP COLUMN original_sent_at;
