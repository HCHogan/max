-- A dispatch worker can disappear after durably claiming a message but before
-- recording that it finished.  The delivery side already has a name for that
-- shape — 'outcome_unknown', swept in by expiredSendingDeliverySql once the
-- ownership lease expires — but dispatch had no equivalent, and its claim
-- query only ever selects 'pending' and 'failed'.  So an abandoned 'claimed'
-- row was invisible to every reader forever: the lease expiry check in that
-- query never applied to it, and nothing else looked.
--
-- One row had been sitting that way since 2026-08-05, stranded by a restart
-- two minutes before its lease ran out.  Not a large loss on its own — the
-- message was a mirror copy — but the leak is monotonic, one message per
-- crash mid-dispatch, and silent.
--
-- Deliberately quarantine rather than retry, for the same reason the delivery
-- side does.  Re-running an abandoned dispatch re-runs the model, and the
-- abandoned attempt may already have replied; a duplicate reply in a group
-- chat is worse than a missing one, and unlike a missing one it cannot be
-- taken back.  Recovering these properly — deciding per row whether the reply
-- happened — belongs to ADR 002, which is where the durable checkpoint that
-- could answer that question is being designed.  Until then the state exists
-- so the rows are countable instead of lost.
ALTER TABLE message_dispatches DROP CONSTRAINT message_dispatches_status_check;

ALTER TABLE message_dispatches
  ADD CONSTRAINT message_dispatches_status_check
  CHECK (status = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text,
                             'ignored'::text, 'failed'::text, 'outcome_unknown'::text]));
