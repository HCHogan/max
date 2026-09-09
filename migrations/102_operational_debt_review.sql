-- Reviews never rewrite, replay, or delete the source effect. An acknowledgement
-- covers one observed revision only; a later attempt is new, unreviewed debt.
CREATE VIEW operational_debt AS
SELECT kind, entity_id, conversation_id, observed_at, md5(snapshot::text) AS fingerprint, snapshot
FROM (
  SELECT CASE d.status WHEN 'outcome_unknown' THEN 'delivery_outcome_unknown' ELSE 'delivery_permanent_failure' END AS kind,
    d.delivery_id AS entity_id, e.conversation_id, d.updated_at AS observed_at,
    jsonb_build_object('status',d.status,'attempt',d.attempt_count,'updated_epoch',extract(epoch FROM d.updated_at),
      'message_id',d.canonical_message_id,'endpoint_id',d.endpoint_id,'error_hash',md5(d.last_error)) AS snapshot
  FROM message_deliveries d JOIN conversation_endpoints e USING(endpoint_id)
  WHERE d.status IN ('outcome_unknown','permanent_failure')
  UNION ALL
  SELECT 'dispatch_outcome_unknown',d.canonical_message_id,m.conversation_id,d.updated_at,
    jsonb_build_object('status',d.status,'attempt',d.attempt_count,'updated_epoch',extract(epoch FROM d.updated_at),'error_hash',md5(d.last_error))
  FROM message_dispatches d JOIN messages m USING(canonical_message_id) WHERE d.status='outcome_unknown'
  UNION ALL
  SELECT 'media_parked',id,NULL::bigint,parked_at,
    jsonb_build_object('kind',kind,'attempt',attempts,'parked_epoch',extract(epoch FROM parked_at),'error_hash',md5(last_error),'payload_hash',md5(payload::text))
  FROM fetch_jobs WHERE parked_at IS NOT NULL
  UNION ALL
  SELECT 'monitor_fire_parked',fire_id,conversation_id,parked_at,
    jsonb_build_object('attempt',delivery_attempts,'parked_epoch',extract(epoch FROM parked_at),'error_hash',md5(last_error),'revision',definition_revision)
  FROM monitor_fires WHERE parked_at IS NOT NULL
  UNION ALL
  SELECT 'request_failed',r.message_id,m.conversation_id,r.updated_at,
    jsonb_build_object('disposition',r.disposition,'turn_id',r.turn_id,'updated_epoch',extract(epoch FROM r.updated_at),'reason_hash',md5(r.reason))
  FROM conversation_requests r JOIN messages m ON m.canonical_message_id=r.message_id WHERE r.disposition='failed'
  UNION ALL
  SELECT 'sandbox_outcome_unknown',sandbox_id,conversation_id,last_used_at,
    jsonb_build_object('status',status,'last_used_epoch',extract(epoch FROM last_used_at),'expires_epoch',extract(epoch FROM expires_at),'failure_hash',md5(failure_detail))
  FROM sandboxes WHERE status='outcome-unknown'
  UNION ALL
  SELECT 'task_notification_exhausted',notice.notification_id,work.conversation_id,work.updated_at,
    jsonb_build_object('attempts',notice.attempts,'revision',notice.revision,'attempt',notice.attempt,'body_hash',md5(notice.body::text),'review_hash',md5(notice.review_decision::text))
  FROM task_notifications notice JOIN durable_tasks work USING(task_id)
  WHERE notice.delivered_at IS NULL AND notice.superseded_at IS NULL
    AND notice.review_decision->>'action' IS DISTINCT FROM 'skip' AND notice.attempts>=15
    AND notice.revision=work.revision AND notice.attempt=work.attempt
    AND notice.body->>'status'=work.status AND work.status<>'cancelled'
) debt;

CREATE TABLE operational_debt_reviews (
  review_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('delivery_outcome_unknown','delivery_permanent_failure','dispatch_outcome_unknown','media_parked','monitor_fire_parked','request_failed','sandbox_outcome_unknown','task_notification_exhausted')),
  entity_id bigint NOT NULL,
  conversation_id bigint,
  fingerprint text NOT NULL CHECK (length(fingerprint)=32),
  snapshot jsonb NOT NULL,
  disposition text NOT NULL CHECK (disposition IN ('accepted','resolved','reopened')),
  actor text NOT NULL CHECK (length(trim(actor))>0),
  reason text NOT NULL CHECK (length(trim(reason))>0),
  evidence text NOT NULL CHECK (length(trim(evidence))>0),
  reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX operational_debt_review_latest ON operational_debt_reviews(kind,entity_id,fingerprint,review_id DESC);

CREATE FUNCTION reject_operational_review_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'operational debt reviews are append-only; append a reopened review to revoke';
END $$;
CREATE TRIGGER operational_debt_reviews_immutable BEFORE UPDATE OR DELETE ON operational_debt_reviews
FOR EACH ROW EXECUTE FUNCTION reject_operational_review_mutation();

CREATE VIEW operational_debt_status AS
SELECT debt.*,COALESCE(review.disposition,'unreviewed') AS disposition,review.review_id
FROM operational_debt debt
LEFT JOIN LATERAL (
  SELECT disposition,review_id FROM operational_debt_reviews r
  WHERE r.kind=debt.kind AND r.entity_id=debt.entity_id AND r.fingerprint=debt.fingerprint
    AND r.conversation_id IS NOT DISTINCT FROM debt.conversation_id
  ORDER BY review_id DESC LIMIT 1
) review ON true;
