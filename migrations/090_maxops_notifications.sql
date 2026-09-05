CREATE TABLE maxops_notifications (
    group_id BIGINT NOT NULL REFERENCES conversations(legacy_group_id) ON DELETE CASCADE,
    alert_key TEXT NOT NULL,
    last_notified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, alert_key)
);
CREATE INDEX maxops_notifications_last_notified_idx ON maxops_notifications(last_notified_at);
