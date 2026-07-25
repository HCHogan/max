-- Commands are UI, not conversation.  `!ps`, `!model`, `!memory rm 3`
-- carry nothing the model needs, and `!btw` used to be worse than
-- useless: the question was persisted while its (then ephemeral) reply
-- was not, leaving a permanently unanswered-looking line that later
-- turns would helpfully answer again.
--
-- The flag is set at insert time from the same parser the dispatcher
-- uses, so "is this a command" has exactly one definition.  The
-- backfill can't call that parser, so it approximates: leading
-- whitespace, any number of rendered @-mention tokens, then a bang.
-- False positives here only hide an old line from the model, which is
-- why an approximation is acceptable for history but not for new rows.

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS is_command boolean NOT NULL DEFAULT false;

UPDATE messages
   SET is_command = true
 WHERE NOT is_command
   AND rendered_text ~ '^[[:space:]]*(\[@#[0-9]+\][[:space:]]*)*!';

-- Both history queries filter on it, and both are per-group ordered by
-- received_at, so the flag rides along on the existing indexes only if
-- it is cheap to test — it is, being a NOT NULL boolean.
CREATE INDEX IF NOT EXISTS messages_group_recent_idx
  ON messages (group_id, received_at DESC)
  WHERE NOT is_command;
