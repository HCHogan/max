-- Where this group's transcript starts.
--
-- The prompt used to take the last N messages, so one new message slid
-- the window and changed its very first line — and a provider's prefix
-- cache stops at the first byte that differs.  Every dispatch therefore
-- paid full price for the whole transcript.
--
-- With an anchor the window grows instead of sliding: the transcript is
-- "everything since this timestamp", which is a prefix that only ever
-- gets longer, so the cache covers all of it.  The anchor moves in one
-- step when the count passes a high-water mark, dropping back to the
-- low-water mark — one cache miss every (high - low) dispatches rather
-- than one every dispatch.
--
-- NULL means "not anchored yet"; the floor is then just cleared_at
-- (`!clear`), and the first dispatch past the high-water mark sets it.
-- `!unclear` leaves it alone: it undoes a watermark the user set, and
-- this one is bookkeeping.

ALTER TABLE sessions
  ADD COLUMN IF NOT EXISTS context_anchor timestamptz;
