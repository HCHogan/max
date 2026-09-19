-- Delivery receipts remain user history; no trigger schedules execution.
DROP TRIGGER message_deliveries_notify_work ON message_deliveries;
DROP FUNCTION max_notify_delivery_work();
UPDATE message_delivery_parts
SET status='outcome_unknown', last_error=COALESCE(last_error,'delivery worker retired before receipt'), updated_at=now()
WHERE status='sending';
UPDATE message_deliveries
SET status=CASE WHEN status='sending' THEN 'outcome_unknown' ELSE 'suppressed' END,
    last_error=COALESCE(last_error,'delivery queue retired; not replayed'),
    lease_owner=NULL, lease_expires_at=NULL, updated_at=now()
WHERE status IN ('pending','reserved','sending','failed');
