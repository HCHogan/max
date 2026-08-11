-- ADR 007 step 12: telling somebody the plan finished survives a restart.
--
-- Step 11 computed the result, closed the plan, and then dispatched the turn
-- that reports it.  A process dying between the last two lost the telling — not
-- the plan's integrity, but an answer somebody was waiting for, which is the
-- part they actually notice.
--
-- The fix is the construction monitor fires already use: admit the turn first,
-- durably, and let boot recovery relaunch it.  Admission is the idempotency
-- point rather than closing, so a crash before the close is harmless: the plan
-- is driven again, reaches the same result, and finds the wake already admitted.

ALTER TABLE plans
  -- The turn opened to report this plan's outcome.  At most one, ever: a plan
  -- that reported twice would be two answers to one question, and a group
  -- reading them cannot tell which is current.
  ADD COLUMN wake_turn_id bigint REFERENCES agent_turns(turn_id) ON DELETE SET NULL,
  -- The host-authored view that turn opens with, stored rather than re-derived.
  -- Re-deriving it would mean re-running the plan, and a recovered turn is
  -- entitled to the same words the original one would have had.
  ADD COLUMN wake_view text,
  ADD CONSTRAINT plans_wake_shape_check
    CHECK ((wake_turn_id IS NULL) = (wake_view IS NULL));

CREATE UNIQUE INDEX plans_wake_turn_idx
  ON plans (wake_turn_id)
  WHERE wake_turn_id IS NOT NULL;
