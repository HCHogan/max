-- Re-stamp conversation_compartments.source_hash after the ADR 003 cutover.
--
-- Migration 062 redefined conversation_source_hash *and* the ledger it reads:
-- 055 rewrote canonical_content, 059 added event_kind, 060 changed occurred_at.
-- Every hash stamped before that cutover therefore describes an input set the
-- function can no longer produce, so both live consumers report a false alarm
-- on the entire history:
--
--   * the admin integrity check counts every historical compartment as a
--     bad_source_range (Max.ContextAdmin.runContextIntegrityCheck), and
--   * episode expansion flags a source mismatch on every expand handle
--     (Max.EpisodeStore.expandEpisode).
--
-- Re-stamping restores the invariant those checks exist to test: a stored hash
-- equals the current hash of its ledger range. It also forgets any genuine
-- pre-cutover drift, which is the deliberate trade — a hash whose input set no
-- longer exists cannot distinguish drift from the schema change that caused it.
-- Drift detection is meaningful again from this point forward.
--
-- Capture-run hashes are deliberately left alone: they are idempotency-key and
-- publication-CAS ingredients for one in-flight run, never a standing claim
-- about the ledger.

UPDATE conversation_compartments AS compartment
   SET source_hash = public.conversation_source_hash(
         compartment.conversation_id,
         compartment.start_ingest_seq,
         compartment.end_ingest_seq
       )
 WHERE compartment.source_hash IS DISTINCT FROM public.conversation_source_hash(
         compartment.conversation_id,
         compartment.start_ingest_seq,
         compartment.end_ingest_seq
       );
