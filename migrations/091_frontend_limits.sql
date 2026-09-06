-- Frontend tools/deadline are doubled to 60/750 seconds. The ownership
-- lease must exceed that deadline; never revive already expired ownership.
CREATE OR REPLACE FUNCTION max_frontend_claim(execution bigint) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE turn agent_turns;
BEGIN
  SELECT * INTO turn FROM agent_turns WHERE turn_id=execution;
  IF NOT FOUND OR turn.status NOT IN ('starting','running','recovery-pending') THEN RETURN false; END IF;
  PERFORM conversation_id FROM conversations WHERE conversation_id=turn.conversation_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM conversation_frontends WHERE conversation_id=turn.conversation_id
    AND turn_id<>execution AND lease_until>clock_timestamp()) THEN RETURN false; END IF;
  INSERT INTO conversation_frontends(conversation_id,turn_id,lease_until)
    VALUES(turn.conversation_id,execution,clock_timestamp()+interval '900 seconds')
    ON CONFLICT(conversation_id) DO UPDATE SET turn_id=execution,lease_until=excluded.lease_until;
  UPDATE agent_turns SET frontend_managed=true WHERE turn_id=execution;
  IF turn.trigger_canonical_message_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=execution) THEN
    INSERT INTO conversation_requests(message_id,turn_id) VALUES(turn.trigger_canonical_message_id,execution)
      ON CONFLICT(message_id) DO UPDATE SET turn_id=execution WHERE conversation_requests.disposition='pending';
  END IF;
  RETURN true;
END;
$$;

UPDATE conversation_frontends SET lease_until=lease_until+interval '450 seconds'
WHERE lease_until>clock_timestamp();
