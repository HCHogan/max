-- Message insertion wakes the timeline itself (063). Delivery/dispatch state,
-- endpoint topology, and global media work can change the same rendered view
-- without advancing conversation_seq, so notify those commits as refreshes.

CREATE TABLE admin_timeline_revisions (
  conversation_id bigint PRIMARY KEY REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION max_bump_admin_timeline(target_conversation bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO admin_timeline_revisions (conversation_id, revision, updated_at)
  VALUES (target_conversation, 1, now())
  ON CONFLICT (conversation_id) DO UPDATE
  SET revision = admin_timeline_revisions.revision + 1,
      updated_at = now();
  PERFORM pg_notify('max_timeline_work', target_conversation::text);
END
$$;

-- Replace 063's notify-only body. Its existing message trigger keeps its
-- binding and now advances the durable revision in the same transaction.
CREATE OR REPLACE FUNCTION max_notify_timeline_work()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM max_bump_admin_timeline(NEW.conversation_id);
  RETURN NEW;
END
$$;

CREATE FUNCTION max_notify_timeline_delivery_work()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  target_conversation bigint;
BEGIN
  SELECT message.conversation_id INTO target_conversation
  FROM messages message
  WHERE message.canonical_message_id = NEW.canonical_message_id;

  IF target_conversation IS NOT NULL THEN
    PERFORM max_bump_admin_timeline(target_conversation);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER message_deliveries_notify_timeline_work
AFTER INSERT OR UPDATE ON message_deliveries
FOR EACH ROW EXECUTE FUNCTION max_notify_timeline_delivery_work();

CREATE FUNCTION max_notify_timeline_dispatch_work()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  target_conversation bigint;
BEGIN
  SELECT message.conversation_id INTO target_conversation
  FROM messages message
  WHERE message.canonical_message_id = NEW.canonical_message_id;

  IF target_conversation IS NOT NULL THEN
    PERFORM max_bump_admin_timeline(target_conversation);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER message_dispatches_notify_timeline_work
AFTER INSERT OR UPDATE ON message_dispatches
FOR EACH ROW EXECUTE FUNCTION max_notify_timeline_dispatch_work();

CREATE TRIGGER conversation_endpoints_notify_timeline_work
AFTER INSERT OR UPDATE ON conversation_endpoints
FOR EACH ROW EXECUTE FUNCTION max_notify_timeline_work();

CREATE FUNCTION max_notify_all_timelines()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO admin_timeline_revisions (conversation_id, revision, updated_at)
  SELECT conversation_id, 1, now() FROM conversations
  ON CONFLICT (conversation_id) DO UPDATE
  SET revision = admin_timeline_revisions.revision + 1,
      updated_at = now();
  PERFORM pg_notify('max_timeline_work', '*');
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER fetch_jobs_notify_all_timelines
AFTER INSERT OR UPDATE OR DELETE ON fetch_jobs
FOR EACH ROW EXECUTE FUNCTION max_notify_all_timelines();

CREATE TRIGGER platform_accounts_notify_all_timelines
AFTER UPDATE ON platform_accounts
FOR EACH ROW EXECUTE FUNCTION max_notify_all_timelines();
