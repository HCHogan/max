-- Retain historical decisions, but never reconstruct runtime work from them.
DROP TRIGGER message_dispatches_notify_work ON message_dispatches;
DROP TRIGGER message_dispatches_notify_timeline_work ON message_dispatches;
DROP FUNCTION max_notify_dispatch_work();
DROP FUNCTION max_notify_timeline_dispatch_work();

UPDATE message_dispatches
SET status = CASE WHEN status = 'claimed' THEN 'outcome_unknown' ELSE 'ignored' END,
    last_error = COALESCE(last_error, 'dispatch retired at process-queue cutover; not replayed'),
    lease_owner = NULL, lease_expires_at = NULL, updated_at = now(), completed_at = now()
WHERE status IN ('pending', 'reserved', 'claimed', 'failed', 'deferred');
