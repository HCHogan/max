-- Reminders and monitors are one concept: an automation whose instruction
-- Max handles in the foreground when its trigger fires. Canned text becomes
-- that instruction verbatim; nothing is published without a model turn.
ALTER TABLE monitors DROP CONSTRAINT IF EXISTS monitors_required_role_check;
ALTER TABLE monitors ADD CONSTRAINT monitors_required_role_check
  CHECK (required_role IN ('member', 'group_admin', 'owner'));

-- Time automations only need their creator to still be a member; message
-- and webhook triggers keep the administrator requirement.
UPDATE monitors
   SET required_role = 'member'
 WHERE trigger_kind = 'time_cron';

-- The seed (the creator's own last inbound row) is found at or before the
-- arming frontier, which canned rows never recorded.
UPDATE monitors m
   SET continuation_kind = 'elaborated',
       effect_ceiling = '{"tool_grants": {}}'::jsonb,
       armed_ingest_seq = COALESCE(m.armed_ingest_seq,
         (SELECT COALESCE(max(message.ingest_seq), 0) FROM messages message
           WHERE message.conversation_id = m.conversation_id
             AND message.received_at <= m.created_at))
 WHERE m.continuation_kind = 'canned';

-- A canned occurrence carries no elaborated snapshot; retire any that were
-- still waiting so the next calendar edge is admitted the new way.
UPDATE monitor_fires f
   SET cancelled_at = now(), disposition = 'cancelled',
       last_error = COALESCE(last_error, 'retired with canned reminders')
  FROM monitors m
 WHERE f.monitor_id = m.monitor_id AND f.admission_state = 'pending'
   AND f.cancelled_at IS NULL AND f.task_id IS NULL
   AND f.definition_snapshot->>'goal' IS NULL;

ALTER TABLE monitors DROP CONSTRAINT IF EXISTS monitors_continuation_kind_check;
ALTER TABLE monitors ADD CONSTRAINT monitors_continuation_kind_check
  CHECK (continuation_kind = 'elaborated');
ALTER TABLE monitors ALTER COLUMN continuation_kind SET DEFAULT 'elaborated';
