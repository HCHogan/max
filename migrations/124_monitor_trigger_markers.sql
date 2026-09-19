-- Trigger history survives, but worker leases and persisted delivery retries do
-- not. The startup boundary interrupts unfinished triggers before ingress.
DROP VIEW operational_debt_status;
DROP VIEW operational_debt;
DROP TRIGGER monitor_fires_notify_work ON monitor_fires;
DROP INDEX monitor_fires_pending_idx;
ALTER TABLE monitor_fires
  DROP CONSTRAINT monitor_fires_cancel_shape_check,
  DROP COLUMN claim_owner,
  DROP COLUMN claim_expires_at,
  DROP COLUMN delivery_attempts,
  DROP COLUMN next_attempt_at,
  DROP COLUMN parked_at;
CREATE INDEX monitor_fires_pending_idx ON monitor_fires(fire_id)
  WHERE admission_state='pending' AND cancelled_at IS NULL;
CREATE TRIGGER monitor_fires_notify_work
  AFTER INSERT OR UPDATE OF admission_state, cancelled_at ON monitor_fires
  FOR EACH ROW EXECUTE FUNCTION max_notify_monitor_work();
DROP FUNCTION max_lease_free(text, timestamptz);
DROP FUNCTION max_lease_until(double precision);
