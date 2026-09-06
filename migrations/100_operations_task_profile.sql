-- Capability selection remains in Haskell. The store accepts the explicit
-- fleet-management profile without widening existing research task grants.
ALTER TABLE durable_tasks DROP CONSTRAINT durable_tasks_profile_check;
ALTER TABLE durable_tasks ADD CONSTRAINT durable_tasks_profile_check
  CHECK (profile IN ('research','browser','sandbox','operations'));
ALTER TABLE monitors DROP CONSTRAINT monitors_task_profile_check;
ALTER TABLE monitors ADD CONSTRAINT monitors_task_profile_check
  CHECK (task_profile IN ('research','browser','sandbox','operations'));
