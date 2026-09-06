-- Domain decisions are made explicitly by the Haskell transaction owner.
-- Keep durable constraints and wakeup notifications; remove implicit business
-- cascades only after all turn/task/control writers have migrated together.
DROP TRIGGER task_attempt_settle ON agent_turns;
DROP FUNCTION max_task_settle();
DROP TRIGGER task_completion ON durable_tasks;
DROP FUNCTION max_task_completion();
DROP TRIGGER browser_task_changed ON durable_tasks;
DROP FUNCTION max_browser_task_changed();
DROP FUNCTION max_task_claim(text);
DROP FUNCTION max_task_steer_child(bigint,bigint,text);
DROP FUNCTION max_monitor_configure(bigint,bigint,boolean,bigint,integer,text,text,integer,text,text,boolean);
DROP FUNCTION max_monitor_control(bigint,bigint,boolean,bigint,text,integer,text,text,integer,text,boolean);
DROP FUNCTION max_task_control(bigint,bigint,boolean,bigint,text,integer,bigint,text);
DROP FUNCTION max_task_inbox(bigint);

DROP FUNCTION max_frontend_claim(bigint);
-- Preserve valid ownership when upgrading the enlarged foreground deadline.
-- Expired owners remain fenced; they are never resurrected by a migration.
UPDATE conversation_frontends SET lease_until=GREATEST(lease_until,clock_timestamp()+interval '3750 seconds')
  WHERE lease_until>clock_timestamp();
