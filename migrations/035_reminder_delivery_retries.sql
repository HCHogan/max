-- Reminder delivery is external I/O: a transient disconnect must not be
-- recorded as if the user was reminded. Keep the scheduled fire_at intact and
-- track the delivery attempt separately so retries survive process restarts.
ALTER TABLE reminders
    ADD COLUMN delivery_attempts int NOT NULL DEFAULT 0,
    ADD COLUMN next_attempt_at timestamptz,
    ADD COLUMN last_error text,
    ADD COLUMN parked_at timestamptz;

DROP INDEX reminders_due_idx;

-- The worker sleeps on the effective due time. Parked reminders remain in the
-- table for diagnosis/cancellation but never wake the delivery worker.
CREATE INDEX reminders_due_idx
    ON reminders ((COALESCE(next_attempt_at, fire_at)))
    WHERE fired_at IS NULL AND parked_at IS NULL;
