BEGIN;
INSERT INTO message_deliveries(canonical_message_id,endpoint_id,status,idempotency_key)
SELECT canonical_message_id,origin_endpoint_id,
       CASE WHEN row_number() OVER (ORDER BY canonical_message_id)=1 THEN 'sending' ELSE 'pending' END,
       'upgrade-local-delivery:' || canonical_message_id
FROM messages ORDER BY canonical_message_id LIMIT 2
ON CONFLICT (canonical_message_id,endpoint_id) DO UPDATE SET status=EXCLUDED.status;
CREATE TEMP TABLE old_delivery_work AS
  SELECT delivery_id,status FROM message_deliveries WHERE status IN ('pending','reserved','sending','failed');
INSERT INTO message_delivery_parts(delivery_id,part_index,fingerprint,idempotency_key,status,native_event_id)
SELECT delivery_id,0,'confirmed fixture','confirmed:' || delivery_id,'confirmed','native:' || delivery_id FROM old_delivery_work;
INSERT INTO message_delivery_parts(delivery_id,part_index,fingerprint,idempotency_key,status)
SELECT delivery_id,1,'uncertain fixture','uncertain:' || delivery_id,'sending' FROM old_delivery_work;
CREATE TEMP TABLE confirmed_parts_before AS SELECT to_jsonb(p) AS row FROM message_delivery_parts p WHERE status='confirmed';
CREATE TEMP TABLE delivery_messages_before AS SELECT to_jsonb(m) AS row FROM messages m;
\ir ../../migrations/119_local_delivery.sql
DO $$ BEGIN
  IF (SELECT count(*) FROM old_delivery_work)<2 THEN RAISE EXCEPTION 'delivery fixture missing old work'; END IF;
  IF EXISTS (SELECT 1 FROM old_delivery_work old JOIN message_deliveries current USING(delivery_id)
             WHERE current.status <> CASE WHEN old.status='sending' THEN 'outcome_unknown' ELSE 'suppressed' END)
    THEN RAISE EXCEPTION 'delivery work was not retired conservatively'; END IF;
  IF EXISTS (SELECT 1 FROM message_delivery_parts WHERE status='sending')
    THEN RAISE EXCEPTION 'started part still active'; END IF;
  IF EXISTS (SELECT row FROM confirmed_parts_before EXCEPT SELECT to_jsonb(p) FROM message_delivery_parts p)
    THEN RAISE EXCEPTION 'confirmed part receipt changed'; END IF;
  IF EXISTS (SELECT row FROM delivery_messages_before EXCEPT SELECT to_jsonb(m) FROM messages m)
    THEN RAISE EXCEPTION 'message history changed'; END IF;
END $$;
COMMIT;
