BEGIN;
INSERT INTO browser_profiles(profile_id,conversation_id,principal_id,name,origin,checkpoint)
VALUES(95,1,1,'retained','https://example.com','encrypted-upgrade-fixture');
INSERT INTO browser_workspaces(task_id,revision,generation,epoch,owner_turn_id,runtime_id,state,checkpoint,profile_id,profile_version)
VALUES(1,2,7,9,4,'old-runtime','busy','encrypted-workspace-fixture',95,1);
INSERT INTO monitors(monitor_id,conversation_id,monitor_ordinal,armed_by_principal_id,arming_turn_id,goal_text,trigger_kind,trigger_spec,continuation_kind,next_fire_at,task_profile)
OVERRIDING SYSTEM VALUE VALUES(95,1,1,1,1,'frozen monitor goal','time_cron','{}','elaborated',now()+interval '1 hour','browser');
INSERT INTO browser_monitor_profiles(monitor_id,profile_id,profile_version) VALUES(95,95,1);
INSERT INTO monitor_fires(monitor_id,conversation_id,idempotency_key,scheduled_at,claim_owner,claim_expires_at)
VALUES(95,1,'retained-occurrence',now(),'old-worker',now()-interval '1 second');
CREATE TEMP TABLE before_workspace_authority AS SELECT * FROM browser_workspaces;
CREATE TEMP TABLE before_fire_authority AS SELECT * FROM monitor_fires;
\ir ../../migrations/095_haskell_authority_and_workspaces.sql
\ir ../../migrations/096_haskell_monitor_admission.sql
DO $$
BEGIN
  IF EXISTS((SELECT * FROM browser_workspaces EXCEPT SELECT * FROM before_workspace_authority)
    UNION ALL (SELECT * FROM before_workspace_authority EXCEPT SELECT * FROM browser_workspaces)) THEN
    RAISE EXCEPTION 'browser ownership/checkpoint state changed during upgrade';
  END IF;
  IF EXISTS((SELECT * FROM monitor_fires EXCEPT SELECT * FROM before_fire_authority)
    UNION ALL (SELECT * FROM before_fire_authority EXCEPT SELECT * FROM monitor_fires)) THEN
    RAISE EXCEPTION 'frozen occurrence or expired claim changed during upgrade';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgname IN ('monitor_fire_snapshot','zz_browser_fire_profile','browser_profile_changed')) THEN
    RAISE EXCEPTION 'snapshot or profile business trigger survived';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_proc WHERE proname IN ('max_task_authorize','max_task_admit','max_task_resource','max_monitor_task_admit','max_browser_acquire','max_browser_begin','max_browser_finish')) THEN
    RAISE EXCEPTION 'retired business API survived';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM monitor_fires WHERE monitor_id=95 AND definition_snapshot->>'browser_profile_version'='1' AND claim_expires_at<clock_timestamp()) THEN
    RAISE EXCEPTION 'snapshot version or fencing evidence lost';
  END IF;
END;
$$;
COMMIT;
SELECT '095/096 retained frozen occurrences and busy browser ownership' AS result;
