-- Optimistic revision for full-row Session mutation.
--
-- In-process callers serialize on a per-session lock, while this revision
-- protects against a second process/registry or a stale administrative write.
-- A writer may update only the exact version it read and increments once per
-- committed mutation.
ALTER TABLE sessions
  ADD COLUMN revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0);
