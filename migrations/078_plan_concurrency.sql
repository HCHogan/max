-- ADR 007 step 12: a steer takes effect when it lands, and a child may delegate.
--
-- Step 11's claim gate was "no running child", which both ends of a fork's life
-- look like and which is therefore enough to dispatch and to resume.  It is not
-- enough to *reconcile*: an edited plan wants some children stopped and others
-- started while the first set is still running, and under that gate the edit sat
-- until they finished on their own.
--
-- Widening the gate needs a watermark, or the driver would re-claim a plan it
-- has already acted on the moment it released the lease and spin.

ALTER TABLE plans
  -- The revision this driver has already reconciled against.  Distinct from
  -- exec_revision, which says which plan the checkpoint's *path* was taken in:
  -- one is about where execution stands, the other about what has been acted
  -- on, and a steer moves the second without touching the first.
  ADD COLUMN reconciled_revision integer
    CHECK (reconciled_revision IS NULL OR reconciled_revision > 0);

-- Two notifications the nested case needs, and step 11 did not.
--
-- A child that opened a plan of its own finishes its turn while that plan is
-- still suspended, so its parent must not treat it as decided — the work moved
-- from the turn to the plan.  Which means the parent is no longer woken by the
-- child turn settling; it is woken when the child's *result* is written, and
-- that write is an UPDATE on the edge rather than on the turn.
CREATE TRIGGER turn_edges_notify_plan_result
  AFTER UPDATE OF child_result ON turn_edges
  FOR EACH ROW
  WHEN (NEW.child_result IS NOT NULL AND NEW.edge_kind = 'spawn')
  EXECUTE FUNCTION max_notify_plan_work();

-- And a nested plan closing releases its parent even when it produced nothing:
-- the child is decided the moment its plan is no longer open, whatever the plan
-- decided.
CREATE TRIGGER plans_notify_closed
  AFTER UPDATE OF status ON plans
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'open')
  EXECUTE FUNCTION max_notify_plan_work();
