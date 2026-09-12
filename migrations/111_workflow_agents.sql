-- A workflow step is a view of an ordinary durable child, not another job queue.
CREATE TABLE workflow_agent_steps (
  parent_task_id bigint NOT NULL,
  parent_revision integer NOT NULL,
  call_key text NOT NULL,
  child_task_id bigint NOT NULL UNIQUE REFERENCES durable_tasks(task_id),
  child_revision integer NOT NULL,
  first_journal_id bigint NOT NULL REFERENCES execution_journal(journal_id),
  settled_journal_id bigint REFERENCES execution_journal(journal_id),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(parent_task_id,parent_revision,call_key),
  FOREIGN KEY(parent_task_id,parent_revision) REFERENCES task_revisions(task_id,revision),
  CHECK ((result IS NULL) = (settled_journal_id IS NULL))
);

-- Awaiting parents release scheduling capacity while retaining their attempt,
-- lease, generation and budget. Rows are also fenced by the current attempt in
-- the scheduler, so an interrupted/dead process cannot lend out a stale slot.
CREATE TABLE workflow_agent_waits (
  turn_id bigint NOT NULL REFERENCES agent_turns(turn_id),
  child_task_id bigint NOT NULL REFERENCES durable_tasks(task_id),
  PRIMARY KEY(turn_id,child_task_id)
);
