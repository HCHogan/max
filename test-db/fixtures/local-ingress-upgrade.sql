BEGIN;
CREATE TEMP TABLE retiring_ingress AS
  SELECT canonical_message_id,
         CASE WHEN row_number() OVER (ORDER BY canonical_message_id) = 1 THEN 'claimed' ELSE 'pending' END AS status
  FROM messages ORDER BY canonical_message_id LIMIT 2;
INSERT INTO message_dispatches(canonical_message_id,status)
SELECT canonical_message_id,status FROM retiring_ingress
ON CONFLICT (canonical_message_id) DO UPDATE SET status=EXCLUDED.status;
CREATE TEMP TABLE ingress_history_before AS SELECT to_jsonb(m) AS row FROM messages m;
CREATE TEMP TABLE terminal_dispatch_before AS
  SELECT to_jsonb(d) AS row FROM message_dispatches d
  WHERE status NOT IN ('pending','reserved','claimed','failed','deferred');
\ir ../../migrations/118_local_ingress.sql
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM retiring_ingress old JOIN message_dispatches current USING(canonical_message_id)
             WHERE current.status <> CASE WHEN old.status='claimed' THEN 'outcome_unknown' ELSE 'ignored' END)
    THEN RAISE EXCEPTION 'old dispatches were not retired conservatively'; END IF;
  IF EXISTS (SELECT 1 FROM message_dispatches WHERE status IN ('pending','reserved','claimed','failed','deferred'))
    THEN RAISE EXCEPTION 'live persistent dispatch work survived cutover'; END IF;
  IF EXISTS (SELECT row FROM ingress_history_before EXCEPT SELECT to_jsonb(m) FROM messages m)
    THEN RAISE EXCEPTION 'ingress cutover changed message history'; END IF;
  IF EXISTS (SELECT row FROM terminal_dispatch_before EXCEPT SELECT to_jsonb(d) FROM message_dispatches d)
    THEN RAISE EXCEPTION 'ingress cutover changed terminal dispatch history'; END IF;
END $$;
COMMIT;
