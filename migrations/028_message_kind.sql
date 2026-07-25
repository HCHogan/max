-- The messages table is the record of what the chat actually saw, not
-- a curated view for the model.  That distinction was blurred while
-- several things the bot really said — progress narration, !debug
-- tool lines, command replies — simply weren't written down, so the
-- only place they existed was the group itself and the logs.
--
-- They are all recorded now, and `kind` says what each row is.  The
-- prompt filters on it; forensics, `!clear` and `search_messages` get
-- the whole picture.
--
--   chat     conversation — members, and the bot's own replies and
--            narration.  The only kind the transcript shows.
--   command  a `!cmd` and whatever the bot answered it with.  UI, not
--            conversation.
--   debug    the ⚙ / ↳ tool trace `!debug on` prints.
--
-- Replaces 027's is_command, which named one instance of the idea
-- rather than the idea.

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'chat';

UPDATE messages SET kind = 'command' WHERE is_command;

ALTER TABLE messages DROP COLUMN IF EXISTS is_command;

ALTER TABLE messages
  ADD CONSTRAINT messages_kind_check
  CHECK (kind IN ('chat', 'command', 'debug'));

-- 027's index was partial on the old column; rebuild it on the new one.
DROP INDEX IF EXISTS messages_group_recent_idx;
CREATE INDEX IF NOT EXISTS messages_group_recent_idx
  ON messages (group_id, received_at DESC)
  WHERE kind = 'chat';
