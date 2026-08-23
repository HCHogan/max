-- A timestamp is not a total ledger order: two messages may share it, and a
-- history import may commit later with an older source timestamp.  Persist the
-- exact canonical-ledger frontier when a turn becomes terminal so ADR-005's
-- ambient delta can use ingest_seq on both sides.
ALTER TABLE agent_turns
  ADD COLUMN finished_ingest_seq bigint
    CHECK (finished_ingest_seq IS NULL OR finished_ingest_seq >= 0);

-- Best available boundary for existing terminal turns.  New writes take the
-- frontier in the same transaction as the terminal status update.
UPDATE agent_turns t
SET finished_ingest_seq = COALESCE((
  SELECT max(m.ingest_seq)
  FROM messages m
  WHERE m.conversation_id = t.conversation_id
    AND m.received_at <= t.finished_at
), 0)
WHERE t.finished_at IS NOT NULL;
