-- ADR 007 step 11: a plan that forks suspends; it does not end.
--
-- Steps 9 and 10 ran a whole plan inside one tool call, which is why AtFork
-- could only be *reported*.  A fork child is a durable turn — it has a spawn
-- edge, it can be stopped, it survives a restart, and it can be reconciled
-- against a plan somebody steered meanwhile — and none of that is reachable
-- from inside a tool whose effect row has no LLM in it.  So execution moves
-- out of the call: the plan keeps a checkpoint, a worker dispatches the fork's
-- children, and the plan resumes once they are decided.
--
-- Two facts get durable homes here, and both were previously in a stack frame.

ALTER TABLE plans
  -- Where execution stands: Max.Plan.Execute.ExecState — a path, the bindings
  -- taken so far, and what has been spent.  Serializable by construction, which
  -- is the whole reason ADR 007 step 5 split the interpreter into a pure step
  -- function and a driver: a zipper of closures does not survive the process,
  -- and surviving the process is precisely what makes a child a turn rather
  -- than a thread.
  ADD COLUMN exec_state jsonb
    CHECK (exec_state IS NULL OR jsonb_typeof(exec_state) = 'object'),
  -- The fork node the walk stopped on.  Provenance for the journal, and what a
  -- resume names when the checkpoint's path no longer exists in the plan it is
  -- read back against.
  ADD COLUMN exec_node_id text,
  -- The revision the checkpoint was taken against.  A steer moves the head
  -- underneath a suspension, so a checkpoint whose revision is behind the head
  -- is the ordinary case rather than the exceptional one; the resume is
  -- entitled to know which plan it was standing in.
  ADD COLUMN exec_revision integer CHECK (exec_revision IS NULL OR exec_revision > 0),
  -- Lease over the resume, in the shape monitor_fires and the dispatch queue
  -- already use.  Only one process may be driving a suspended plan, or two
  -- would dispatch the same subgoal twice and the spawn index would refuse the
  -- second at random.
  ADD COLUMN wake_owner text,
  ADD COLUMN wake_claim_expires_at timestamptz,
  ADD CONSTRAINT plans_exec_shape_check
    CHECK ((exec_state IS NULL) = (exec_node_id IS NULL)
       AND (exec_state IS NULL) = (exec_revision IS NULL)),
  ADD CONSTRAINT plans_wake_claim_shape_check
    CHECK ((wake_owner IS NULL) = (wake_claim_expires_at IS NULL)),
  -- A closed plan is nobody's to resume.  Stated as a constraint rather than
  -- left to the queries, because "abandon this plan" and "stop driving it" have
  -- to be one act: a checkpoint outliving its plan is a suspension that would
  -- wake into a conversation that has moved on.
  ADD CONSTRAINT plans_closed_has_no_checkpoint_check
    CHECK (status = 'open' OR exec_state IS NULL);

-- The worker's claim scan.  Partial, because the interesting set is tiny and
-- the table is one row per plan a conversation ever wrote.
CREATE INDEX plans_suspended_idx
  ON plans (plan_id)
  WHERE status = 'open' AND exec_state IS NOT NULL;

ALTER TABLE turn_edges
  -- What the child produced.  Written by the child itself, through a tool whose
  -- argument schema *is* the subgoal's declared expected shape — so a value
  -- landing here has already been checked against the type the parent plan was
  -- validated against, rather than being prose somebody will parse later.
  --
  -- On the edge rather than in a table of its own: the edge is already exactly
  -- once per child (turn_edges_spawn_child_idx), and a child's result is a
  -- property of the spawn, not of the turn — the same turn machinery serves
  -- ordinary dispatches that produce no value at all.
  ADD COLUMN child_result jsonb,
  ADD CONSTRAINT turn_edges_child_result_kind_check
    CHECK (child_result IS NULL OR edge_kind = 'spawn');

-- Cross-process wakeups, same construction as max_monitor_work: NOTIFY is
-- delivered only after the row transaction commits, so a worker that recheck-
-- then-waits cannot sleep through the commit window.
CREATE FUNCTION max_notify_plan_work() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('max_plan_work', '1');
  RETURN NEW;
END;
$$;

CREATE TRIGGER plans_notify_work
  AFTER INSERT OR UPDATE OF status, exec_state, head_revision, wake_claim_expires_at
  ON plans
  FOR EACH ROW EXECUTE FUNCTION max_notify_plan_work();

-- A settling turn only concerns this worker when it is somebody's child.  The
-- test is one lookup on the unique spawn index rather than a WHEN clause,
-- which cannot hold a subquery — and without it every turn in every group
-- would wake a worker that has nothing to do.
CREATE FUNCTION max_notify_plan_child_settled() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM turn_edges e
    WHERE e.to_turn_id = NEW.turn_id AND e.edge_kind = 'spawn'
  ) THEN
    PERFORM pg_notify('max_plan_work', '1');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agent_turns_notify_plan_child_settled
  AFTER UPDATE OF status ON agent_turns
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status
        AND NEW.status = ANY (ARRAY['succeeded'::text, 'silence'::text, 'failed'::text,
                                    'aborted'::text, 'crashed'::text]))
  EXECUTE FUNCTION max_notify_plan_child_settled();
