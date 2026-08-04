-- Wake durable dispatch and delivery workers on commit.  LISTEN clients
-- subscribe before rechecking, so notifications are hints without races; a
-- bounded timeout still discovers leases/retries becoming due by time alone.

CREATE FUNCTION max_notify_dispatch_work()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IN ('pending', 'failed') THEN
    PERFORM pg_notify('max_dispatch_work', NEW.canonical_message_id::text);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER message_dispatches_notify_work
AFTER INSERT OR UPDATE OF status, next_attempt_at ON message_dispatches
FOR EACH ROW EXECUTE FUNCTION max_notify_dispatch_work();

CREATE FUNCTION max_notify_delivery_work()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IN ('pending', 'failed') THEN
    PERFORM pg_notify('max_delivery_work', NEW.delivery_id::text);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER message_deliveries_notify_work
AFTER INSERT OR UPDATE OF status, next_attempt_at ON message_deliveries
FOR EACH ROW EXECUTE FUNCTION max_notify_delivery_work();
