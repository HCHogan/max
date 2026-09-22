-- Rename the public capability profile without rewriting historical snapshots.
ALTER TABLE monitors DROP CONSTRAINT monitors_task_profile_check;
ALTER TABLE monitors ADD CONSTRAINT monitors_task_profile_check
  CHECK (task_profile IN ('basic','research','browser','sandbox','operations'));
ALTER TABLE monitors ALTER COLUMN task_profile SET DEFAULT 'basic';
