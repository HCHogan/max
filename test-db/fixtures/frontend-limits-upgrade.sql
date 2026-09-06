BEGIN;
INSERT INTO conversations(conversation_id,conversation_kind,legacy_group_id)
VALUES(91,'group',9091),(92,'group',9092);
INSERT INTO agent_turns(turn_id,conversation_id,turn_ordinal,initiator_principal_id,status)
VALUES(91,91,1,1,'running'),(92,92,1,1,'running');
SELECT max_frontend_claim(91), max_frontend_claim(92);
UPDATE conversation_frontends SET lease_until=now()-interval '1 second' WHERE turn_id=92;
CREATE TEMP TABLE previous_frontend_leases AS SELECT * FROM conversation_frontends;
\ir ../../migrations/091_frontend_limits.sql
DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM conversation_frontends current JOIN previous_frontend_leases previous USING(turn_id)
    WHERE current.turn_id=91 AND current.lease_until=previous.lease_until+interval '450 seconds') THEN
    RAISE EXCEPTION 'active frontend lease was not extended in place';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM conversation_frontends current JOIN previous_frontend_leases previous USING(turn_id)
    WHERE current.turn_id=92 AND current.lease_until=previous.lease_until) THEN
    RAISE EXCEPTION 'expired frontend lease was revived';
  END IF;
  IF NOT max_frontend_claim(92) THEN
    RAISE EXCEPTION 'expired frontend could not be reclaimed';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM conversation_frontends
    WHERE turn_id=92 AND lease_until>clock_timestamp()+interval '890 seconds'
      AND lease_until<=clock_timestamp()+interval '900 seconds') THEN
    RAISE EXCEPTION 'new frontend activation did not receive the doubled lease';
  END IF;
END;
$$;
COMMIT;
SELECT '091 frontend lease preservation and new activation passed' AS result;
