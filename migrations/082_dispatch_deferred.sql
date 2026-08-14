-- Issue #17.C: a question asked while the conversation is busy waits its turn
-- instead of being folded into somebody else's.
--
-- Until now a message arriving while a turn ran was pushed into that turn's
-- inbox as an ambient note, whatever it was about and whoever sent it.  The
-- predicate was the conversation and nothing else, so an unrelated question
-- from a second person became context in a stranger's turn and was never
-- separately answered.  Production, 2026-08-14:
--
--   absorbed into a running turn  aimed=false group_id=650536599 message_id=98421 task=t2
--
-- and the turn it landed in belonged to a different author entirely.
--
-- The queue this needs already exists — this table, with its lease, its
-- next_attempt_at and its NOTIFY trigger.  What was missing is a way to say
-- "not now" that is distinguishable from "failed".
--
-- 'deferred' is that state.  It differs from 'failed' in what it means and
-- therefore in what an operator reading the table concludes: nothing went
-- wrong, the conversation was occupied.  It differs from leaving the row
-- 'pending' with a future next_attempt_at in that the reason is recorded
-- rather than inferred, which is what lets the release step target exactly the
-- rows that are waiting on a turn.
--
-- Deliberately absent from max_notify_dispatch_work: a deferred row is
-- *scheduled*, and waking a worker that will find next_attempt_at in the
-- future is a wasted round trip.  The precise wakeup is the release — it sets
-- the row back to 'pending', which fires the existing trigger.  The claim
-- predicate still accepts 'deferred' so that a row whose releaser died is
-- picked up by the ordinary scan rather than stranded.

ALTER TABLE message_dispatches DROP CONSTRAINT message_dispatches_status_check;

ALTER TABLE message_dispatches
  ADD CONSTRAINT message_dispatches_status_check
    CHECK (status = ANY (ARRAY[
      'pending'::text,
      'claimed'::text,
      'completed'::text,
      'ignored'::text,
      'failed'::text,
      'outcome_unknown'::text,
      'deferred'::text
    ]));

-- The claim scan already orders by (next_attempt_at, canonical_message_id) and
-- filters on status; deferred rows join that set, so the partial index has to
-- cover them or a busy conversation degrades the scan it sits in.
CREATE INDEX IF NOT EXISTS message_dispatches_claimable_idx
  ON message_dispatches (next_attempt_at, canonical_message_id)
  WHERE status IN ('pending', 'failed', 'deferred');
