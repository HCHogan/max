-- The hydrated admin timeline reads the canonical ledger directly. Wake its
-- bounded long-poll on commit instead of imposing an application polling
-- interval; conversation_seq remains the durable cursor and notifications are
-- only race-free hints.

CREATE FUNCTION max_notify_timeline_work()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('max_timeline_work', NEW.conversation_id::text);
  RETURN NEW;
END
$$;

CREATE TRIGGER messages_notify_timeline_work
AFTER INSERT ON messages
FOR EACH ROW EXECUTE FUNCTION max_notify_timeline_work();
